import Testing
import simd
@testable import ParallaxKit

@Test func constantSignalPassesThrough() {
    var filter = OneEuroFilter()
    var value: Float = 0
    for _ in 0..<100 { value = filter.filter(0.25, deltaTime: 1.0 / 60) }
    #expect(abs(value - 0.25) < 1e-3)
}

@Test func jitterIsSuppressed() {
    var filter = OneEuroFilter(minimumCutoff: 1.0, beta: 0.007)
    var raw: [Float] = []
    var filtered: [Float] = []

    // A slow drift with alternating noise on top, which is the shape of a real
    // head-tracking signal when the viewer is holding still.
    var t: Float = 0
    for i in 0..<240 {
        let noise: Float = (i % 2 == 0) ? 0.01 : -0.01
        let sample = t + noise
        raw.append(sample)
        filtered.append(filter.filter(sample, deltaTime: 1.0 / 60))
        t += 0.0005
    }

    func spread(_ values: [Float]) -> Float {
        let tail = values.dropFirst(60)
        guard let low = tail.min(), let high = tail.max() else { return 0 }
        return high - low
    }

    #expect(spread(filtered) < spread(raw))
}

/// A step must be approached monotonically, without overshoot, and must settle.
@Test func stepResponseIsMonotonicAndSettles() {
    var filter = OneEuroFilter()
    _ = filter.filter(0, deltaTime: 1.0 / 60)

    var previous: Float = 0
    for _ in 0..<120 {
        let value = filter.filter(0.4, deltaTime: 1.0 / 60)
        #expect(value >= previous)
        #expect(value <= 0.4)
        previous = value
    }
    #expect(abs(previous - 0.4) < 0.01)
}

/// The tunable that makes the filter useful: raising beta lowers lag on a moving
/// signal while leaving the steady state alone.
@Test func higherBetaReducesLagOnARamp() {
    var sluggish = OneEuroFilter(minimumCutoff: 1.0, beta: 0.001)
    var responsive = OneEuroFilter(minimumCutoff: 1.0, beta: 0.5)
    _ = sluggish.filter(0, deltaTime: 1.0 / 60)
    _ = responsive.filter(0, deltaTime: 1.0 / 60)

    var target: Float = 0
    for _ in 0..<60 {
        target += 0.005
        _ = sluggish.filter(target, deltaTime: 1.0 / 60)
        _ = responsive.filter(target, deltaTime: 1.0 / 60)
    }

    let sluggishLag = abs(sluggish.filter(target, deltaTime: 1.0 / 60) - target)
    let responsiveLag = abs(responsive.filter(target, deltaTime: 1.0 / 60) - target)
    #expect(responsiveLag < sluggishLag)
}

@Test func resetClearsHistory() {
    var filter = OneEuroFilter()
    _ = filter.filter(10, deltaTime: 1.0 / 60)
    filter.reset()
    let value = filter.filter(0, deltaTime: 1.0 / 60)
    #expect(value == 0)
}

@Test func vectorFilterMovesEachAxisIndependently() {
    var filter = OneEuroFilter3()
    var value: SIMD3<Float> = .zero
    for _ in 0..<200 {
        value = filter.filter(SIMD3<Float>(1, -2, 0.5), deltaTime: 1.0 / 60)
    }
    #expect(abs(value.x - 1) < 1e-2)
    #expect(abs(value.y - (-2)) < 1e-2)
    #expect(abs(value.z - 0.5) < 1e-2)
}

