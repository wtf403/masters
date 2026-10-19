import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

public enum ClipEye: String, Sendable, CaseIterable {
    case left
    case right
}

public struct ClipPackagerOptions: Sendable {
    /// Stereo layout of the source frame.
    public var layout: SideBySide.Layout
    /// Which eye becomes the colour track when the source is stereo.
    public var eye: ClipEye
    public var baseline: Float
    public var horizontalFieldOfView: Float
    public var nearPlane: Float
    public var farPlane: Float
    public var recommendedViewingDistance: Float
    public var parallaxClamp: Float
    public var colourTrackName: String
    public var depthTrackName: String?

    public init(
        layout: SideBySide.Layout = .none,
        eye: ClipEye = .left,
        baseline: Float = 0.065,
        horizontalFieldOfView: Float = 60,
        nearPlane: Float = 0.25,
        farPlane: Float = 8,
        recommendedViewingDistance: Float = 0.5,
        parallaxClamp: Float = 0.03,
        colourTrackName: String = ClipBundle.defaultColourName,
        depthTrackName: String? = nil
    ) {
        self.layout = layout
        self.eye = eye
        self.baseline = baseline
        self.horizontalFieldOfView = horizontalFieldOfView
        self.nearPlane = nearPlane
        self.farPlane = farPlane
        self.recommendedViewingDistance = recommendedViewingDistance
        self.parallaxClamp = parallaxClamp
        self.colourTrackName = colourTrackName
        self.depthTrackName = depthTrackName
    }
}

public struct ClipPackagerResult: Sendable {
    public var metadata: ClipMetadata
    public var frameCount: Int
    /// Presentation size of the written colour track, in pixels.
    public var presentationSize: CGSize
    public var layout: SideBySide.Layout
    /// Codec actually used. HEVC is preferred and H.264 is the fallback.
    public var codec: String
}

public enum ClipPackagerError: Error, Equatable {
    case noVideoTrack
    case cannotAddTrack
    case cannotStartWriter(String)
    case noUsableCodec(String)
    case readerFailed(String)
    case writerFailed(String)
    case emptySource
}

extension ClipPackagerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noVideoTrack:
            return "the input has no video track"
        case .cannotAddTrack:
            return "the writer rejected the video track"
        case .cannotStartWriter(let detail):
            return "the writer would not start: \(detail)"
        case .noUsableCodec(let detail):
            return """
            no usable video encoder. Tried HEVC, H.264 and uncompressed. \
            This usually means the platform video encoding services are unavailable, \
            which happens in restricted sandboxes. The encoder itself is not the \
            problem you are looking for. Details: \(detail)
            """
        case .readerFailed(let detail):
            return "reading the source failed: \(detail)"
        case .writerFailed(let detail):
            return "writing the clip failed: \(detail)"
        case .emptySource:
            return "the source frame is empty"
        }
    }
}

/// Turns an ordinary movie into a clip bundle.
///
/// This is the step the original app never had. The Unity project shipped five
/// hand-built 3D scenes, so there was no content pipeline at all; here the content is
/// video, so something must take a movie and give it the geometry metadata that makes
/// the parallax correct rather than merely convincing.
public enum ClipPackager {

