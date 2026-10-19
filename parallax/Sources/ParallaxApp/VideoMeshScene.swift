#if os(iOS)
import Foundation
import SceneKit
import AVFoundation
import CoreImage
import ParallaxKit

/// Decodes both MV-HEVC views and rebuilds a video surface during playback.
@MainActor
final class VideoMeshScene {
    let node = SCNNode()
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let output: AVPlayerVideoOutput
    private let processor = StereoVideoProcessor()
    private var processing = false
    private var generation = 0
    private let material = SCNMaterial()
    private let coordinates: SCNGeometrySource
    private let triangles: SCNGeometryElement
    private var lastHost: Double = 0
    private var lastPTS: Double = -1
    private(set) var processedFrames = 0
    private(set) var lastProcessingMilliseconds = 0.0
    private(set) var aspect: Float = 16.0/9.0
    private(set) var status = "Decoding stereo video…"
    var strength: Float = 1 { didSet { lastPTS = -1 } }
    var isPlaying = true

    init(url: URL) throws {
        let specification = AVVideoOutputSpecification(tagCollections: [.stereoscopicForVideoOutput()])
        specification.defaultOutputSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        output = AVPlayerVideoOutput(specification: specification)
        player = AVQueuePlayer()
        player.videoOutput = output
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        var uv: [CGPoint] = []
        var indices: [UInt32] = []
        for y in 0..<54 { for x in 0..<96 {
            uv.append(CGPoint(x: Double(x)/95, y: Double(y)/53))
            if x < 95 && y < 53 {
                let a = UInt32(y*96+x), b = a+96
                indices += [a,b,a+1,a+1,b,b+1]
            }
        } }
        coordinates = SCNGeometrySource(textureCoordinates: uv)
        triangles = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        material.lightingModel = .constant
        material.isDoubleSided = true
    }

    func play() { if isPlaying { player.play() } }
    func pause() { player.pause(); generation += 1 }
    func toggle() { isPlaying.toggle(); isPlaying ? player.play() : player.pause() }

    func update() {
        let host = CACurrentMediaTime()
        guard !processing, host-lastHost >= 1.0/30 else { return }
        lastHost = host
        if let error = player.currentItem?.error { status = error.localizedDescription; return }
        guard let group = output.taggedBuffers(forHostTime: CMTime(seconds: host, preferredTimescale: 1_000_000_000)) else {
            if processedFrames == 0 && player.currentTime().seconds > 3 { status = "This clip must contain both MV-HEVC stereo views." }
            return
        }
        guard group.presentationTime.seconds != lastPTS else { return }
        var left: CVPixelBuffer?, right: CVPixelBuffer?
        for tagged in group.taggedBufferGroup {
            guard case .pixelBuffer(let pixel) = tagged.buffer else { continue }
            let eye = tagged.tags.firstValue(matchingCategory: .stereoView)
            if eye == .leftEye { left = pixel }
            if eye == .rightEye { right = pixel }
        }
        guard let left, let right else { status = "Both stereo views are required."; return }
        processing = true
        let token = generation
        let pair = StereoVideoPair(left: left, right: right)
        let pts = group.presentationTime.seconds
        aspect = Float(CVPixelBufferGetWidth(left))/Float(CVPixelBufferGetHeight(left))
        let depthStrength = strength
        let processingStart = CACurrentMediaTime()
        Task { [weak self, processor] in
            do {
                let frame = try await processor.process(pair, strength: depthStrength)
                guard let self else { return }
                defer { self.processing = false }
                guard self.generation == token else { return }
                self.material.diffuse.contents = frame.colour
                let positions = frame.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
                let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), self.coordinates], elements: [self.triangles])
                geometry.materials = [self.material]
                self.node.geometry = geometry
                self.lastPTS = pts
                self.processedFrames += 1
                self.lastProcessingMilliseconds = (CACurrentMediaTime()-processingStart)*1000
                self.status = "Live stereo depth · \(frame.confidence)% matched"
            } catch {
                self?.processing = false
                self?.status = "Stereo decoding failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif
