# TheParallaxView -> native iOS rebuild

SwiftUI app shell, direct iOS API access, no game engine. Draft v0.2, 17 Oct 2026.

Scope: rebuild Peder Norrby's *TheParallaxView* (head-tracked off-axis "window"
illusion) as a native iOS app whose demo content is **spatial video** instead of
Unity 3D scenes.

---

## 0. Why drop Unity

The original is Unity 2017.4.20f2 with UnityARKitPlugin, built with Xcode 10.1 for
iPhone X. That toolchain is dead: the plugin is deprecated, the project predates
arm64-only builds and current ARKit, and the screen geometry is hard-coded to one
device. Everything it actually does is available directly on iOS:

| The original needed | Native replacement |
|---|---|
| ARKit face tracking via a Unity plugin | ARKit, first party |
| 3D scenes for content | spatial video, decoded with AVFoundation |
| Off-axis projection on a Unity camera | Metal, with our own projection matrix |
| Blend-shape eye guessing | ARFaceAnchor eye transforms, which are exact |

Two real wins from going native. ARKit exposes **leftEyeTransform** and
**rightEyeTransform** on ARFaceAnchor, so the interpupillary distance and eye height
that the original estimated from blend shapes become measured values. And the
renderer can draw the video warp in one Metal pass instead of three Unity cameras
toggling each other.

---

## 1. Module map

| Concern | Framework | What we use |
|---|---|---|
| Head pose | ARKit | ARSession + ARFaceTrackingConfiguration, ARFaceAnchor transforms |
| Fallback pose | Vision / AVFoundation | front camera + VNDetectFaceLandmarksRequest, or userFaceTrackingEnabled |
| Clip decode | AVFoundation | AVAssetReader + tagged buffer groups, CVMetalTextureCache |
| Spatial metadata | AVFoundation | AVSpatialVideoConfiguration |
| Depth authoring | Metal compute / Core ML | custom stereo kernel, or Depth Anything as a Core ML model |
| Rendering | Metal + MetalKit | MTKView, compute pass, render pass |
| Math | simd | off-axis projection, pose filtering |
| UI | SwiftUI | library, player chrome, settings, calibration |
| Glass and touch | SwiftUI Liquid Glass, UIKit | glassEffect(.interactive()), UITouch.majorRadius |
| Haptics | UIKit / CoreHaptics | UIImpactFeedbackGenerator, CHHapticEngine |

---

## 2. Package layout

    ParallaxKit/                     SPM library, no UIKit, unit-testable
      Math/OffAxisProjection.swift   port of OffAxisProjection.cs
      Math/OneEuroFilter.swift       pose smoothing
      Math/HeadPose.swift            struct: position, rotation, IPD, timestamp
      Tracking/HeadTracking.swift    protocol
      Tracking/ARKitHeadTracker.swift
      Tracking/VisionHeadTracker.swift   non-TrueDepth fallback
      Video/SpatialClipReader.swift  decode colour + depth
      Video/ClipMetadata.swift       baseline, FOV, intrinsics, comfort clamp
      Render/ParallaxRenderer.swift  MTKViewDelegate, two passes
      Render/Shaders.metal
    App/                             SwiftUI
      ParallaxApp.swift
      Views/LibraryView.swift
      Views/PlayerView.swift
      Views/PlayerChrome.swift
      Views/SettingsView.swift
      Views/MetalVideoView.swift     UIViewRepresentable around MTKView
    Tools/
      package-clip/                  macOS CLI: video -> .scpak
      build-depth/                   macOS CLI: stereo -> depth track

The point of the split: the projection math and the clip format have no UIKit
dependency, so they can be unit-tested against values taken from the Unity source.

---

## 3. Head tracking, low level

    let config = ARFaceTrackingConfiguration()
    config.maximumNumberOfTrackedFaces = 1
    config.isLightEstimationEnabled = true
    session.run(config, options: [.resetTracking, .removeExistingAnchors])

Delegate on a dedicated serial queue, not the main thread:

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.first as? ARFaceAnchor else { return }
        let head  = simd_float4x4(face.transform)
        let left  = simd_float4x4(face.leftEyeTransform).columns.3
        let right = simd_float4x4(face.rightEyeTransform).columns.3
        let ipd   = simd_distance(left, right)          // metres, exact
        let pose  = HeadPose(transform: head, ipd: ipd,
                             timestamp: session.currentFrame?.timestamp ?? 0)
        poseBuffer.append(pose)                         // ring buffer
    }

