import Foundation
import simd

/// CPU mirror of the parallax warp performed in the shader.
///
/// The shader is the real implementation, but it cannot be run without a GPU and a
/// display. Keeping the arithmetic here in Swift means the properties that make the
/// effect correct are pinned down by tests rather than asserted in a comment, and it
/// gives the thesis a reference to compare the GPU result against.
public enum ParallaxWarp {

    /// Metric depth for a depth sample, following the shader's mapping.
    ///
    /// A sample of 1 means nearest, which is the convention the depth authoring pass
    /// writes and the convention the off-axis projection expects.
    public static func distance(depthSample: Float, near: Float, far: Float) -> Float {
        let sample = min(max(depthSample, 0), 1)
        return far + (near - far) * sample
    }

    /// Displacement in texture coordinates.
    ///
    /// The magnitude falls with distance, so a nearer surface moves more than a far
    /// one, and the result is clamped because a mis-sampled depth at an occlusion edge
    /// would otherwise pull texture from outside the image and tear the border.
    public static func offset(
        headOffset: SIMD2<Float>,
        distance: Float,
        scale: Float,
        clamp clampFraction: Float
    ) -> SIMD2<Float> {
        let z = max(distance, 0.001)
        let raw = (headOffset / z) * scale
        let limit = max(clampFraction, 0)
        return simd_clamp(raw, SIMD2<Float>(repeating: -limit), SIMD2<Float>(repeating: limit))
    }

    /// Convenience form that takes the depth sample directly.
    public static func offset(
        headOffset: SIMD2<Float>,
        depthSample: Float?,
        planeDistance: Float,
        near: Float,
        far: Float,
        scale: Float,
        clamp clampFraction: Float
    ) -> SIMD2<Float> {
        let distance = depthSample.map { self.distance(depthSample: $0, near: near, far: far) }
            ?? planeDistance
        return offset(headOffset: headOffset, distance: distance, scale: scale, clamp: clampFraction)
    }
}

