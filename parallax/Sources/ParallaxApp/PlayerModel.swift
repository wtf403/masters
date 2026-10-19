#if os(iOS)
import Foundation
import Combine
import QuartzCore
import UIKit
import AVFoundation
import ParallaxKit

/// Settings the player chrome exposes, mirroring the original app's sliders.
struct PlayerSettings: Equatable, Sendable {
    /// 1 is the authored amount of parallax, 0 flattens the effect.
    var parallaxScale: Float = 1
    /// Distance between the screen and the content plane, metres.
    var planeDistance: Float = 0.35
    var renderPath: RenderPath = .projectedPlane
    var debugMode: DebugMode = .off
    /// User-tuned screen size correction, applied on top of the panel table.
    var calibrationMultiplier: Float = 1
}

/// Carries poses from the tracking queue to the renderer.
///
/// ARKit calls back on its own serial queue while drawing happens on the main thread,
/// so the handoff needs a buffer that both can touch. The buffer is also what lets the
/// renderer ask for the pose that belongs to a given video frame rather than the pose
/// that happens to be newest.
final class PoseRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = PoseBuffer(capacity: 240)
    private var tracked = false

    func record(_ pose: HeadPose) {
        lock.lock()
        buffer.append(pose)
        tracked = pose.isTracked
        lock.unlock()
    }

    func recordTracking(_ isTracked: Bool) {
        lock.lock()
        tracked = isTracked
        lock.unlock()
    }

    var latest: HeadPose? {
        lock.lock(); defer { lock.unlock() }
        return buffer.latest
    }

    var isTracked: Bool {
        lock.lock(); defer { lock.unlock() }
        return tracked
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    func pose(nearestTo timestamp: TimeInterval) -> HeadPose? {
        lock.lock(); defer { lock.unlock() }
        return buffer.pose(nearestTo: timestamp)
    }
}

/// Bridges the display link's target/action to a closure.
final class DisplayLinkProxy: NSObject {
    var onTick: ((CFTimeInterval) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onTick?(link.timestamp)
    }
}

