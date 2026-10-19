# Stereo test clips

The app bundles two development demos and decodes both stereo views for live
depth-based fish-tank playback.

| File | Duration | Source and format |
| --- | --- | --- |
| `Hummingbird.mov` | 4.33 seconds | Apple's RealityKit stereo sample, converted from 3840×1080 side-by-side to 1280×720-per-eye MV-HEVC. Both eyes retained; no camera calibration was invented. |
| `apple-spatial-lighthouse.mov` | 13.91 seconds | Existing local sample; verified MV-HEVC with both eyes and rectilinear projection. Copied to the device as `Lighthouse.mov`. Original download provenance was not recorded. |

Sources:

- Apple sample: https://developer.apple.com/documentation/realitykit/rendering-stereoscopic-video-with-realitykit
- Apple download: https://docs-assets.developer.apple.com/published/4bf2d74e8473/RenderingStereoscopicVideoWithRealityKit.zip

Apple's sample license is preserved in `Apple-Sample-LICENSE.txt`. These samples
are included for local development; check the source terms before redistribution.

Open a demo from Spatial Videos, or use + to import your own movie.
