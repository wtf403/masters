import Foundation
import Testing
import simd
@testable import ParallaxKit

private func pose(at time: TimeInterval, x: Float = 0) -> HeadPose {
    var transform = matrix_identity_float4x4
    transform.columns.3 = SIMD4<Float>(x, 0, 0, 1)
    return HeadPose(transform: transform, interpupillaryDistance: 0.064, timestamp: time)
}

@Test func emptyBufferHasNoPose() {
    let buffer = PoseBuffer(capacity: 4)
    #expect(buffer.isEmpty)
    #expect(buffer.latest == nil)
    #expect(buffer.earliest == nil)
    #expect(buffer.pose(nearestTo: 0) == nil)
}

@Test func bufferReportsInsertionOrderAndEndpoints() {
    var buffer = PoseBuffer(capacity: 4)
    for i in 0..<3 { buffer.append(pose(at: TimeInterval(i))) }

    #expect(buffer.count == 3)
    #expect(buffer.earliest?.timestamp == 0)
    #expect(buffer.latest?.timestamp == 2)
    #expect(buffer.poses.map(\.timestamp) == [0, 1, 2])
}

/// Once the buffer is full the oldest samples drop out, which is what keeps the
/// lookup bounded during a long session.
@Test func bufferDropsOldestWhenFull() {
    var buffer = PoseBuffer(capacity: 3)
    for i in 0..<5 { buffer.append(pose(at: TimeInterval(i))) }

    #expect(buffer.count == 3)
    #expect(buffer.poses.map(\.timestamp) == [2, 3, 4])
    #expect(buffer.earliest?.timestamp == 2)
    #expect(buffer.latest?.timestamp == 4)
}

/// The reason the buffer exists: a frame is drawn with the pose that belongs to it,
/// not with whatever arrived most recently.
@Test func nearestLookupPicksTheClosestPoseInBothDirections() {
    var buffer = PoseBuffer(capacity: 8)
    for i in 0..<5 { buffer.append(pose(at: TimeInterval(i) * 0.1)) }

    #expect(buffer.pose(nearestTo: 0.21)?.timestamp == 0.2)
    #expect(buffer.pose(nearestTo: 0.24)?.timestamp == 0.2)
    // 3 * 0.1 is not exactly 0.3 in binary floating point, so compare near it.
    let third = buffer.pose(nearestTo: 0.26)?.timestamp ?? 0
    #expect(abs(third - 0.3) < 1e-9)
}

/// A request newer than everything held returns the newest sample, and one older
/// than everything returns the oldest, so the caller always has something to draw.
@Test func nearestLookupClampsOutsideTheRetainedRange() {
    var buffer = PoseBuffer(capacity: 8)
    for i in 0..<3 { buffer.append(pose(at: TimeInterval(i) * 0.1)) }

    #expect(buffer.pose(nearestTo: 99)?.timestamp == 0.2)
    #expect(buffer.pose(nearestTo: -99)?.timestamp == 0)
}

@Test func atOrBeforeNeverReturnsAFuturePose() {
    var buffer = PoseBuffer(capacity: 8)
    for i in 0..<5 { buffer.append(pose(at: TimeInterval(i) * 0.1)) }

    #expect(buffer.pose(atOrBefore: 0.25)?.timestamp == 0.2)
    #expect(buffer.pose(atOrBefore: 0.2)?.timestamp == 0.2)
    // Before the oldest sample there is nothing usable, so the oldest is returned.
    #expect(buffer.pose(atOrBefore: -1)?.timestamp == 0)
}

@Test func clearingRemovesEverything() {
    var buffer = PoseBuffer(capacity: 4)
    buffer.append(pose(at: 1))
    buffer.removeAll()
    #expect(buffer.isEmpty)
    #expect(buffer.latest == nil)
}

/// ARKit's camera space puts the scene at negative z, while the projection expects
/// the viewer at positive z.
@Test func screenFrameFlipsZButKeepsLateralDirection() {
    var transform = matrix_identity_float4x4
    transform.columns.3 = SIMD4<Float>(0.03, -0.02, -0.5, 1)
    let pose = HeadPose(transform: transform, interpupillaryDistance: 0.064, timestamp: 0)

    let screen = pose.screenFramePosition
    #expect(screen.x == 0.03)
    #expect(screen.y == -0.02)
    #expect(screen.z == 0.5)
}

/// Eyes are offset along the head's own x axis, so a rotated head puts them on a
/// rotated baseline rather than on the world x axis.
@Test func eyePositionsFollowTheHeadOrientation() {
    var transform = matrix_identity_float4x4
    transform.columns.0 = SIMD4<Float>(0, 1, 0, 0)   // head x axis now points up
    transform.columns.3 = SIMD4<Float>(0, 0, 0, 1)
    let pose = HeadPose(transform: transform, interpupillaryDistance: 0.06, timestamp: 0)

    let left = pose.eyePosition(.left)
    let right = pose.eyePosition(.right)
    #expect(abs((right.y - left.y) - 0.06) < 1e-5)
    #expect(abs(left.x - right.x) < 1e-5)
}