/// The observable app state.
///
/// This uses `ObservableObject` rather than the newer `@Observable` macro because the
/// macro requires the Swift plugin server, which cannot run in every build
/// environment. Nothing here depends on which mechanism notifies SwiftUI, so moving to
/// `@Observable` later is a mechanical change.
@MainActor
final class PlayerModel: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading(String)
        case playing(String)
        case failed(String)

        var clipName: String? {
            switch self {
            case .loading(let name), .playing(let name): name
            case .idle, .failed: nil
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var clips: [ClipItem] = []
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var isTracking = false
    @Published private(set) var poseCount = 0
    @Published private(set) var eyeDistance: Float?
    @Published private(set) var deviceIdentifier: String?

    let renderer: ParallaxRenderer?
    @Published private(set) var rendererError: String?
    @Published private(set) var trackingUnavailable = false

    @Published var settings = PlayerSettings() {
        didSet { applySettings() }
    }

    @Published var isPlaying = false {
        didSet { displayLink?.isPaused = !isPlaying }
    }

    private let tracker = ARKitHeadTracker()
    private let relay = PoseRelay()
    private var reader: MovieClipReader?
    private var playbackTime: TimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    /// System clock time that corresponds to video time zero. ARKit timestamps and
    /// video timestamps come from different clocks, so pairing a frame with a pose
    /// needs this offset. It is recomputed whenever playback restarts or seeks.
    private var streamOrigin: TimeInterval?
    private let displayLinkProxy = DisplayLinkProxy()
    private var displayLink: CADisplayLink?

    init() {
        deviceIdentifier = ScreenMetrics.machineIdentifier()
        let projection = OffAxisProjection(
            screen: ScreenMetrics.current().screen(for: .landscape),
            nearPlane: 0.01,
            farPlane: 10
        )
        do {
            renderer = try ParallaxRenderer(projection: projection)
        } catch {
            renderer = nil
            rendererError = "\(error)"
        }
        clips = ClipLibrary.clips()

        displayLinkProxy.onTick = { [weak self] timestamp in
            MainActor.assumeIsolated { self?.tick(timestamp) }
        }
    }

    // MARK: - Clips

    func refreshClips() {
        clips = ClipLibrary.clips()
    }

    func open(_ clip: ClipItem) async {
        pause()
        reader = nil
        status = .loading(clip.name)

        do {
            let reader = try await MovieClipReader.open(url: clip.url)
            try reader.start()
            self.reader = reader
            duration = reader.duration
            playbackTime = 0
            progress = 0
            streamOrigin = nil
            status = .playing(clip.name)
            isPlaying = true
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func seek(toProgress value: Double) {
        guard let reader, duration > 0 else { return }
        let time = duration * min(max(value, 0), 1)
        do {
            try reader.start(at: time)
            playbackTime = time
            progress = duration > 0 ? time / duration : 0
            streamOrigin = nil
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func togglePlayback() { isPlaying.toggle() }

    func pause() { isPlaying = false }

    // MARK: - Tracking

    func startTracking() {
        guard tracker.isSupported else {
            trackingUnavailable = true
            return
        }
        trackingUnavailable = false

        let relay = self.relay
        // The callbacks arrive on the tracker's own queue, so they may only touch the
        // relay, which is safe from any thread.
        tracker.onPose = { pose in relay.record(pose) }
        tracker.onTrackingStateChange = { tracked in relay.recordTracking(tracked) }

        do {
            try tracker.start()
        } catch {
            trackingUnavailable = true
        }
    }

    func stopTracking() {
        tracker.stop()
    }

    /// Re-centre the window on wherever the viewer is holding their head.
    func resetCentre() {
        tracker.reset()
    }

    // MARK: - Frame loop

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = 0
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        isPlaying = false
    }

    private func tick(_ timestamp: CFTimeInterval) {
        defer { lastTick = timestamp }
        poseCount = relay.count
        isTracking = relay.isTracked
        eyeDistance = relay.latest?.interpupillaryDistance

        guard let reader, let renderer else { return }

        let step = lastTick == 0 ? 1.0 / 60.0 : min(max(timestamp - lastTick, 0), 0.25)
        if isPlaying { playbackTime += step }

        // Decoding on the main thread is a placeholder: the decode workstream moves
        // this onto its own queue and hands finished frames over.
        guard let frame = try? reader.frame(at: playbackTime) else { return }
        renderer.enqueue(frame: frame)

        if let origin = streamOrigin ?? streamOriginFor(playing: frame.presentationTime) {
            renderer.update(headPose: relay.pose(nearestTo: origin + frame.presentationTime))
        } else {
            renderer.update(headPose: relay.latest)
        }

        if duration > 0 {
            progress = min(max(playbackTime / duration, 0), 1)
        }
    }

    private func streamOriginFor(playing videoTime: TimeInterval) -> TimeInterval? {
        let origin = CACurrentMediaTime() - videoTime
        streamOrigin = origin
        return origin
    }

    private func applySettings() {
        guard let renderer else { return }
        renderer.parallaxScale = settings.parallaxScale
        renderer.planeDistance = settings.planeDistance
        renderer.renderPath = settings.renderPath
        renderer.debugMode = settings.debugMode

        let metrics = ScreenMetrics.current(calibrationMultiplier: settings.calibrationMultiplier)
        renderer.projection = OffAxisProjection(
            screen: metrics.screen(for: .landscape),
            nearPlane: renderer.projection.nearPlane,
            farPlane: renderer.projection.farPlane
        )
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let read as ClipReadError:
            switch read {
            case .noVideoTrack: "That file has no video track."
            case .cannotCreateReader(let detail): "Could not read that file. \(detail)"
            case .cannotCreateOutput: "Could not decode that file's video track."
            case .readerFailed(let detail): "Decoding stopped. \(detail)"
            case .notStarted: "Playback was not started."
            }
        default:
            "\(error)"
        }
    }
}
#endif
