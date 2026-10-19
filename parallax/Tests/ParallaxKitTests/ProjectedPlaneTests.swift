import Testing
import simd
@testable import ParallaxKit

/// Geometry of the projected-plane render path, checked on the CPU.
///
/// The shader is the real implementation, but it cannot be compiled on a machine
/// without the Metal toolchain, and it cannot be run without a device. These cases
/// mirror `planeVertex` exactly and pin down the two properties the path depends on:
/// the content plane exactly covers the screen when the viewer is centred, and moving
/// the head changes which part of the plane is visible.
private struct PlaneGeometry {
    let projection: OffAxisProjection
    let planeDistance: Float

    /// Corner in NDC for a unit-plane corner in {-1, 1}, mirroring the shader.
    func project(corner: SIMD2<Float>, head: SIMD3<Float>) -> SIMD3<Float> {
        let half = SIMD2<Float>(projection.screen.width * 0.5, projection.screen.height * 0.5)
        let eyeDistance = max(head.z, 0.001)
        let plane = max(planeDistance, 0.001)
        let grow = (eyeDistance + plane) / eyeDistance
        let point = SIMD3<Float>(corner.x * half.x * grow, corner.y * half.y * grow, -plane)
        return projection.project(point: point, head: head)
    }
}

private let planeScreen = OffAxisProjection.Screen(width: 0.135, height: 0.062)
private let restHead = SIMD3<Float>(0, 0, 0.5)

@Test func contentPlaneExactlyCoversTheScreenAtRest() {
    let geometry = PlaneGeometry(
        projection: OffAxisProjection(screen: planeScreen, nearPlane: 0.01, farPlane: 10),
        planeDistance: 0.35
    )

    for corner in [SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1), SIMD2<Float>(-1, 1), SIMD2<Float>(1, 1)] {
        let ndc = geometry.project(corner: corner, head: restHead)
        #expect(abs(abs(ndc.x) - 1) < 1e-4)
        #expect(abs(abs(ndc.y) - 1) < 1e-4)
    }
}

/// The plane is grown to compensate for its distance, so the growth factor has to
/// cancel the perspective divide exactly. If it does not, the image is scaled wrong
/// whenever the viewer is centred, which is the one case that must look perfect.
@Test func coverageHoldsForAnyContentDistance() {
    for distance: Float in [0.1, 0.35, 1.0, 2.0] {
        let geometry = PlaneGeometry(
            projection: OffAxisProjection(screen: planeScreen, nearPlane: 0.01, farPlane: 10),
            planeDistance: distance
        )
        let ndc = geometry.project(corner: SIMD2<Float>(1, 1), head: restHead)
        #expect(abs(ndc.x - 1) < 1e-4, "distance \(distance)")
        #expect(abs(ndc.y - 1) < 1e-4, "distance \(distance)")
    }
}

/// This is the effect itself: moving the head off the axis must push the plane's
/// corners off screen, which is what reveals content that was previously hidden by
/// the screen edges.
@Test func movingTheHeadRevealsADifferentPartOfThePlane() {
    let geometry = PlaneGeometry(
        projection: OffAxisProjection(screen: planeScreen, nearPlane: 0.01, farPlane: 10),
        planeDistance: 0.35
    )

    let centred = geometry.project(corner: SIMD2<Float>(1, 1), head: restHead)
    let moved = geometry.project(corner: SIMD2<Float>(1, 1), head: SIMD3<Float>(0.03, 0, 0.5))

    // The right corner leaves the visible area, so the middle of the image moves left
    // on screen and the viewer sees more of the right side of the content.
    #expect(moved.x > centred.x)
    #expect(moved.x > 1)
}

/// A deeper content plane produces more displacement for the same head movement,
/// which is the control the settings slider exposes.
@Test func displacementGrowsWithContentDistance() {
    let head = SIMD3<Float>(0.02, 0, 0.5)
    let near = PlaneGeometry(
        projection: OffAxisProjection(screen: planeScreen, nearPlane: 0.01, farPlane: 10),
        planeDistance: 0.15
    ).project(corner: SIMD2<Float>(1, 1), head: head)
    let far = PlaneGeometry(
        projection: OffAxisProjection(screen: planeScreen, nearPlane: 0.01, farPlane: 10),
        planeDistance: 1.5
    ).project(corner: SIMD2<Float>(1, 1), head: head)

    #expect(far.x > near.x)
}
