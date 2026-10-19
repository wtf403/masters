import Foundation
import MetalKit

/// Rendering stage. Consumes head poses and decoded frames, draws the window.
public protocol ParallaxRendering: AnyObject {
    /// Attach to the view that will present frames.
    @MainActor
    func attach(to view: MTKView)
    /// Latest head pose, used to rebuild the off-axis projection each frame.
    func update(headPose: HeadPose?)
    /// Offer a decoded frame for display.
    func enqueue(frame: VideoFrame)
    /// Projection settings, including the physical screen rectangle.
    var projection: OffAxisProjection { get set }
    var debugMode: DebugMode { get set }
}

/// Debug visualisations, carried over from the original app's camera switcher.
public enum DebugMode: String, CaseIterable, Sendable, Codable {
    case off
    case wireframe
    case depth
    case fullScreen
}