Notes that matter:

- **Mirror correction.** ARKit face anchors are mirrored in x, so negate x when
  converting to render space. The original did the same thing
  (new Vector3(-pos.x, pos.y, pos.z)) with a comment admitting it was guesswork; it
  is a documented property of the anchor, so document it once and move on.
- **Pose and frame must be paired by timestamp.** A ring buffer of
  (pose, ARFrame.timestamp) lets the renderer pick the pose nearest the video frame's
  presentation timestamp. Without this you get judder that looks like bad tracking
  but is actually bad sync.
- **Smoothing.** Use a one-euro filter, not a fixed low-pass. It keeps latency low
  when the head is still and opens up when it moves, which is exactly what a parallax
  effect needs.
- **Fallback.** Devices without TrueDepth, and the simulator, use the front camera
  with VNDetectFaceLandmarksRequest and a solved head pose, or run
  ARWorldTrackingConfiguration with userFaceTrackingEnabled when device motion is
  also useful. Gate that on ARWorldTrackingConfiguration.supportsUserFaceTracking.

---

## 4. Content pipeline: spatial video to a playable clip

**Inputs, in order of how easy they are to get.** Side-by-side 3D (SBS) is worth
supporting first, because it is the most widely available 3D video format and
decoding it is a texture split. MV-HEVC spatial video from an iPhone 15 Pro or newer
is the target format. Plain 2D video is the degenerate case with monocular depth.

**Reading both eyes.** MV-HEVC is a single track with two video layers, not two
tracks. Read it with AVAssetReader; each sample buffer carries a CMTaggedBufferGroup,
and the CMTagCollections on the track identify the left and right layers. Apple
documents this path in "Reading multiview 3D video files": resolve the layer IDs with
loadVideoLayerIdsForTrack, then read the tagged buffer group and pull one pixel
buffer per eye.

**Metadata.** Build an AVSpatialVideoConfiguration from the track's format
description. It gives cameraSystemBaseline, horizontalFieldOfView,
disparityAdjustment and cameraCalibrationDataLensCollection. Baseline and FOV are
what convert disparity into metric depth; disparityAdjustment is where the zero
parallax plane sits. All three are needed for the effect to be geometrically right
rather than merely convincing.

**Depth.**

1. Rectify the pair using the lens collection, then run stereo matching as a Metal
   compute kernel (census cost plus a semi-global pass) to get disparity. Depth is
   then z = focal * baseline / disparity.
2. Where disparity is unreliable, meaning low texture, motion blur or reflective
   surfaces, fall back to monocular depth. Apple ships **Depth Anything** as a Core ML
   model, so this is a supported dependency rather than a random checkpoint.
3. Fuse: mono for structure, stereo for scale. Then temporally smooth with a
   flow-guided median using VNGenerateOpticalFlowRequest. Flickering depth is the
   single biggest perceptual failure mode, more than absolute accuracy.

**Packaging.** Write colour and depth into one file with AVAssetWriter, using tagged
pixel buffer group output so the file keeps MV-HEVC semantics: a colour track, plus a
depth track carried as 16-bit luma, or 10-bit HEVC for extra range. A sidecar JSON
holds intrinsics, baseline, FOV, near and far planes, the comfort clamp and the
recommended viewing distance. If the auxiliary depth track proves awkward on device,
the safe fallback is a second video file; the app reads either behind one
SpatialClipReader interface.

Command line shape:

    package-clip in.mov -o clip.scpak

---

## 5. Renderer: two Metal passes

**Pass A, compute: depth to displaced geometry.** Build a vertex grid, starting at
256x144 and tuned later. At each grid point, sample the depth texture and write a
position plus a uv. The grid is the video surface, displaced along z by depth.

**Pass B, render: draw the grid with the off-axis projection.**

Why a displaced mesh instead of warping uv in the fragment shader: a fragment warp
only smears texels, so the perspective is wrong as soon as the head moves more than a
centimetre or two, and edges tear. A displaced mesh moves the geometry itself, so the
off-axis frustum stays correct across the whole tracking range and occlusion edges
stretch the way real geometry does. Keep the fragment warp as the cheap path and as
the reference implementation for comparison in the thesis.

