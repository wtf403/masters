import Testing
import simd
@testable import ParallaxKit

/// The reference screen: the iPhone X panel the original hard-coded,
/// 135 mm x 62 mm landscape.
private let referenceScreen = OffAxisProjection.Screen(width: 0.135, height: 0.062)

@Test func offAxisMatrixMatchesTheOriginalEntryMapping() {
    // Values mirroring OffAxisProjection.cs: a viewer 22 mm from the screen's top
    // edge and 40 mm from the bottom, centred horizontally.
    let left: Float = 0
    let right: Float = 0.135
    let top: Float = 0.022
    let bottom: Float = -0.040
    let near: Float = 0.01
    let far: Float = 10

    let m = OffAxisProjection.perspectiveOffCenter(
        left: left, right: right, bottom: bottom, top: top, near: near, far: far
    )

    let x = 2 * near / (right - left)
    let y = 2 * near / (top - bottom)
    let a = (right + left) / (right - left)
    let b = (top + bottom) / (top - bottom)
    let c = -(far + near) / (far - near)
    let d = -(2 * far * near) / (far - near)

    // Careful: simd_float4x4 subscripts as (column, row) while Unity's Matrix4x4
    // subscripts as (row, column), so the original's m[0,2] is m[2,0] here.
    // Original: m[0,0]=x, m[1,1]=y, m[0,2]=a, m[1,2]=b, m[2,2]=c, m[2,3]=d, m[3,2]=-1
    #expect(m[0, 0] == x)
    #expect(m[1, 1] == y)
    #expect(m[2, 0] == a)
    #expect(m[2, 1] == b)
    #expect(m[2, 2] == c)
    #expect(m[3, 2] == d)
    #expect(m[2, 3] == -1)
    #expect(m[1, 0] == 0)
    #expect(m[3, 3] == 0)
}

/// The defining property of the effect: the four corners of the screen must land
/// exactly on the corners of the rendered image.
@Test func centredViewerPlacesScreenEdgesOnImageEdges() {
    let projection = OffAxisProjection(screen: referenceScreen, nearPlane: 0.01, farPlane: 10)
    let head = SIMD3<Float>(0, 0, 0.5)

    let halfWidth = referenceScreen.width / 2
    let halfHeight = referenceScreen.height / 2

    let topLeft = projection.project(point: SIMD3(-halfWidth, halfHeight, 0), head: head)
    #expect(abs(topLeft.x - (-1)) < 1e-4)
    #expect(abs(topLeft.y - 1) < 1e-4)

    let bottomRight = projection.project(point: SIMD3(halfWidth, -halfHeight, 0), head: head)
    #expect(abs(bottomRight.x - 1) < 1e-4)
    #expect(abs(bottomRight.y - (-1)) < 1e-4)
}

/// Off-centre viewers must produce an asymmetric frustum, which is the whole point:
/// the rectangle is no longer centred in front of the eye.
@Test func offCentreViewerProducesAsymmetricFrustum() {
    let projection = OffAxisProjection(screen: referenceScreen)
    let head = SIMD3<Float>(0.03, -0.01, 0.4)

    let f = projection.frustum(head: head)
    #expect(f.left < 0)
    #expect(f.right > 0)
    // Moved right, so the left edge is further away than the right edge.
    #expect(abs(f.left) > abs(f.right))
    // Moved down, so the top edge is further away than the bottom edge.
    #expect(f.top > abs(f.bottom))

    let halfWidth = referenceScreen.width / 2
    let halfHeight = referenceScreen.height / 2
    let topLeft = projection.project(point: SIMD3(-halfWidth, halfHeight, 0), head: head)
    #expect(abs(topLeft.x - (-1)) < 1e-3)
    #expect(abs(topLeft.y - 1) < 1e-3)
}

@Test func nearPlaneIsNormalisedToTheConfiguredValue() {
    let projection = OffAxisProjection(screen: referenceScreen, nearPlane: 0.01, farPlane: 10)
    let f = projection.frustum(head: SIMD3(0, 0, 1.5))
    #expect(f.near == 0.01)
    #expect(f.far == 10)
}

@Test func centringTheScreenOffsetKeepsTheFrustumSymmetric() {
    let offset = SIMD2<Float>(0.01, -0.005)
    let screen = OffAxisProjection.Screen(width: 0.135, height: 0.062, centreOffset: offset)
    let projection = OffAxisProjection(screen: screen)

    // A viewer sitting exactly on the offset screen's centre sees a symmetric frustum.
    let f = projection.frustum(head: SIMD3(offset.x, offset.y, 0.45))
    #expect(abs(f.left + f.right) < 1e-5)
    #expect(abs(f.top + f.bottom) < 1e-5)
}

