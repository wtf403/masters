import Foundation
import simd

/// Off-axis (asymmetric) perspective projection, ported from OffAxisProjection.cs
/// in algomystic/TheParallaxView.
///
/// The screen is treated as a physical window. Given where the viewer's eye is
/// relative to the screen, the projection places the screen's edges exactly on the
/// edge of the rendered image, so whatever is drawn inside the screen reads as a
/// continuation of the space the screen sits in.
///
/// Frame conventions. Screen frame: the screen lies in the plane z = 0, centred on
/// the origin plus Screen.centreOffset, with +x right, +y up, +z out of the screen
/// toward the viewer. The viewer therefore sits at positive z. The eye camera looks
/// down -z, which is the convention the original matrix produces.
public struct OffAxisProjection: Sendable, Equatable {

    /// Physical screen rectangle in metres.
    public struct Screen: Sendable, Equatable {
        public var width: Float
        public var height: Float
        /// Offset of the screen rectangle's centre from the tracked device origin.
        public var centreOffset: SIMD2<Float>

        public init(width: Float, height: Float, centreOffset: SIMD2<Float> = .zero) {
            self.width = width
            self.height = height
            self.centreOffset = centreOffset
        }
    }

    public struct Frustum: Sendable, Equatable {
        public var left: Float
        public var right: Float
        public var bottom: Float
        public var top: Float
        public var near: Float
        public var far: Float

        public init(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
            self.left = left
            self.right = right
            self.bottom = bottom
            self.top = top
            self.near = near
            self.far = far
        }
    }

    public var screen: Screen
    public var nearPlane: Float
    public var farPlane: Float

    public init(screen: Screen, nearPlane: Float = 0.01, farPlane: Float = 10) {
        self.screen = screen
        self.nearPlane = nearPlane
        self.farPlane = farPlane
    }

    /// Frustum planes for an eye at head, expressed in the screen frame in metres.
    ///
    /// Mirrors the original: the four edges are measured from the point on the
    /// screen plane directly in front of the viewer, then the whole frustum is
    /// rescaled so the near plane lands on nearPlane (1 cm in the original).
    public func frustum(head: SIMD3<Float>) -> Frustum {
        let halfWidth = screen.width * 0.5
        let halfHeight = screen.height * 0.5

        // Distance from the eye to the screen plane. Clamped so a viewer at or
        // behind the plane produces a defined, if useless, matrix.
        let distance = max(head.z, 1e-4)

        let leftEdge = -halfWidth + screen.centreOffset.x
        let rightEdge = halfWidth + screen.centreOffset.x
        let bottomEdge = -halfHeight + screen.centreOffset.y
        let topEdge = halfHeight + screen.centreOffset.y

        let scale = nearPlane / distance

        return Frustum(
            left: (leftEdge - head.x) * scale,
            right: (rightEdge - head.x) * scale,
            bottom: (bottomEdge - head.y) * scale,
            top: (topEdge - head.y) * scale,
            near: nearPlane,
            far: farPlane
        )
    }

    public func projectionMatrix(head: SIMD3<Float>) -> simd_float4x4 {
        let f = frustum(head: head)
        return OffAxisProjection.perspectiveOffCenter(
            left: f.left, right: f.right, bottom: f.bottom, top: f.top, near: f.near, far: f.far
        )
    }

    /// Direct transcription of PerspectiveOffCenter from the original source.
    /// Entry mapping verified against OffAxisProjection.cs:
    /// m[0,2] = a, m[1,2] = b, m[2,2] = c, m[2,3] = d, m[3,2] = -1.
    public static func perspectiveOffCenter(
        left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float
    ) -> simd_float4x4 {
        let x = 2 * near / (right - left)
        let y = 2 * near / (top - bottom)
        let a = (right + left) / (right - left)
        let b = (top + bottom) / (top - bottom)
        let c = -(far + near) / (far - near)
        let d = -(2 * far * near) / (far - near)

        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(a, b, c, -1),
            SIMD4<Float>(0, 0, d, 0)
        ))
    }

    /// Project a point in the screen frame to normalised device coordinates.
    public func project(point: SIMD3<Float>, head: SIMD3<Float>) -> SIMD3<Float> {
        let eyeSpace = SIMD4<Float>(point - head, 1)
        let clip = projectionMatrix(head: head) * eyeSpace
        return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
    }
}