Fragment warp, for reference:

    fragment float4 warpFragment(VertexOut in [[stage_in]],
                                 texture2d<float> colorTex [[texture(0)]],
                                 texture2d<float> depthTex [[texture(1)]],
                                 constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float d = depthTex.sample(s, in.uv).r;          // 1.0 = near
        float z = mix(u.zFar, u.zNear, d);
        float2 offset = (u.headOffset.xy / z) * u.parallaxScale;
        return colorTex.sample(s, in.uv + offset);
    }

**Per-frame projection.** Port OffAxisProjection.cs directly:

    static func perspectiveOffCenter(left: Float, right: Float, bottom: Float,
                                     top: Float, near: Float, far: Float) -> simd_float4x4 {
        let x = 2 * near / (right - left)
        let y = 2 * near / (top - bottom)
        let a = (right + left) / (right - left)
        let b = (top + bottom) / (top - bottom)
        let c = -(far + near) / (far - near)
        let d = -(2 * far * near) / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0,  0),
            SIMD4<Float>(0, y, 0,  0),
            SIMD4<Float>(a, b, c, -1),
            SIMD4<Float>(0, 0, d,  0)
        ))
    }

This is a faithful transcription of the Unity matrix, verified against the source in
the repo (m[0,2]=a, m[1,2]=b, m[2,2]=c, m[2,3]=d, m[3,2]=-1). A unit test should
assert it against those exact entries.

**The screen rectangle.** The original hard-coded 135 mm x 40 mm with a 22 mm top
offset, which is iPhone X landscape only. iOS exposes no physical screen size, so
build a table keyed on the machine identifier from utsname (iPhone17,1 and so on)
with real millimetre dimensions, and derive the visible rectangle minus the safe
area. Fall back to an estimate from nativeScale when a device is unknown, and log it,
because a wrong screen size produces a plausible but incorrect parallax.

**Debug views.** Reproduce the original's three-camera switcher (world, eye, device)
as a debug overlay. It is useful for thesis figures and for diagnosing tracking
problems.

---

## 6. SwiftUI shell

SwiftUI owns the entire app except one view.

    struct MetalVideoView: UIViewRepresentable {
        let renderer: ParallaxRenderer
        func makeUIView(context: Context) -> MTKView {
            let view = MTKView(frame: .zero, device: renderer.device)
            view.delegate = renderer
            view.preferredFramesPerSecond = 60
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            renderer.attach(to: view)
            return view
        }
        func updateUIView(_ view: MTKView, context: Context) {}
    }

Screens: LibraryView (grid of clips, replacing the original's five hard-coded scene
buttons), PlayerView (MetalVideoView plus chrome), SettingsView (the original's
sliders: eye select and auto, parallax clamp, sensitivity, calibration reset), and
CalibrationView.

State is @Observable model objects. Lifecycle: pause the ARSession and the player on
didEnterBackgroundNotification, resume on foreground. Thermals: watch
thermalStateDidChangeNotification and drop the grid resolution before iOS drops the
frame rate for you.

---

## 7. Interaction: long-press chrome and glass

One correction to the canvas notes, because it changes the design. **3D Touch does
not exist on modern iPhones.** It was on iPhone 6s through XS; everything since uses
Haptic Touch, which is a timed long press with no pressure channel. So "controls
visible only on force touch" has to be built as a long press.

    .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12) { revealChrome() }
    .sensoryFeedback(.impact(weight: .light), trigger: chromeVisible)

Chrome springs in, then auto-hides after a few seconds of no interaction, mirroring
how the original showed its panel.

**Glass.** iOS 26 Liquid Glass fits the "screen glass" note natively:

    controls
        .padding()
        .glassEffect(.regular.interactive(), in: .capsule)

Interactive glass reacts to touch and pointer input at the contact point. Group
several surfaces with GlassEffectContainer so they blend where they meet. For a
pressure-driven look with no pressure API available, drive intensity from
UITouch.majorRadius, the contact area, which does grow as a finger presses harder,
and pair it with a CoreHaptics ramp. Treat it as a proxy and say so in the thesis.

---

## 8. Quality ladder, mapped to code

| Level | Implementation | Effort |
|---|---|---|
| L0 | Fragment warp, depth ignored | Tracking and projection only. Proves the illusion. |
| L1 | Fragment warp with the depth texture | Cheap, good over a small head range. |
| L2 | Pick the near eye layer, warp both, blend | Hides disocclusion holes. |
| L3 | Compute-displaced mesh, off-axis projection | The main target. Correct over the full range. |
| L4 | Splat or 4D reconstruction of the take | Stretch goal, chapter 4 material. |

