import Foundation
import Metal
import MetalKit
import CoreVideo
import simd

public enum RenderPath: String, Sendable, CaseIterable, Codable {
    /// Content placed behind the screen and drawn with the off-axis projection.
    case projectedPlane
    /// Content on the screen with a texture-lookup displacement. The reference path.
    case fragmentWarp
}

public enum RenderError: Error, Equatable {
    case noDevice
    case libraryCompilationFailed(String)
    case missingFunction(String)
    case pipelineCreationFailed(String)
    case textureCacheUnavailable
    case frameTextureUnavailable
}

/// Uniform layout must match `WarpUniforms` in the shader source exactly.
private struct WarpUniforms {
    var projection: simd_float4x4
    var head: SIMD4<Float>
    var screen: SIMD4<Float>
    var params: SIMD4<Float>
    var debug: SIMD4<Float>
}

/// The window renderer.
///
/// Two paths share one uniform block and one vertex format. The projected-plane path
/// places the video behind the screen and lets the off-axis projection decide what is
/// visible through it, which is the geometrically honest version. The fragment-warp
/// path keeps the image on the screen and shifts the texture lookup instead; it is
/// cheaper and wrong at large head offsets, and it exists as the reference the thesis
/// compares against.
public final class ParallaxRenderer: NSObject, ParallaxRendering, MTKViewDelegate {

    public let device: MTLDevice

    public var projection: OffAxisProjection
    public var debugMode: DebugMode = .off
    public var renderPath: RenderPath = .projectedPlane

    /// Scales the parallax. 1 is the authored amount, 0 flattens the effect entirely,
    /// which is the setting used to demonstrate the difference during evaluation.
    public var parallaxScale: Float = 1
    /// Maximum displacement as a fraction of the screen, in texture coordinates.
    ///
    /// The warp reads depth, so without a clamp a wrong depth sample near an
    /// occlusion edge pulls texture from outside the image and tears the border.
    /// This is the value the shader reads as params.z.
    public var parallaxClamp: Float = 0.03
    /// Pixel format the depth track is stored in.
    ///
    /// Depth is authored as a greyscale image, so any single-sample or BGRA format
    /// works and the shader only reads .r. 16-bit would be the accuracy upgrade;
    /// 8-bit is the current authoring path, documented in Tools/BuildDepth.
    public var depthPixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Distance in metres between the screen and the content plane.
    public var planeDistance: Float = 0.35

    private let commandQueue: MTLCommandQueue
    private let planePipeline: MTLRenderPipelineState
    private let warpPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let placeholderDepth: MTLTexture

    private let lock = NSLock()
    private var pendingFrame: VideoFrame?
    private var shownFrame: VideoFrame?
    private var headPosition = OneEuroFilter3(minimumCutoff: 1.0, beta: 0.01)
    private var filteredHead: SIMD3<Float>?
    private var lastPoseTimestamp: TimeInterval?

    public init(device: MTLDevice? = nil, projection: OffAxisProjection) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RenderError.noDevice
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: WarpShader.source, options: nil)
        } catch {
            throw RenderError.libraryCompilationFailed("\(error)")
        }

        func function(_ name: String) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.missingFunction(name)
            }
            return function
        }

        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw RenderError.pipelineCreationFailed("\(error)")
            }
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw RenderError.textureCacheUnavailable
        }

        let placeholderDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        placeholderDescriptor.usage = .shaderRead
        guard let placeholder = device.makeTexture(descriptor: placeholderDescriptor) else {
            throw RenderError.textureCacheUnavailable
        }

        self.device = device
        self.commandQueue = queue
        self.planePipeline = try pipeline(vertex: "planeVertex", fragment: "planeFragment")
        self.warpPipeline = try pipeline(vertex: "warpVertex", fragment: "warpFragment")
        self.textureCache = cache
        self.placeholderDepth = placeholder
        self.projection = projection
        super.init()
    }

    // MARK: - ParallaxRendering

    @MainActor
    public func attach(to view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
    }

    public func update(headPose: HeadPose?) {
        guard let headPose else { return }
        let target = headPose.screenFramePosition

        lock.lock()
        defer { lock.unlock() }

        // Delta time comes from the pose clock, not the wall clock, so a stall in
        // delivery does not read as a very slow head movement.
        let delta: Float
        if let last = lastPoseTimestamp {
            delta = Float(max(min(headPose.timestamp - last, 0.1), 1.0 / 240.0))
        } else {
            delta = 1.0 / 60.0
        }
        lastPoseTimestamp = headPose.timestamp

        filteredHead = headPosition.filter(target, deltaTime: delta)
    }

    public func enqueue(frame: VideoFrame) {
        lock.lock()
        pendingFrame = frame
        lock.unlock()
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        lock.lock()
        if let pending = pendingFrame {
            shownFrame = pending
            pendingFrame = nil
        }
        let frame = shownFrame
        let head = filteredHead ?? SIMD3<Float>(0, 0, 0.5)
        lock.unlock()

        guard
            let frame,
            let colourTexture = texture(from: frame.colour, pixelFormat: .bgra8Unorm),
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let depthTexture = frame.depth.flatMap { texture(from: $0, pixelFormat: depthPixelFormat) }
            ?? placeholderDepth

        let scale = max(parallaxScale, 0)
        let uniforms = WarpUniforms(
            projection: projection.projectionMatrix(head: head),
            head: SIMD4<Float>(head.x, head.y, head.z, 0),
            screen: SIMD4<Float>(
                projection.screen.width * 0.5,
                projection.screen.height * 0.5,
                projection.nearPlane,
                projection.farPlane
            ),
            params: SIMD4<Float>(
                max(planeDistance * scale, 0.0001),
                scale,
                max(parallaxClamp, 0),
                frame.depth == nil ? 0 : 1
            ),
            debug: SIMD4<Float>(Float(debugCode(debugMode)), 0, 0, 0)
        )

        encoder.setRenderPipelineState(renderPath == .projectedPlane ? planePipeline : warpPipeline)
        encoder.setVertexBytes([uniforms], length: MemoryLayout<WarpUniforms>.stride, index: 0)
        encoder.setFragmentBytes([uniforms], length: MemoryLayout<WarpUniforms>.stride, index: 0)
        encoder.setFragmentTexture(colourTexture, index: 0)
        encoder.setFragmentTexture(depthTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    private func debugCode(_ mode: DebugMode) -> Int {
        switch mode {
        case .off: 0
        case .wireframe: 1
        case .depth: 2
        case .fullScreen: 3
        }
    }

    private func texture(from buffer: CVPixelBuffer, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, pixelFormat, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
