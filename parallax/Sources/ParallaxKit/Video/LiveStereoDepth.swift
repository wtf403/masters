import Foundation
import Metal
import CoreVideo

/// Small GPU block matcher for rectified stereo. Returns relative disparity,
/// not calibrated metric depth. Negative disparities are allowed in spatial video.
public final class LiveStereoDepth {
    public let width = 96
    public let height = 54
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let result: MTLBuffer
    private var cache: CVMetalTextureCache
    public enum Failure: Error { case unavailable, texture, compute }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: 96 * 54 * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared) else { throw Failure.unavailable }
        self.device = device
        self.queue = queue
        result = buffer
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw Failure.unavailable }
        self.cache = cache
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "stereo") else { throw Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    public func disparity(left: CVPixelBuffer, right: CVPixelBuffer) throws -> [SIMD2<Float>] {
        func texture(_ pixel: CVPixelBuffer) throws -> CVMetalTexture {
            var value: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixel, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 0, &value) == kCVReturnSuccess,
                let value else { throw Failure.texture }
            return value
        }
        let l = try texture(left), r = try texture(right)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw Failure.compute }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(CVMetalTextureGetTexture(l), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(r), index: 1)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? Failure.compute }
        return withExtendedLifetime((l, r)) {
            Array(UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: SIMD2<Float>.self), count: width * height))
        }
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void stereo(texture2d<float> left [[texture(0)]], texture2d<float> right [[texture(1)]],
                       device float2 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= 96 || p.y >= 54) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = float2(p) / float2(95,53);
        float best = 1e9, second = 1e9, disparity = 0;
        // Search +/- 6.25% of eye width at a 192-pixel matching resolution.
        for (int d = -12; d <= 12; ++d) {
            float cost = 0;
            if (uv.x - float(d)/192 < 0 || uv.x - float(d)/192 > 1) continue;
            for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {
                float2 a = uv + float2(x,y)/float2(192,108);
                float3 lc = left.sample(s,a).rgb;
                float3 rc = right.sample(s,a-float2(float(d)/192,0)).rgb;
                cost += dot(abs(lc-rc),float3(0.299,0.587,0.114));
            }
            if (cost < best) { second = best; best = cost; disparity = d; }
            else second = min(second,cost);
        }
        float confidence = (second-best)/max(second,0.0001);
        out[p.y*96+p.x] = float2(disparity, best/25 < 0.15 && confidence > 0.025 ? 1.0 : 0.0);
    }
    """#
}
