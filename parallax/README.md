# parallax

## Current iPhone app: MV-HEVC fish-tank player

Open a bundled spatial video or import one with **+**. Allow front-camera access.
The player decodes both tagged MV-HEVC views through `AVPlayerVideoOutput`,
estimates signed stereo disparity on Metal, and reprojects a video-aligned depth
surface with TheParallaxView-style off-axis projection. ARKit measures the
selected eye relative to the current phone camera, so moving either the phone or
the head changes the view. The camera does not rotate to follow gaze direction.

Hold the phone in landscape, select your viewing eye, and tap **Centre** while
looking straight at it. Small movements work best. Use the depth slider to adjust
the effect; zero flattens the surface. Pause retains head-controlled perspective.
As in TheParallaxView, the monoscopic illusion is strongest with one eye closed.

This is an experimental live stereo baseline, not the finished Core ML version.
A 96×54 GPU block matcher feeds a depth surface. Spatial/temporal smoothing reduces
noise, but does not yet use optical-flow motion compensation. Depth is relative,
with an authored 2–12 cm range behind the screen, rather than calibrated metric
scene reconstruction. Occlusion edges can stretch and newly exposed regions can
be missing. Per-frame colour and depth are processed together by a worker actor;
head-pose updates remain on the main actor, independently of video processing.
The input loop requests up to 30 frames/s, while actual throughput is device-dependent.

No neural network is bundled yet. The next quality comparison is a compact stereo
Core ML model versus this measured baseline, with frame latency, temporal stability,
and energy use evaluated on the phone. See `docs/FISHTANK-ARCHITECTURE.md`.

The old static scenes and offline depth assets are not bundled or exposed in the
current app. Source sample licensing is in `Samples/README.md`. Build using Xcode's
command-line tools; no simulator runtime is required.

## Earlier video prototype

A native iOS app that turns the screen into a window onto another space, using
spatial video as its content and head tracking to drive the perspective.

This is a rebuild of Peder Norrby's TheParallaxView, which did the same thing with
Unity 3D scenes. The repository at ../TheParallaxView is the reference
implementation and is not modified here: the projection math was ported from it and
is checked against it in the tests.

Design notes live in docs/PLAN.md.

## Layout

    Sources/ParallaxKit      core library: math, tracking, video, rendering
    Sources/ParallaxApp      SwiftUI app
    Tools/PackageClip        authoring CLI: video to .scpak
    Tools/BuildDepth         authoring CLI: stereo to depth track
    Tests/ParallaxKitTests   unit tests
    Scripts                  build and verification helpers

## Status

Phase P1 is implemented, and phase P2 has started.

Implemented and tested:

- Math: off-axis projection ported from the Unity source, per-device screen
  geometry, head pose, one-euro filtering, and the CPU reference for the warp.
- Tracking: ARKit face tracking with measured interpupillary distance from the eye
  transforms, a world-tracking fallback for devices without TrueDepth, a
  timestamp-indexed pose buffer, and pose smoothing.
- Video: clip bundle format and metadata, a movie reader, side-by-side layout
  handling, pixel operations, a packager, and a block-matching depth builder.
- Render: a Metal renderer with two paths, an off-axis projected plane and a
  fragment warp kept as the reference, with a parallax clamp.
- App: the SwiftUI shell, clip library, player, settings and calibration.

Known gaps, stated so the thesis does not overclaim:

- The compute-displaced mesh path (quality level L3) is not implemented. The two
  paths that exist are the projected plane and the fragment warp.
- Depth comes from a CPU block matcher with no sub-pixel refinement, no
  left-right consistency and no semi-global pass. It reports its own confidence.
- Depth is quantised to 8 bits. 16-bit is the intended upgrade.
- Nothing has been run on a device or in a simulator. See the limits below.

## Building

Build and run the tests:

    swift build
    swift test

Type-check the iOS-only code, which needs no simulator:

    Scripts/typecheck-ios.sh

Generate the Xcode project, then open it:

    xcodegen generate
    open Parallax.xcodeproj

## Verification limits on this machine

The iOS SDK is present, so type-checking iOS code works, but no iOS platform
runtime is installed: `xcrun simctl list runtimes` is empty and xcodebuild reports
"iOS 26.5 is not installed" for both device and simulator destinations. So an app
bundle cannot be built or run here.

What that means in practice:

- The core library is verified by unit tests, which run natively.
- iOS-only code is verified by type-checking against the iOS SDK.
- Building and running the app needs the iOS platform installed in Xcode
  (Settings, Components) and a signing team for a device.

The Xcode project is generated from project.yml and is deliberately not committed.

## Verification limits on this machine

Two further constraints were found while building:

- The command line tools cannot encode video here. HEVC, H.264 and uncompressed all
  fail to start, which points at the platform media encoding services being
  unavailable in a restricted sandbox rather than at the code. The tools are
  therefore verified up to the encoding call, and their pure logic is covered by
  unit tests; the encode itself has not been exercised.
- IOSurface allocation is refused, so clip and texture buffers fall back to
  ordinary CPU pixel buffers. That is slower but functionally the same, and it is
  what lets the pixel tests run at all.

Run the suite with the same flags CI should use:

    CLANG_MODULE_CACHE_PATH=/tmp/pmc SWIFTPM_MODULECACHE_OVERRIDE=/tmp/pmc \
      swift test --disable-sandbox

