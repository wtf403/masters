#!/usr/bin/env python3
"""Bake a rectified side-by-side video into colour + relative-depth mesh frames.

Requires numpy, opencv-python-headless and ffmpeg. Camera calibration is absent,
so output depths are an authored shallow relief, not measured metric distances.
"""
import argparse
import json
from pathlib import Path
import subprocess
import cv2
import numpy as np


def matcher():
    return cv2.StereoSGBM_create(
        minDisparity=-32, numDisparities=96, blockSize=5,
        P1=8 * 25, P2=32 * 25, disp12MaxDiff=1,
        uniquenessRatio=8, speckleWindowSize=80, speckleRange=2,
        mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY,
    )


def self_test():
    rng = np.random.default_rng(4)
    left = rng.integers(0, 256, (180, 640), dtype=np.uint8)
    right = np.roll(left, -8, axis=1)
    disparity = matcher().compute(left, right).astype(np.float32) / 16
    measured = float(np.median(disparity[20:-20, 130:-50]))
    assert abs(measured - 8) < 0.5, measured
    print(f"Synthetic stereo check passed: expected 8 px, measured {measured:.2f} px")


def build(source, output):
    output.mkdir(parents=True, exist_ok=True)
    fps, width, height, grid_w, grid_h = 15, 640, 360, 96, 54
    result = subprocess.run([
        'ffmpeg', '-v', 'error', '-i', str(source),
        '-vf', 'fps=15,scale=1280:360', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-'
    ], check=True, capture_output=True)
    frames = np.frombuffer(result.stdout, dtype=np.uint8).reshape(-1, height, width * 2, 3)
    engine = matcher()
    disparities, confidence = [], []
    for frame in frames:
        left = cv2.cvtColor(frame[:, :width], cv2.COLOR_BGR2GRAY)
        right = cv2.cvtColor(frame[:, width:], cv2.COLOR_BGR2GRAY)
        disparity = engine.compute(left, right).astype(np.float32) / 16
        valid = disparity > -32.5
        confidence.append(float(valid.mean()))
        # Fill unmatched pixels for a continuous surface; this is estimated geometry.
        filled = cv2.inpaint(disparity, (~valid).astype(np.uint8), 5, cv2.INPAINT_NS)
        disparities.append(cv2.GaussianBlur(filled, (9, 9), 2))
    low, high = np.percentile(np.stack(disparities), [5, 95])
    assert high > low + 0.5, 'Stereo input has too little usable disparity'
    encoded, previous = [], None
    for index, disparity in enumerate(disparities):
        inverse_depth = np.clip((disparity - low) / (high - low), 0, 1)
        small = cv2.resize(inverse_depth, (grid_w, grid_h), interpolation=cv2.INTER_AREA)
        small = small if previous is None else 0.65 * small + 0.35 * previous
        previous = small
        encoded.append(np.rint(small * 255).astype(np.uint8))
        if index == len(disparities) // 2:
            cv2.imwrite(str(output / 'VideoScenePreview.jpg'), frames[index, :, :width])
            cv2.imwrite('/tmp/parallax-video-depth.png', cv2.applyColorMap(
                np.rint(inverse_depth * 255).astype(np.uint8), cv2.COLORMAP_TURBO))
    data = np.stack(encoded).tobytes()
    assert len(data) == len(frames) * grid_w * grid_h
    (output / 'VideoSceneDepth.bin').write_bytes(data)
    metadata = dict(width=grid_w, height=grid_h, frameCount=len(frames), fps=fps,
                    duration=len(frames)/fps, nearDepth=0.025, farDepth=0.14,
                    referenceEyeDistance=0.4,
                    validStereoFraction=float(np.mean(confidence)),
                    disparityPercentiles=[float(low), float(high)],
                    method='OpenCV StereoSGBM; filled and smoothed relative disparity',
                    metricCalibration=False,
                    source='Apple Rendering stereoscopic video with RealityKit: sample.mov')
    (output / 'VideoScene.json').write_text(json.dumps(metadata, indent=2) + '\n')
    subprocess.run([
        'ffmpeg', '-y', '-v', 'error', '-i', str(source),
        '-vf', 'crop=iw/2:ih:0:0,fps=15,scale=640:360', '-an',
        '-c:v', 'libx264', '-crf', '19', '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart', str(output / 'VideoSceneColour.mp4')
    ], check=True)
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('input', type=Path, nargs='?')
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    self_test()
    if args.input:
        if args.output is None:
            p.error('--output is required with an input')
        build(args.input, args.output)
