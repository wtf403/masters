#if os(iOS) && canImport(ARKit)
import Foundation
import ARKit
import simd

/// How the tracker asks ARKit for face anchors.
///
/// Both modes deliver ARFaceAnchor updates, so everything downstream of the anchor is
/// shared between them. They differ in which camera ARKit uses and, more importantly,
/// in the coordinate frame it reports the face in.
public enum ARKitHeadTrackerMode: Sendable, Equatable, CaseIterable {
    /// ARFaceTrackingConfiguration. Needs a TrueDepth front camera, and reports the
    /// face in device space, so head movement is measured relative to the phone.
    case faceTracking
    /// ARWorldTrackingConfiguration with userFaceTrackingEnabled. This is the fallback
    /// for devices with no TrueDepth camera, such as the SE line and most iPads. The
    /// anchor is reported in world space, so the pose only means anything relative to
    /// where tracking started: call reset once the viewer is settled to set that
    /// reference, and the recentred pose behaves like device space thereafter.
    case worldTrackingWithUserFace
    /// Face tracking when the device supports it, otherwise world tracking with a user
    /// face. This is the default, so more devices get a working window.
    case automatic
}

/// Head tracking backed by ARKit face tracking.
///
/// The delegate runs on a private serial queue rather than the main thread, and the
/// published state is guarded by a lock, so the renderer can read the latest pose
/// without waiting on the main actor.
public final class ARKitHeadTracker: NSObject, HeadTracking, @unchecked Sendable {

    /// Requested configuration. automatic is resolved against the device.
    public let mode: ARKitHeadTrackerMode

    private let session = ARSession()
    private let queue = DispatchQueue(label: "parallax.arkit.tracking", qos: .userInteractive)
    private let lock = NSLock()

    private var storedPose: HeadPose?
    private var storedOnPose: ((HeadPose) -> Void)?
    private var storedOnStateChange: ((Bool) -> Void)?
    private var wasTracked = false

    /// Pose treated as neutral. Reset captures the current pose here so the viewer
    /// can recentre without moving their head to a particular spot.
    private var referenceTransform: simd_float4x4?

    public init(mode: ARKitHeadTrackerMode = .automatic) {
        self.mode = mode
        super.init()
        session.delegate = self
        // ARKit delivers delegate callbacks on the queue passed at construction time,
        // which must be set before the session starts delivering frames.
        session.delegateQueue = queue
    }

    /// The concrete mode in use, or nil when this device supports neither mode.
    public var resolvedMode: ARKitHeadTrackerMode? {
        switch mode {
        case .faceTracking:
            return ARFaceTrackingConfiguration.isSupported ? .faceTracking : nil
        case .worldTrackingWithUserFace:
            return ARWorldTrackingConfiguration.supportsUserFaceTracking ? .worldTrackingWithUserFace : nil
        case .automatic:
            if ARFaceTrackingConfiguration.isSupported { return .faceTracking }
            if ARWorldTrackingConfiguration.supportsUserFaceTracking { return .worldTrackingWithUserFace }
            return nil
        }
    }

    /// True when some usable face-tracking configuration exists on this device.
    public var isSupported: Bool { resolvedMode != nil }

    public var latestPose: HeadPose? {
        lock.lock(); defer { lock.unlock() }
        return storedPose
    }

    public var onPose: ((HeadPose) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnPose }
        set { lock.lock(); storedOnPose = newValue; lock.unlock() }
    }

    public var onTrackingStateChange: ((Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnStateChange }
        set { lock.lock(); storedOnStateChange = newValue; lock.unlock() }
    }

    public func start() throws {
        switch resolvedMode {
        case .faceTracking:
            let configuration = ARFaceTrackingConfiguration()
            configuration.maximumNumberOfTrackedFaces = 1
            configuration.isLightEstimationEnabled = false
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        case .worldTrackingWithUserFace:
            let configuration = ARWorldTrackingConfiguration()
            configuration.userFaceTrackingEnabled = true
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        case nil, .automatic:
            throw HeadTrackingError.unsupportedDevice
        }
    }

    public func stop() {
        session.pause()
    }

    /// Treat the pose the viewer is holding right now as the neutral one.
    public func reset() {
        lock.lock()
        referenceTransform = storedPose.map(\HeadPose.transform)
        lock.unlock()
    }

    // MARK: - Pose conversion

    /// ARKit face anchors are mirrored in x relative to the render space we want.
    /// This is a documented property of the anchor, so it is corrected once here
    /// instead of at every use site.
    static func mirrorX(_ matrix: simd_float4x4) -> simd_float4x4 {
        let reflection = simd_float4x4(diagonal: SIMD4<Float>(-1, 1, 1, 1))
        return reflection * matrix * reflection
    }

    private func makePose(from face: ARFaceAnchor, timestamp: TimeInterval) -> HeadPose {
        let mirrored = ARKitHeadTracker.mirrorX(face.transform)
        let relative = referenceTransform.map { simd_inverse($0) * mirrored } ?? mirrored

        // Interpupillary distance is measured from the eye transforms, so it is a
        // real value rather than one guessed from blend shapes as in the original.
        let left = face.leftEyeTransform.columns.3
        let right = face.rightEyeTransform.columns.3

        return HeadPose(
            transform: relative,
            interpupillaryDistance: simd_distance(left, right),
            timestamp: timestamp,
            isTracked: face.isTracked
        )
    }

    private func publish(_ pose: HeadPose) {
        lock.lock()
        storedPose = pose
        let callback = storedOnPose
        let stateCallback = wasTracked == pose.isTracked ? nil : storedOnStateChange
        wasTracked = pose.isTracked
        lock.unlock()

        callback?(pose)
        if let stateCallback { stateCallback(pose.isTracked) }
    }
}

extension ARKitHeadTracker: ARSessionDelegate {

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        let timestamp = session.currentFrame?.timestamp ?? ProcessInfo.processInfo.systemUptime
        publish(makePose(from: face, timestamp: timestamp))
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        lock.lock()
        let callback = storedOnStateChange
        let wasTrackedBefore = wasTracked
        wasTracked = false
        lock.unlock()
        if wasTrackedBefore { callback?(false) }
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        lock.lock()
        let callback = wasTracked ? storedOnStateChange : nil
        wasTracked = false
        lock.unlock()
        callback?(false)
    }
}
#endif
