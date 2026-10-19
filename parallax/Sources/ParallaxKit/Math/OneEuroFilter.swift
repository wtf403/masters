import Foundation
import simd

/// One-euro filter for a scalar signal.
///
/// A fixed low-pass trades latency against jitter, which is the wrong trade for
/// head tracking: the pose should be steady while the viewer holds still and
/// responsive the moment they move. The one-euro filter adapts its cutoff to the
/// signal's speed, so it gives both.
public struct OneEuroFilter: Sendable {
    public var minimumCutoff: Float
    public var beta: Float
    public var derivativeCutoff: Float

    private var previous: Float?
    private var previousDerivative: Float = 0

    public init(minimumCutoff: Float = 1.0, beta: Float = 0.007, derivativeCutoff: Float = 1.0) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public static func alpha(cutoff: Float, deltaTime: Float) -> Float {
        let tau = 1 / (2 * Float.pi * max(cutoff, 1e-6))
        return 1 / (1 + tau / max(deltaTime, 1e-6))
    }

    public mutating func filter(_ value: Float, deltaTime: Float) -> Float {
        guard let previous else {
            self.previous = value
            return value
        }

        let derivative = (value - previous) / max(deltaTime, 1e-6)
        let derivativeAlpha = OneEuroFilter.alpha(cutoff: derivativeCutoff, deltaTime: deltaTime)
        let smoothedDerivative = derivativeAlpha * derivative + (1 - derivativeAlpha) * previousDerivative
        previousDerivative = smoothedDerivative

        let cutoff = minimumCutoff + beta * abs(smoothedDerivative)
        let alpha = OneEuroFilter.alpha(cutoff: cutoff, deltaTime: deltaTime)
        let result = alpha * value + (1 - alpha) * previous
        self.previous = result
        return result
    }

    public mutating func reset() {
        previous = nil
        previousDerivative = 0
    }
}

/// One-euro filter for a 3-vector, used for head position and rotation.
public struct OneEuroFilter3: Sendable {
    private var x: OneEuroFilter
    private var y: OneEuroFilter
    private var z: OneEuroFilter

    public init(minimumCutoff: Float = 1.0, beta: Float = 0.007, derivativeCutoff: Float = 1.0) {
        x = OneEuroFilter(minimumCutoff: minimumCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        y = OneEuroFilter(minimumCutoff: minimumCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        z = OneEuroFilter(minimumCutoff: minimumCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    public mutating func filter(_ value: SIMD3<Float>, deltaTime: Float) -> SIMD3<Float> {
        SIMD3<Float>(
            x.filter(value.x, deltaTime: deltaTime),
            y.filter(value.y, deltaTime: deltaTime),
            z.filter(value.z, deltaTime: deltaTime)
        )
    }

    public mutating func reset() {
        x.reset()
        y.reset()
        z.reset()
    }
}

