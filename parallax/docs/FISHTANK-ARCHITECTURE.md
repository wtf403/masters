# MV-HEVC fish-tank video player

## Goal

Use an ordinary iPhone screen as a perspective-correct window onto spatial video.
Eye position relative to the physical display controls the virtual camera. This
is a head-coupled, monoscopic display, not a binocular headset or a flat player.

## Current executable baseline

1. AVPlayerVideoOutput requests tagged left/right views and AVPlayer handles time/audio.
2. Metal computes signed disparity for a rectified stereo pair.
3. A worker actor filters disparity, generates relative depth and unprojects the
   colour image into a mesh. It permits only one in-flight frame to bound latency.
4. ARFaceAnchor selected-eye transforms are converted into the current camera's
   display-oriented coordinates. This incorporates relative phone/head movement.
5. Off-axis projection renders the mesh through the physical screen rectangle.

The matching window is 5×5 on a 192×108 sampling grid with ±12-pixel search;
output is 96×54. This does not support arbitrary unrectified stereo or panoramic
projection. Large motion, occlusion, thin objects and textureless regions expose
limitations. Smoothed percentile normalization is relative, not metric depth.
Frame temporal smoothing is not optical-flow-aligned and can trail moving objects.
The current scene renderer is SceneKit backed by Metal, not a custom Metal rasterizer.

## Neural version

A compact stereo Core ML model should replace matching, preserving left-view colour
alignment, signed disparity convention, confidence and frame timestamp. Do not
substitute monocular inference silently: it discards the second camera's constraints.
MobileStereoNet is a candidate to convert and benchmark, not a verified iPhone-ready
model. Its stereo input conventions and disparity offsets need validation against
MV-HEVC samples; model operation placement on Neural Engine must be measured.

Add optical-flow-aligned temporal filtering with confidence reset at cuts, then
occlusion handling using the second view. Benchmark against this classical baseline
before calling the result an improvement. Measure p50/p95 frame processing, eye-to-
display latency, video throughput, energy, temporal flicker and synthesized-view error.

## Apple API boundary

Photos' Spatial Scenes does not imply third-party iOS access to its reconstruction
model. Apple's engineer identifies Spatial3DImage generation APIs as visionOS-only.
AVDepthData captures supported camera depth; it does not infer depth from arbitrary
MV-HEVC files. Core ML supports deploying a separately acquired/converted model.

## Sources checked 2026-10-18

- https://github.com/algomystic/TheParallaxView
- https://developer.apple.com/documentation/avfoundation/reading-multiview-3d-video-files
- https://developer.apple.com/forums/thread/787237
- https://www.apple.com/lae/os/pdf/All_New_Features_iOS_26_Sept_2025.pdf
- https://github.com/cogsys-tuebingen/mobilestereonet
- https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest

## Verification snapshot, 2026-10-18

- Nine focused Swift tests passed, including positive/negative stereo disparity
  and projection tests. The disparity test has two parameterized cases.
- The same live decoding/mesh code rendered three eye positions from Hummingbird
  on the Mac. Neutral view is upright; displaced views exhibit depth motion and
  visible occlusion-edge distortion. All three files tested at that time yielded both views. Spatial-Test had little
  reliable stereo detail and was subsequently removed; only Hummingbird and
  Lighthouse remain bundled.
- Release build installed and launched on the connected iPhone 15.
- Device diagnostics recorded 284 processed video frames, 308 tracked eye frames,
  eye distance 0.389 m and 20.0 ms for the latest processing sample. This is not
  an average, p95, FPS or end-to-end motion-to-photon latency measurement.
- Core ML inference, optical-flow temporal alignment and subjective fish-tank
  quality have not yet been validated.
