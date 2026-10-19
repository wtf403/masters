import Foundation
import CoreVideo

/// Metadata that travels with a playable clip.
///
/// The geometric fields are what make the parallax correct rather than merely
/// convincing: without a baseline and a field of view, disparity cannot be turned
/// into metres.
public struct ClipMetadata: Codable, Sendable, Equatable {
    public var version: Int
    /// File name of the colour track within the clip bundle.
    public var colourTrack: String
    /// File name of the depth track, when the clip carries one.
    public var depthTrack: String?
    /// Camera baseline in metres, from cameraSystemBaseline.
    public var baseline: Float
    /// Horizontal field of view in degrees.
    public var horizontalFieldOfView: Float
    /// Relative shift of the two views, from disparityAdjustment.
    public var disparityAdjustment: Float
    /// Near and far planes in metres for the depth range.
    public var nearPlane: Float
    public var farPlane: Float
    /// Distance at which the clip was authored to be viewed, metres.
    public var recommendedViewingDistance: Float
    /// Maximum parallax displacement as a fraction of screen width.
    public var parallaxClamp: Float

    public init(
        version: Int = 1,
        colourTrack: String,
        depthTrack: String? = nil,
        baseline: Float = 0.065,
        horizontalFieldOfView: Float = 60,
        disparityAdjustment: Float = 0,
        nearPlane: Float = 0.25,
        farPlane: Float = 8,
        recommendedViewingDistance: Float = 0.5,
        parallaxClamp: Float = 0.03
    ) {
        self.version = version
        self.colourTrack = colourTrack
        self.depthTrack = depthTrack
        self.baseline = baseline
        self.horizontalFieldOfView = horizontalFieldOfView
        self.disparityAdjustment = disparityAdjustment
        self.nearPlane = nearPlane
        self.farPlane = farPlane
        self.recommendedViewingDistance = recommendedViewingDistance
        self.parallaxClamp = parallaxClamp
    }
}

/// A decoded frame, ready for the renderer.
///
/// This is the currency between the decoder and the renderer: the decoder fills it,
/// the renderer consumes it, and neither knows about the other.
public struct VideoFrame {
    public var colour: CVPixelBuffer
    public var depth: CVPixelBuffer?
    /// Presentation timestamp in seconds, used to pair the frame with a head pose.
    public var presentationTime: TimeInterval
    /// Baseline of the source, so the renderer can scale parallax per clip.
    public var baseline: Float

    public init(
        colour: CVPixelBuffer,
        depth: CVPixelBuffer?,
        presentationTime: TimeInterval,
        baseline: Float
    ) {
        self.colour = colour
        self.depth = depth
        self.presentationTime = presentationTime
        self.baseline = baseline
    }
}

/// Reads a clip and produces frames.
public protocol SpatialClipReading: AnyObject {
    var metadata: ClipMetadata { get }
    var duration: TimeInterval { get }

    func start() throws
    func stop()
    /// Advance to the given time and return the frame to display, if any.
    func frame(at time: TimeInterval) throws -> VideoFrame?
}

