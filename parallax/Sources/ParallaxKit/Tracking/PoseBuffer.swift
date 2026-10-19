import Foundation
import simd

/// A fixed-capacity ring of head poses, indexable by time.
///
/// The renderer and the video decoder run on different clocks, so a pose is never
/// consumed at the instant it arrives. The renderer asks for the pose that belongs
/// to the frame it is about to present, and this buffer answers that question.
/// Mismatched pairing shows up as judder that reads like bad tracking, which is why
/// the lookup is by presentation timestamp rather than "whatever arrived latest".
public struct PoseBuffer: Sendable {

    private var storage: [HeadPose?]
    private var nextIndex: Int = 0
    private var filled: Int = 0

    /// Number of poses retained. At 60 Hz this holds roughly two seconds, which is
    /// more than the worst-case presentation latency we expect to bridge.
    public let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = max(capacity, 1)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    public var count: Int { filled }
    public var isEmpty: Bool { filled == 0 }

    public mutating func append(_ pose: HeadPose) {
        storage[nextIndex] = pose
        nextIndex = (nextIndex + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    /// Poses in insertion order, oldest first.
    public var poses: [HeadPose] {
        let start = filled == capacity ? nextIndex : 0
        return (0..<filled).compactMap { storage[(start + $0) % capacity] }
    }

    /// Most recently appended pose.
    public var latest: HeadPose? {
        guard filled > 0 else { return nil }
        let index = (nextIndex - 1 + capacity) % capacity
        return storage[index]
    }

    /// Oldest pose still retained.
    public var earliest: HeadPose? {
        guard filled > 0 else { return nil }
        let start = filled == capacity ? nextIndex : 0
        return storage[start]
    }

    /// The pose whose timestamp is closest to the requested time.
    ///
    /// Returns nil only when the buffer is empty. Callers that care whether the
    /// match was close should compare the returned pose's timestamp against the
    /// requested time themselves; a stale-but-closest pose is still the right thing
    /// to draw with when the decoder falls behind.
    public func pose(nearestTo timestamp: TimeInterval) -> HeadPose? {
        var best: HeadPose?
        var bestDelta = TimeInterval.greatestFiniteMagnitude
        for pose in poses {
            let delta = abs(pose.timestamp - timestamp)
            if delta < bestDelta {
                bestDelta = delta
                best = pose
            }
        }
        return best
    }

    /// Pose at or before the requested time, which is what a low-latency renderer
    /// can actually use: predicting ahead is a later optimisation. Falls back to
    /// the earliest retained pose when every sample is newer than the request.
    public func pose(atOrBefore timestamp: TimeInterval) -> HeadPose? {
        var best: HeadPose?
        for pose in poses where pose.timestamp <= timestamp {
            if let current = best {
                if pose.timestamp > current.timestamp { best = pose }
            } else {
                best = pose
            }
        }
        return best ?? earliest
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        nextIndex = 0
        filled = 0
    }
}
