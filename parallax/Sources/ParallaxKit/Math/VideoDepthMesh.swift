import Foundation
import simd

public struct VideoDepthMetadata: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let fps: Double
    public let nearDepth: Float
    public let farDepth: Float
    public let referenceEyeDistance: Float
}

/// A video-aligned 2.5D surface. Depth is relative stereo relief, not metric capture.
public struct VideoDepthMesh: Sendable {
    public enum LoadError: Error { case invalidMetadata, invalidByteCount }
    public let metadata: VideoDepthMetadata
    private let bytes: [UInt8]

    public init(metadata: VideoDepthMetadata, data: Data) throws {
        guard metadata.width > 1, metadata.width <= 1024,
              metadata.height > 1, metadata.height <= 1024,
              metadata.frameCount > 0, metadata.frameCount <= 100_000,
              metadata.fps.isFinite, metadata.fps > 0,
              metadata.nearDepth.isFinite, metadata.farDepth.isFinite,
              metadata.nearDepth > 0, metadata.farDepth > metadata.nearDepth,
              metadata.referenceEyeDistance.isFinite, metadata.referenceEyeDistance > 0 else {
            throw LoadError.invalidMetadata
        }
        guard data.count == metadata.width * metadata.height * metadata.frameCount else {
            throw LoadError.invalidByteCount
        }
        self.metadata = metadata
        bytes = Array(data)
    }

    public func vertices(frame: Int) -> [SIMD3<Float>] {
        let m = metadata
        let offset = min(max(frame, 0), m.frameCount - 1) * m.width * m.height
        return (0..<(m.width * m.height)).map { index in
            let u = Float(index % m.width) / Float(m.width - 1)
            let v = Float(index / m.width) / Float(m.height - 1)
            let closeness = Float(bytes[offset + index]) / 255
            let depth = m.farDepth + (m.nearDepth - m.farDepth) * closeness
            // Unproject along the source camera ray so the neutral view matches the video.
            let scale = (m.referenceEyeDistance + depth) / m.referenceEyeDistance
            return SIMD3<Float>((u - 0.5) * 0.135 * scale,
                                (0.5 - v) * 0.062 * scale, -depth)
        }
    }

    public var textureCoordinates: [SIMD2<Float>] {
        (0..<(metadata.width * metadata.height)).map { index in
            SIMD2<Float>(Float(index % metadata.width) / Float(metadata.width - 1),
                         Float(index / metadata.width) / Float(metadata.height - 1))
        }
    }

    public var triangleIndices: [UInt32] {
        var indices: [UInt32] = []
        for row in 0..<(metadata.height - 1) {
            for column in 0..<(metadata.width - 1) {
                let a = UInt32(row * metadata.width + column)
                let b = a + UInt32(metadata.width)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return indices
    }
}