    /// Read the source movie, write its colour track into the bundle, and write the
    /// metadata beside it.
    ///
    /// Frames are copied one at a time rather than passed through, because a
    /// side-by-side source has to be split and a rotated source has to be un-rotated.
    /// That costs a re-encode, which is acceptable for an offline step.
    public static func package(
        input: URL,
        to bundleURL: URL,
        options: ClipPackagerOptions
    ) async throws -> ClipPackagerResult {

        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ClipPackagerError.noVideoTrack }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)

        // Stored pixel dimensions ignore the presentation transform, so a portrait
        // recording arrives sideways. Fold the transform into the size now.
        let presented = naturalSize.applying(transform)
        let sourceWidth = Int(abs(presented.width).rounded())
        let sourceHeight = Int(abs(presented.height).rounded())

        // Resolve a deferred layout now that the frame size is known. Guessing here
        // rather than in the tool means every caller gets the same behaviour.
        let layout = options.layout == .auto
            ? SideBySide.guessLayout(width: sourceWidth, height: sourceHeight)
            : options.layout

        let rects = SideBySide.eyeRects(
            width: sourceWidth,
            height: sourceHeight,
            layout: layout
        )
        let sourceRect = options.eye == .left ? rects.left : rects.right

        let outputWidth = Int(sourceRect.width)
        let outputHeight = Int(sourceRect.height)
        guard outputWidth > 0, outputHeight > 0 else { throw ClipPackagerError.emptySource }

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let colourURL = bundleURL.appendingPathComponent(options.colourTrackName)
        try? FileManager.default.removeItem(at: colourURL)

        // HEVC is the natural choice for a spatial clip, but the encoder is not
        // available on every machine, so fall back rather than fail outright. Which
        // codec was used is reported, because it affects file size and quality.
        var encoder: Encoder?
        var failures: [String] = []
        // nil selects an uncompressed track, which is always available. It is a large
        // file, so it is the last resort rather than the default, but it keeps the
        // tool usable on a machine where no video encoder is available at all.
        for codec in [AVVideoCodecType.hevc, AVVideoCodecType.h264, nil] as [AVVideoCodecType?] {
            do {
                encoder = try Encoder(
                    url: colourURL,
                    width: outputWidth,
                    height: outputHeight,
                    codec: codec
                )
                break
            } catch {
                failures.append("\(codec?.rawValue ?? "uncompressed"): \(error)")
            }
        }

        guard let encoder else {
            throw ClipPackagerError.noUsableCodec(failures.joined(separator: "; "))
        }

        let writer = encoder.writer
        let videoInput = encoder.input
        let adaptor = encoder.adaptor
        let codecName = encoder.codec?.rawValue ?? "uncompressed"

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ClipPackagerError.cannotAddTrack }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw ClipPackagerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var frameCount = 0

        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            // Wait for the writer rather than dropping frames.
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw ClipPackagerError.writerFailed(
                        writer.error?.localizedDescription ?? "unknown"
                    )
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let destination = try PixelBufferOps.makeBGRA(width: outputWidth, height: outputHeight)
            try PixelBufferOps.copy(rect: sourceRect, from: sourceBuffer, into: destination)

            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            if adaptor.append(destination, withPresentationTime: presentation) {
                frameCount += 1
            } else if writer.status == .failed {
                throw ClipPackagerError.writerFailed(writer.error?.localizedDescription ?? "unknown")
            }
        }

        if reader.status == .failed {
            throw ClipPackagerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ClipPackagerError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        // A flat source carries no stereo baseline, so parallax has no metric scale
        // and the projection alone does the work. Recording 0 keeps that honest.
        let metadata = ClipMetadata(
            colourTrack: options.colourTrackName,
            depthTrack: options.depthTrackName,
            baseline: layout == .none ? 0 : options.baseline,
            horizontalFieldOfView: options.horizontalFieldOfView,
            disparityAdjustment: 0,
            nearPlane: options.nearPlane,
            farPlane: options.farPlane,
            recommendedViewingDistance: options.recommendedViewingDistance,
            parallaxClamp: options.parallaxClamp
        )

        try ClipBundle(url: bundleURL).writeMetadata(metadata)

        return ClipPackagerResult(
            metadata: metadata,
            frameCount: frameCount,
            presentationSize: CGSize(width: outputWidth, height: outputHeight),
            layout: layout,
            codec: codecName
        )
    }
}

/// Writer, input and adaptor for one encoding attempt.
///
/// Only exists so the codec fallback can construct a complete set, discover that the
/// encoder is unavailable, and try the next one without leaving a half-configured
/// writer behind.
private struct Encoder {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// nil means an uncompressed track.
    let codec: AVVideoCodecType?

    init(url: URL, width: Int, height: Int, codec: AVVideoCodecType?) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let settings: [String: Any]? = codec.map { codec in
            [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )

        guard writer.canAdd(input) else { throw ClipPackagerError.cannotAddTrack }
        writer.add(input)
        guard writer.startWriting() else {
            throw ClipPackagerError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.codec = codec
    }
}

