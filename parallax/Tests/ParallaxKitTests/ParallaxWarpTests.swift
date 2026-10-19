import Testing
import simd
@testable import ParallaxKit

/// The depth mapping must be monotonic and must put the near plane at the ends it
/// claims, because the projection converts the other way round.
@Test func depthMappingHitsBothPlanesAndIsMonotonic() {
    let near: Float = 0.25
    let far: Float = 8

    #expect(abs(ParallaxWarp.distance(depthSample: 1, near: near, far: far) - near) < 1e-5)
    #expect(abs(ParallaxWarp.distance(depthSample: 0, near: near, far: far) - far) < 1e-5)

    var previous = Float.greatestFiniteMagnitude
    for step in stride(from: Float(0), through: 1, by: 0.1) {
        let value = ParallaxWarp.distance(depthSample: step, near: near, far: far)
        #expect(value < previous)
        previous = value
    }
}

/// Out of range samples are clamped rather than extrapolated: a bad depth sample must
/// not be able to invert the depth and pull the image through itself.
@Test func depthSamplesOutsideTheUnitRangeAreClamped() {
    #expect(ParallaxWarp.distance(depthSample: 4, near: 0.25, far: 8) == 0.25)
    #expect(ParallaxWarp.distance(depthSample: -3, near: 0.25, far: 8) == 8)
}

/// The defining property: a centred viewer sees no displacement at all, so the image
/// is pixel-exact when the head is on axis.
@Test func zeroHeadOffsetMeansZeroDisplacement() {
    let offset = ParallaxWarp.offset(headOffset: .zero, distance: 0.5, scale: 1, clamp: 0.03)
    #expect(offset == .zero)
}

/// Parallax must shrink with distance, which is what makes a near object appear to
/// move further than a far one.
@Test func nearerSurfacesDisplaceMore() {
    let head = SIMD2<Float>(0.02, 0)

    let near = ParallaxWarp.offset(headOffset: head, distance: 0.3, scale: 1, clamp: 10)
    let far = ParallaxWarp.offset(headOffset: head, distance: 3.0, scale: 1, clamp: 10)

    #expect(abs(near.x) > abs(far.x))
}

/// The clamp has to actually bound the result; without it a mis-sampled depth at an
/// occlusion edge samples outside the image and tears the border.
@Test func clampBoundsTheDisplacement() {
    let clamp: Float = 0.03
    let head = SIMD2<Float>(0.5, -0.5)

    let offset = ParallaxWarp.offset(headOffset: head, distance: 0.05, scale: 1, clamp: clamp)
    #expect(abs(offset.x) <= clamp + 1e-6)
    #expect(abs(offset.y) <= clamp + 1e-6)
}

/// Scaling by zero is the control condition used to demonstrate the effect: the same
/// head movement must produce a perfectly flat result.
@Test func zeroScaleFlattensTheEffect() {
    let head = SIMD2<Float>(0.03, 0.01)
    let offset = ParallaxWarp.offset(headOffset: head, distance: 0.3, scale: 0, clamp: 0.03)
    #expect(offset == .zero)
}

/// With no depth track the warp falls back to the content plane distance, which is the
/// L1 path.
@Test func missingDepthFallsBackToThePlaneDistance() {
    let headOffset = SIMD2<Float>(0.02, 0.01)
    let withPlane = ParallaxWarp.offset(
        headOffset: headOffset,
        depthSample: nil,
        planeDistance: 0.35,
        near: 0.25,
        far: 8,
        scale: 1,
        clamp: 10
    )
    let explicit = ParallaxWarp.offset(
        headOffset: headOffset,
        distance: 0.35,
        scale: 1,
        clamp: 10
    )
    #expect(abs(withPlane.x - explicit.x) < 1e-6)
    #expect(abs(withPlane.y - explicit.y) < 1e-6)
}

