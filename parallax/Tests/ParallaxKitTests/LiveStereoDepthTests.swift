import Testing
import CoreVideo
import Metal
@testable import ParallaxKit

@Test(arguments: [-4, 4])
func liveMatcherRecoversSignedDisparity(shift: Int) throws {
    let width = 192, height = 108
    func pixelBuffer(offset: Int) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                       kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                   attributes as CFDictionary, &output) == kCVReturnSuccess)
        let buffer = try #require(output)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let xx = min(max(x+offset,0),width-1)
            let value = UInt8(truncatingIfNeeded: (xx &* 73856093) ^ (y &* 19349663) ^ ((xx*y) &* 83492791))
            for c in 0..<3 { bytes[y*stride+x*4+c] = value }
            bytes[y*stride+x*4+3] = 255
        } }
        return buffer
    }
    let matcher = try LiveStereoDepth()
    let result = try matcher.disparity(left: pixelBuffer(offset: 0), right: pixelBuffer(offset: shift))
    let interior = result.enumerated().filter { i, value in
        i % 96 > 12 && i % 96 < 84 && i / 96 > 5 && i / 96 < 49 && value.y > 0
    }.map { $0.element.x }.sorted()
    #expect(interior.count > 2000)
    #expect(abs(try #require(interior.dropFirst(interior.count/2).first) - Float(shift)) < 0.5)
}
