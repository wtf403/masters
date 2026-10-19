import Foundation
import Testing
import simd
@testable import ParallaxKit

private func depthMesh(_ data: [UInt8]) throws -> VideoDepthMesh {
    let json = """
    {"width":2,"height":2,"frameCount":1,"fps":15,"nearDepth":0.025,
     "farDepth":0.14,"referenceEyeDistance":0.4}
    """
    let metadata = try JSONDecoder().decode(VideoDepthMetadata.self, from: Data(json.utf8))
    return try VideoDepthMesh(metadata: metadata, data: Data(data))
}

@Test func videoSurfacePreservesSourceImageAtReferenceEye() throws {
    let mesh = try depthMesh([0, 255, 128, 64])
    let projection = OffAxisProjection(screen: .init(width: 0.135, height: 0.062))
    let expected: [SIMD2<Float>] = [.init(-1, 1), .init(1, 1), .init(-1, -1), .init(1, -1)]
    for (point, target) in zip(mesh.vertices(frame: 0), expected) {
        let projected = projection.project(point: point, head: .init(0, 0, 0.4))
        #expect(abs(projected.x - target.x) < 0.0001)
        #expect(abs(projected.y - target.y) < 0.0001)
    }
}

@Test func videoSurfaceHasDepthDependentParallax() throws {
    let mesh = try depthMesh([0, 255, 0, 255])
    let points = mesh.vertices(frame: 0)
    #expect(points[0].z < points[1].z)
    let projection = OffAxisProjection(screen: .init(width: 0.135, height: 0.062))
    let neutral: SIMD3<Float> = .init(0, 0, 0.4)
    let shifted: SIMD3<Float> = .init(0.03, 0, 0.4)
    let offsets = points.map {
        abs(projection.project(point: $0, head: shifted).x - projection.project(point: $0, head: neutral).x)
    }
    #expect(offsets[0] > offsets[1])
    #expect(mesh.triangleIndices == [0, 2, 1, 1, 2, 3])
    #expect(mesh.textureCoordinates[0] == SIMD2<Float>(0, 0))
    #expect(mesh.textureCoordinates[3] == SIMD2<Float>(1, 1))
}

@Test func incompleteVideoDepthCannotLoad() throws {
    #expect(throws: VideoDepthMesh.LoadError.invalidByteCount) { try depthMesh([0]) }
}