---

## 9. Milestones

| Phase | Deliverable |
|---|---|
| P0, by 25 Oct 2026 | Topic registered; the application form is due at the department |
| P1 | ParallaxKit math plus unit tests, ARKit tracking, L0 with a flat test video |
| P2 | package-clip and build-depth producing 3-5 clips |
| P3 | L1 through L3 warp, comfort clamp, calibration reset |
| P4 | Clip set, SwiftUI polish, glass chrome, evaluation, thesis figures |

P1 is deliberately the least risky milestone: no depth, no new content, just proving
that tracking plus the ported projection matrix produces the window illusion.

---

## 10. Evaluation

Use the stereo pair as ground truth. Warp the left eye by the estimated depth to
predict the right eye view, then measure PSNR and SSIM against the actual right eye
frame while sweeping the synthesis baseline. This gives a quantitative result for
chapters 2 and 3 with no ground-truth depth sensor.

Add:

- unit tests asserting the projection matrix against the Unity source values;
- head-tracking latency, measured as the delay between an anchor update and the
  rendered frame that first uses it;
- a small user study on perceived parallax, comfort and motion sickness, which also
  lets you report the comfort clamp as a derived setting rather than a guess.

---

## 11. Risks

- **No pressure API.** 3D Touch is gone; contact area is a proxy, not pressure.
- **No public physical screen size.** A per-device table is required, and an unknown
  device silently produces wrong parallax.
- **Depth holes** at strong occlusions. Parallax clamp, layered depth, offline
  inpainting.
- **Temporal flicker** in estimated depth. Flow-guided smoothing.
- **Thermals.** ARKit plus two video decodes plus Metal at 60 fps is a lot on a
  phone; budget a reduced mode.
- **Auxiliary depth track** may be awkward to write and read; the sidecar-file
  fallback keeps the app unchanged behind SpatialClipReader.
- **Licensing.** The original code is MIT; its art assets are CC BY-NC, so build new
  content. The expired patent means the illusion itself is free to use.

---

## 12. Appendix: reference inventory

Trimmed from the first exploration pass, kept so this document stands alone.

- **github.com/algomystic/TheParallaxView** - the original. Unity 2017.4.20f2,
  iPhone X face tracking, off-axis projection. Scenes: Hand, Box Scene, Vibranium,
  The Void, Beeple. Code MIT, art CC BY-NC. Source of the projection math.
- **github.com/RTUITLab/TheParallaxView** - MIREA's Windows port. Orbbec Astra Mini
  Pro instead of ARKit, Unity 2021.3.5f1, and 360 video in a sphere as an
  alternative to 3D scenes. Closest precedent for using video content.
- **github.com/AristidesAI/Splat-Frame** - shipped iOS 26 app doing TrueDepth
  tracking plus off-axis projection plus Metal, with photos and videos on the inner
  walls of a cube. Nearest existing product; reference and competitor both.
- **quasarbright/head-tracking-window** - Three.js plus OpenCV.js ArUco plus WebRTC
  desktop window illusion. Readable projection math in another language.
- **jgl.github.io/TheParallaxView** - unrelated RCA course site, name collision only.
- **patent US7738175B2** - lenticular micro-optic security printing, expired. The
  printed ancestor of the illusion, now free to build on.
- **youtube shorts -sD9G9dsgIc** - "Using Depth Maps to Create Semi-Volumetric Video
  in Blender". Authoring path for 2.5D depth-layer content.
- **youtube shorts ved_VJS35ok**, **youtube watch R2wZHTBpH6A**, **slice-ar.com** -
  Slice-AR: a device used as a slicing plane through a CT/MRI volume, on iPad and on
  Illumetry 3D displays. Commercial analogue for the "screen as window" pitch.
- **youtube live GYkq9Rgoj8E at t=5756** - WWDC 2023 keynote cue, Vision Pro and
  spatial video reveal.
- **reddit r/blackmagicfuckery "naked eye 3D card with shadows"** - physical
  lenticular print demo, motivation imagery.
- **framerusercontent.com .../YiNjztx3dxTP5PWQPZb5bT8qnzE.mp4** - 220 KB promo clip,
  motion reference.
- **4vr.xyz** - candidate domain, about 2 USD on namecheap.
- Canvas notes: MVP iOS app plan; screen as window into a different world; navigation
  controls only on long press; glass effect driven by touch; "Massimo on Twitter / X"
  (unresolved).

