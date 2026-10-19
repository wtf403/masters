import Foundation
import simd

/// A single head pose sample, in device space.
///
/// ARKit face anchors are mirrored in x, so the tracker negates x when building
/// this value. That mirroring is a property of the anchor, not a quirk to work
/// around per call site.
public struct HeadPose: Sendable, Equatable {
    /// Head anchor transform in device space, already mirror-corrected.
    public var transform: simd_float4x4
    /// Interpupillary distance in metres, measured from the eye transforms.
    public var interpupillaryDistance: Float
    /// ARFrame timestamp the pose was sampled at.
    public var timestamp: TimeInterval
    /// False when tracking has been lost and the pose is a held-over value.
    public var isTracked: Bool

    public init(
        transform: simd_float4x4,
        interpupillaryDistance: Float,
        timestamp: TimeInterval,
        isTracked: Bool = true
    ) {
        self.transform = transform
        self.interpupillaryDistance = interpupillaryDistance
        self.timestamp = timestamp
        self.isTracked = isTracked
    }

    /// Head position in device space, metres.
    public var position: SIMD3<Float> {
        SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// Left eye position in device space, derived by offsetting along the head's x axis.
    public func eyePosition(_ eye: Eye) -> SIMD3<Float> {
        let axis = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let half = interpupillaryDistance * 0.5
        return position + axis * (eye == .left ? -half : half)
    }

    /// Head position in the projection's screen frame, metres.
    ///
    /// ARKit's camera space puts the scene in front of the camera at negative z, while
    /// the projection expects the viewer at positive z looking down -z at a screen in
    /// the plane z = 0. Flipping z is the whole conversion; x and y already point right
    /// and up in both frames. Doing it here rather than at each call site keeps the
    /// sign convention in one place.
    public var screenFramePosition: SIMD3<Float> {
        SIMD3<Float>(position.x, position.y, -position.z)
    }

    public enum Eye: Sendable, Equatable, CaseIterable {
        case left
        case right
    }

    /// Neutral pose used before tracking starts.
    public static let unknown = HeadPose(
        transform: matrix_identity_float4x4,
        interpupillaryDistance: 0.064,
        timestamp: 0,
        isTracked: false
    )
}

