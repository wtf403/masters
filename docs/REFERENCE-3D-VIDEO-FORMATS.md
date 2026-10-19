# 3D / spatial video: formats, players, sample clips

Research notes, 17 Oct 2026. Companion to `PLAN-spatial-video-parallax.md`.

Answers three questions: what 3D video formats exist that we might need to open,
what actually plays each one, and where to get real clips to test with.

---

## 1. The formats

| Format | Container / codec | How the two eyes are stored | Notes |
|---|---|---|---|
| **Apple spatial video** | MOV/MP4, MV-HEVC | One video track, two HEVC layers (left = base, right = enhancement). Same frame size for both eyes. | Plus spatial metadata boxes (`vexu`, `hfov`) describing baseline, FOV, disparity adjustment, lens calibration. **No depth layer.** Captured by iPhone 15 Pro and later, Vision Pro, URSA Cine Immersive. |
| **Stereo MV-HEVC** | MOV/MP4, MV-HEVC | Identical to above | Same bitstream without the spatial metadata. Plays as 3D but is not treated as "spatial" by Apple. |
| **Apple Immersive Video** | `.aivu` / MOV, MV-HEVC | Two layers, one per eye | MV-HEVC plus projection (180, 360, wide FOV), mask metadata and an extra metadata track. Superset of spatial video. |
| **Apple Projected Media Profile (APMP)** | MOV/MP4, MV-HEVC | Two layers, one per eye | MV-HEVC carrying equirect or hemisphere projection tags. How 180/360 stereo is delivered on Apple platforms. |
| **Side-by-side (SBS / HSBS)** | MP4/MOV/MKV, H.264 or HEVC | Both eyes in a single frame, left half and right half | What VR180 cameras and YouTube VR180 produce. "h" = half resolution per eye. |
| **Over/under (OU / HOU, top-bottom)** | MP4/MOV/MKV, H.264 or HEVC | Both eyes stacked vertically | Preserves full resolution; the friendliest layout for generic video tools. |
| **Anaglyph (red/cyan)** | Anything | Depth baked in as colour tint | Degraded but plays in any player, no headset and no special display. |
| **MVC (3D Blu-ray)** | `.m2ts` / MKV, H.264 MVC | Two views in one stream | Needs a 3D Blu-ray capable player or a demux to SBS. Legacy, but a good source of clean stereo pairs. |
| **Spatial photo / stereo stills** | HEIC (spatial photo), MPO | Auxiliary image layer, or two JPEGs in one MPO | Out of scope except as a test case for the same projection code. |

Also worth knowing: Google's `spatial-media` metadata (`st3d`, spherical v2) is how
SBS/OU files declare their layout on YouTube and in web players, and Meta's Quest
spatial video support is MV-HEVC too. So MV-HEVC is the one format that spans
Apple and Meta hardware.

## 2. What actually plays what

| Format | iPhone / iPad | Mac | Vision Pro | Quest 3 / Quest Pro |
|---|---|---|---|---|
| Spatial video (MV-HEVC + metadata) | Photos (17.2+) plays it flat, one eye | Photos, QuickTime: opens it; stereo presentation depends on display and OS version | Photos, QuickTime: full 3D | 4XVR, SKYBOX (2.0.2 preview), DeoVR |
| Stereo MV-HEVC | as above | as above | full 3D | 4XVR, SKYBOX, DeoVR |
| SBS / OU | Photos ignores layout; use a 3D player | QuickTime/Warped and any 3D-capable player | Photos, QuickTime (with layout tags) | 4XVR, SKYBOX, DeoVR, Meta TV |
| Anaglyph | anything | anything | anything | anything |
| MVC | no | HandBrake to SBS | no | via MKV/SBS |

Caveats found in the field: 4XVR on Quest handles 1080p 8-bit 30 fps MV-HEVC but
falls back to 2D on 10-bit files; SKYBOX users report some MV-HEVC files playing
in 2D even after the 2.0.2 preview added support. So a Quest is a useful test
device but not a reliable reference for "does this file decode".

Command line, no device needed:

- FFmpeg 7.1 and later decode MV-HEVC (`-view_ids` / `view_ids` decoder option);
  the HEVC decoder handles multiview streams with at most two views. FFmpeg's
  `-stereo3d` sets 3D layout metadata on output, and Google spatial-media
  (`st3d`) tagging requires `-strict unofficial`.
- `spatial export` (below) turns any MV-HEVC clip into OU, SBS or two separate
  eye videos, which is the quickest way to see both views with ordinary tools.
- VLC, ffplay and mpv will play SBS/OU; none of them renders MV-HEVC stereo.

## 3. Tooling on macOS

