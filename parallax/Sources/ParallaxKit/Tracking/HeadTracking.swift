import Foundation

/// Source of head pose samples.
///
/// Implementations own a capture session and publish poses. Callers should not
/// assume the callback arrives on the main thread.
public protocol HeadTracking: AnyObject {
    /// Whether this device can run the tracker at all.
    var isSupported: Bool { get }
    /// Most recent pose, or nil before the first sample.
    var latestPose: HeadPose? { get }
    /// Called for each pose update. Set before calling start.
    var onPose: ((HeadPose) -> Void)? { get set }
    /// Called when tracking is lost or regained.
    var onTrackingStateChange: ((Bool) -> Void)? { get set }

    func start() throws
    func stop()
    /// Re-centre, treating the current pose as the neutral one.
    func reset()
}

public enum HeadTrackingError: Error, Equatable {
    case unsupportedDevice
    case cameraPermissionDenied
    case sessionFailed(String)
}

