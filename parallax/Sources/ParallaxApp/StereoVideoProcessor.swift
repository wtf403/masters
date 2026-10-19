#if os(iOS)
import Foundation
import CoreVideo
import CoreImage
import ParallaxKit

/// AVFoundation owns these immutable decoded buffers. Retaining the pair keeps
/// them alive across the actor hop; neither caller nor worker mutates their pixels.
struct StereoVideoPair: @unchecked Sendable {
    let left: CVPixelBuffer
    let right: CVPixelBuffer
}

struct ProcessedStereoVideoFrame: Sendable {
    let colour: CGImage
    let vertices: [SIMD3<Float>]
    let confidence: Int
}

/// GPU waits and depth filtering must not block the main actor's eye-pose updates.
actor StereoVideoProcessor {
    private var matcher: LiveStereoDepth?
    private let context = CIContext()
    private var smoothed = [Float](repeating: 0.5, count: 96*54)
    private var lower: Float?
    private var upper: Float?

    func process(_ pair: StereoVideoPair, strength: Float) throws -> ProcessedStereoVideoFrame {
        if matcher == nil { matcher = try LiveStereoDepth() }
        guard let matcher else { throw LiveStereoDepth.Failure.unavailable }
        let values = try matcher.disparity(left: pair.left, right: pair.right)
        let valid = values.filter { $0.y > 0 }.map(\.x).sorted()
        var depth = smoothed
        if valid.count > values.count/20 {
            let lo = valid[valid.count/10], hi = valid[valid.count*9/10]
            lower = lower.map { $0*0.95+lo*0.05 } ?? lo
            upper = upper.map { $0*0.95+hi*0.05 } ?? hi
            let minD = lower ?? lo, span = max((upper ?? hi)-minD, 2)
            for i in values.indices where values[i].y > 0 {
                depth[i] = min(max((values[i].x-minD)/span,0),1)
            }
        }
        for y in 0..<54 { for x in 0..<96 {
            var sum: Float = 0; var count: Float = 0
            for dy in -1...1 { for dx in -1...1 {
                sum += depth[min(max(y+dy,0),53)*96+min(max(x+dx,0),95)]
                count += 1
            } }
            let i = y*96+x
            smoothed[i] = smoothed[i]*0.35 + sum/count*0.65
        } }
        let image = CIImage(cvPixelBuffer: pair.left)
        guard let colour = context.createCGImage(image, from: image.extent) else { throw LiveStereoDepth.Failure.texture }
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(96*54)
        for y in 0..<54 { for x in 0..<96 {
            let d = (0.12-0.10*smoothed[y*96+x])*strength
            let grow = (0.4+d)/0.4
            vertices.append(SIMD3<Float>((Float(x)/95-0.5)*0.135*grow,
                                        (0.5-Float(y)/53)*0.062*grow,-d))
        } }
        return ProcessedStereoVideoFrame(colour: colour, vertices: vertices, confidence: valid.count*100/values.count)
    }
}
#endif