| Tool | What it does | Link |
|---|---|---|
| `spatial` | Free CLI. `info` to inspect, `export` MV-HEVC to OU/SBS/separate eyes, `make` MV-HEVC from those, `combine` to mux audio, `metadata` to edit spatial tags. `brew install spatial`. Ships a small MV-HEVC sample, `spatial_test.mov`. | blog.mikeswanson.com/spatial/ |
| SpatialMediaKit | Split or merge MV-HEVC on Apple silicon; splits to ProRes 422 HQ so it stays visually lossless. | github.com/sturmen/SpatialMediaKit |
| MV-HEVC Pal | GUI wrapper for the same job on Mac. | github.com/ntfromchicago/mv-hevc-pal |
| Spatialify | iOS and Apple-silicon Mac app, a few dollars. Views and converts 3D formats, exports anaglyph. | App Store |
| Spatial Player | Minimal MV-HEVC player for Vision Pro, useful as a reference implementation of layer extraction and projection. | github.com/mikeswanson/SpatialPlayer |
| Apple sample: converting SBS to MV-HEVC | Shows the `AVAssetWriterInputTaggedPixelBufferGroupAdaptor` path and how to attach spatial metadata. | developer.apple.com/documentation/avfoundation/converting-side-by-side-3d-video-to-multiview-hevc-and-spatial-video |
| Apple sample: reading multiview 3D video | Reads both layers out of an MV-HEVC file frame by frame. | developer.apple.com/documentation/avfoundation/reading-multiview-3d-video-files |
| MP4Box / gpac | Muxes MV-HEVC with audio; carries the spatial metadata boxes through. | gpac.io |
| AWS Elemental MediaConvert | Cloud MV-HEVC encoding via `multiViewSettings` (left = file input, right = multi-view input), Pro tier. | docs.aws.amazon.com/mediaconvert |

## 4. Sample clips

Small and free, good for a first smoke test:

- `spatial_test.mov` inside the `spatial` release zip. A few seconds of real
  MV-HEVC with spatial metadata. The single most convenient test file.
- `sample-vr180.mp4` in alexvnesta/vr180-local-player: 3 seconds, 4096x2048,
  H.264 side-by-side. Plays in any browser. Good for checking SBS layout
  detection before any depth work.
- Thandford's VR Format Test Bench (thanford.com/glyphew/test-vr): synthetic
  SBS, OU and VR180 clips built from gradients and UV patterns, so you can see
  whether a warp is correct rather than merely plausible.
- Noah Kadner's spatial video samples, shot on iPhone: a set of original MOV
  files plus anaglyph conversions, downloadable from his frame.io article
  (blog.frame.io/2024/02/01/how-to-capture-and-view-vision-pro-spatial-video/).

Real stereo pairs with calibration, for the depth pipeline:

- **lulinxuan/VR180** on Hugging Face (CC BY-NC 4.0, gated access, per-sample
  download). 635 stereo video clips and 575 stereo stills shot on two Blackmagic
  URSA Cine Immersive cameras at 90 fps. Each clip is available as camera-native
  BRAW, native fisheye HEVC (8160x7200 per eye), and half-equirectangular HEVC
  (7200x7200 per eye), with factory lens calibration in JSON. About 6 TB for the
  whole set, but you can pull a single sample with
  `hf download lulinxuan/VR180 --include 'h265_eq/<id>/*'`. This is the best
  free source of properly calibrated stereo, and its fisheye-to-equirect tooling
  is directly reusable.
- **SpatialVID** (CVPR 2026, CC BY-NC-SA 4.0): 2D clips with camera poses, depth
  maps and dynamic masks. Not stereo, but exactly what you need to train or
  evaluate a monocular depth fallback and to sanity-check metric depth.
- Apple's own sample projects ship the inputs they use, including an SBS clip in
  the conversion sample. Those come out of the downloadable Xcode projects.
- Retail galleries: Travel Worm (travelworm.mov), Slice of Life VR, VERY-REAL.
  Mostly streamed or licensed, useful as quality references rather than test
  assets.

Licensing note: the Hugging Face VR180 set and SpatialVID are both non-commercial.
Fine for a thesis, not for a shipped product. `spatial_test.mov` and the Apple
sample inputs are for development use.

## 5. What this means for the app

Primary target is MV-HEVC, because that is the only format that carries the
stereo pair *and* the camera intrinsics and baseline we need to make metric depth
and scale parallax. The read path is `AVAssetReader` with a tagged pixel buffer
group output, which yields two `CVPixelBuffer`s per frame, and
`AVSpatialVideoConfiguration(formatDescription:)` for `cameraSystemBaseline`,
`horizontalFieldOfView`, `disparityAdjustment` and
`cameraCalibrationDataLensCollection`.

Keep an SBS/OU import path as well. It is what our own offline builder writes,
what every third-party tool reads, and it makes debugging possible without a
device.

Test matrix worth building around: an iPhone spatial capture at 1080p30, a
Vision Pro 8K capture, a VR180 half-equirectangular pair from the dataset, the
synthetic SBS test pattern for warp verification, and one flat 2D clip as the
control for the P1 milestone where the window illusion should already appear
without any depth at all.

## 6. Sources

Apple: MV-HEVC and spatial video documentation for `AVSpatialVideoConfiguration`,
creating spatial photos and videos with spatial metadata, converting SBS 3D video
to MV-HEVC, reading multiview 3D video files, and the WWDC25 sessions "Explore
video experiences for visionOS" and "Support immersive video playback in visionOS
apps". Mike Swanson's Spatial Video Tool and its documentation. sturmen's
SpatialMediaKit. AWS MediaConvert MV-HEVC documentation. lulinxuan/VR180 dataset
card and paper (arXiv:2610.10607). NJU-3DV/SpatialVID. frame.io article by Noah
Kadner. 4XVR and SKYBOX playback documentation and reports.
