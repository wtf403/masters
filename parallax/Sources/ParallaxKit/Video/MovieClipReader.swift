import Foundation
import AVFoundation
import CoreVideo

public enum ClipReadError: Error, Equatable {
    case noVideoTrack
    case cannotCreateReader(String)
    case cannotCreateOutput
    case readerFailed(String)
    case notStarted
}

/// Plays a plain single-view movie as a clip.
///
/// This is the L0 path: colour only, no depth track, so the warp is driven purely
/// by the off-axis projection. It is also the reader used for the reference
/// implementation in the evaluation, where the fragment warp runs against a flat
/// surface and depth is ignored on purpose.
///
/// Frames are produced in presentation order. `frame(at:)` moves forward until the
/// requested time is reached and returns the frame that should be on screen at that
/// moment, which is the most recent frame at or before the request. A player only
/// ever moves forward, so no seeking is offered.
public final class MovieClipReader: SpatialClipReading {

    public let metadata: ClipMetadata
    public let duration: TimeInterval
    /// Presentation size of the video track, in pixels.
    public let naturalSize: CGSize
    /// Nominal frame rate of the track, frames per second.
    public let nominalFrameRate: Float

    private let asset: AVURLAsset
    private let track: AVAssetTrack

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    private var current: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var lookahead: (buffer: CVPixelBuffer, time: TimeInterval)?

    private init(
        asset: AVURLAsset,
        track: AVAssetTrack,
        metadata: ClipMetadata,
        duration: TimeInterval,
        naturalSize: CGSize,
        nominalFrameRate: Float
    ) {
        self.asset = asset
        self.track = track
        self.metadata = metadata
        self.duration = duration
        self.naturalSize = naturalSize
        self.nominalFrameRate = nominalFrameRate
    }

    /// Load the track properties. Asynchronous because modern AVFoundation loads
    /// asset properties that way, and the reader should not block a thread while a
    /// remote or large file streams in.
    public static func open(url: URL) async throws -> MovieClipReader {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ClipReadError.noVideoTrack }

        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let transform = try await track.load(.preferredTransform)

        // A movie's stored pixel dimensions ignore the presentation transform, so a
        // portrait recording arrives with a rotated track. Fold that in now rather
        // than leaving a landscape quad showing portrait content.
        let presented = naturalSize.applying(transform)

        // A plain movie carries no stereo baseline, so parallax has no metric scale
        // and the projection does all the work. The clamp stays at its default.
        let metadata = ClipMetadata(
            colourTrack: url.lastPathComponent,
            depthTrack: nil,
            baseline: 0,
            horizontalFieldOfView: 60
        )

        return MovieClipReader(
            asset: asset,
            track: track,
            metadata: metadata,
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            naturalSize: CGSize(width: abs(presented.width), height: abs(presented.height)),
            nominalFrameRate: nominalFrameRate
        )
    }

    public func start() throws {
        try start(at: 0)
    }

    /// Start reading, optionally from a given presentation time.
    ///
    /// Seeking is expressed as a time range on the reader rather than by walking
    /// frames from the beginning, so a jump into the middle of a long clip costs the
    /// same as starting at zero.
    public func start(at time: TimeInterval) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ClipReadError.cannotCreateReader(error.localizedDescription)
        }

        if time > 0 {
            let start = CMTime(seconds: time, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }

        // Metal compatibility and an IOSurface-backed pool let the renderer wrap the
        // pixel buffer as a texture without a copy per frame.
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipReadError.cannotCreateOutput }
        reader.add(output)

        guard reader.startReading() else {
            throw ClipReadError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        self.reader = reader
        self.output = output
        current = nil
        lookahead = nil
    }

    public func stop() {
        reader?.cancelReading()
        reader = nil
        output = nil
        current = nil
        lookahead = nil
    }

    public func frame(at time: TimeInterval) throws -> VideoFrame? {
        guard let reader, let output else { throw ClipReadError.notStarted }

        if lookahead == nil { lookahead = try pull(reader: reader, output: output) }

        // Walk forward to the last frame at or before the requested time. The frame
        // after it is kept as a lookahead so the next call does not decode twice.
        while let head = lookahead, head.time <= time {
            current = head
            lookahead = try pull(reader: reader, output: output)
        }

        guard let current else { return nil }
        return VideoFrame(
            colour: current.buffer,
            depth: nil,
            presentationTime: current.time,
            baseline: metadata.baseline
        )
    }

    private func pull(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput
    ) throws -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw ClipReadError.readerFailed(reader.error?.localizedDescription ?? "unknown")
            }
            return nil
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return (buffer, time.isFinite ? time : 0)
    }
}
