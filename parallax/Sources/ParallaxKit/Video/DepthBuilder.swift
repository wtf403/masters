import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

public struct DepthBuilderOptions: Sendable {
    public var layout: SideBySide.Layout
    /// Divide by this before matching. Block matching is quadratic in resolution, so
    /// this is the main cost knob.
    public var downsample: Int
    /// Half-width of the matching window, in downsampled pixels. 1 gives a 3x3 window.
    public var blockRadius: Int
    /// Largest disparity to search, as a fraction of the eye width.
    public var maxDisparityFraction: Float
    /// Normalised SAD above which a match is treated as unreliable and the depth is
    /// written as zero rather than as a confident wrong value.
    public var matchThreshold: Float
    public var depthTrackName: String

    public init(
        layout: SideBySide.Layout = .leftRight,
        downsample: Int = 4,
        blockRadius: Int = 1,
        maxDisparityFraction: Float = 0.04,
        matchThreshold: Float = 0.16,
        depthTrackName: String = ClipBundle.defaultDepthName
    ) {
        self.layout = layout
        self.downsample = downsample
        self.blockRadius = blockRadius
        self.maxDisparityFraction = maxDisparityFraction
        self.matchThreshold = matchThreshold
        self.depthTrackName = depthTrackName
    }
}

public struct DepthBuilderResult: Sendable {
    public var frameCount: Int
    public var size: CGSize
    /// Fraction of pixels that produced a confident match, averaged over the clip.
    /// A low number means the depth track is mostly holes.
    public var averageConfidence: Float
}

public enum DepthBuilderError: Error, Equatable {
    case noVideoTrack
    case cannotAddTrack
    case cannotStartWriter(String)
    case readerFailed(String)
    case writerFailed(String)
    case unsupportedLayout
}

/// Derives a depth track from a side-by-side stereo movie.
///
/// Scope, stated plainly, because this is the part most easily overclaimed. It is a
/// plain CPU block matcher with a normalised sum of absolute differences cost, run at
/// reduced resolution with a small search range. It is not a semi-global matcher, it
/// has no sub-pixel refinement, and it makes no attempt at left-right consistency, so
/// it fails on textureless regions, on motion blur and on reflective surfaces. What it
/// does do is turn a stereo pair into a usable per-frame depth signal and quantify how
/// often it is confident, which is what phase P2 needs to evaluate the effect before
/// investing in a real matcher.
public enum DepthBuilder {

    public static func build(
        fromStereoMovieAt sourceURL: URL,
        to bundleURL: URL,
        options: DepthBuilderOptions
    ) async throws -> DepthBuilderResult {

        guard options.layout != .none else { throw DepthBuilderError.unsupportedLayout }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw DepthBuilderError.noVideoTrack }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let presented = naturalSize.applying(transform)
        let sourceWidth = Int(abs(presented.width).rounded())
        let sourceHeight = Int(abs(presented.height).rounded())

        let rects = SideBySide.eyeRects(width: sourceWidth, height: sourceHeight, layout: options.layout)
        let eyeWidth = Int(rects.left.width)
        let eyeHeight = Int(rects.left.height)
        guard eyeWidth > 0, eyeHeight > 0 else { throw DepthBuilderError.unsupportedLayout }

        // The depth track is written at the eye size, not the packed size, so it lines
        // up with the colour track without either side having to remember the layout.
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let depthURL = bundleURL.appendingPathComponent(options.depthTrackName)
        try? FileManager.default.removeItem(at: depthURL)

        let writer = try AVAssetWriter(outputURL: depthURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: eyeWidth,
                AVVideoHeightKey: eyeHeight,
            ]
        )
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: eyeWidth,
                kCVPixelBufferHeightKey as String: eyeHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )

        guard writer.canAdd(videoInput) else { throw DepthBuilderError.cannotAddTrack }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw DepthBuilderError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw DepthBuilderError.cannotAddTrack }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw DepthBuilderError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        let scale = max(options.downsample, 1)
        let gridWidth = max(eyeWidth / scale, 1)
        let gridHeight = max(eyeHeight / scale, 1)
        let maxDisparity = max(Int(Float(gridWidth) * options.maxDisparityFraction), 1)
        let blockRadius = max(options.blockRadius, 0)

        var frameCount = 0
        var confidenceTotal: Float = 0

        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw DepthBuilderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let pair = try samplePair(from: sourceBuffer, rects: rects)
            let depth = matchDepth(
                left: pair.left,
                right: pair.right,
                width: gridWidth,
                height: gridHeight,
                scale: scale,
                maxDisparity: maxDisparity,
                blockRadius: blockRadius,
                threshold: options.matchThreshold
            )

            confidenceTotal += depth.confidence

            let destination = try PixelBufferOps.makeBGRA(width: eyeWidth, height: eyeHeight)
            write(
                depth: depth.values,
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                scale: scale,
                into: destination,
                fullWidth: eyeWidth,
                fullHeight: eyeHeight
            )

            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            if adaptor.append(destination, withPresentationTime: presentation) {
                frameCount += 1
            } else if writer.status == .failed {
                throw DepthBuilderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
            }
        }

        if reader.status == .failed {
            throw DepthBuilderError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw DepthBuilderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        // Record the depth track in the bundle metadata if a bundle is already there,
        // so a packaged clip gains its depth track without a second pass.
        let bundle = ClipBundle(url: bundleURL)
        if let existing = try? bundle.loadMetadata() {
            var updated = existing
            updated.depthTrack = options.depthTrackName
            try? bundle.writeMetadata(updated)
        }

        return DepthBuilderResult(
            frameCount: frameCount,
            size: CGSize(width: eyeWidth, height: eyeHeight),
            averageConfidence: frameCount > 0 ? confidenceTotal / Float(frameCount) : 0
        )
    }

    // MARK: - Frame handling

    private struct LumaPlane {
        var values: [Float]
        var width: Int
        var height: Int
    }

    private static func samplePair(
        from buffer: CVPixelBuffer,
        rects: SideBySide.EyeRects
    ) throws -> (left: LumaPlane, right: LumaPlane) {
        let lock = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard lock == kCVReturnSuccess else { throw PixelBufferError.lockFailed(lock) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw PixelBufferError.lockFailed(-1)
        }

        let stride = CVPixelBufferGetBytesPerRow(buffer)
        return (
            plane(from: base, stride: stride, rect: rects.left),
            plane(from: base, stride: stride, rect: rects.right)
        )
    }

    private static func plane(
        from base: UnsafeMutableRawPointer,
        stride: Int,
        rect: CGRect
    ) -> LumaPlane {
        let width = Int(rect.width)
        let height = Int(rect.height)
        let originX = Int(rect.origin.x)
        let originY = Int(rect.origin.y)

        var values = [Float](repeating: 0, count: max(width * height, 1))
        for y in 0..<height {
            let row = base.advanced(by: (originY + y) * stride + originX * 4)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                values[y * width + x] = PixelBufferOps.luma(bgra: row.advanced(by: x * 4))
            }
        }

        return LumaPlane(values: values, width: width, height: height)
    }

    /// Normalised SAD block matching on the downsampled pair.
    ///
    /// Returns depth normalised to 0...1 where 1 is nearest, matching the convention
    /// the shader uses when it maps a depth sample between the far and near planes.
    private static func matchDepth(
        left: LumaPlane,
        right: LumaPlane,
        width: Int,
        height: Int,
        scale: Int,
        maxDisparity: Int,
        blockRadius: Int,
        threshold: Float
    ) -> (values: [Float], confidence: Float) {

        var depth = [Float](repeating: 0, count: width * height)
        var matched = 0

        for gy in 0..<height {
            for gx in 0..<width {
                let lx = min(gx * scale, left.width - 1)
                let ly = min(gy * scale, left.height - 1)

                var bestCost = Float.greatestFiniteMagnitude
                var secondCost = Float.greatestFiniteMagnitude
                var bestDisparity = 0

                for disparity in 0...maxDisparity {
                    let rx = (gx - disparity) * scale
                    guard rx >= 0, rx < right.width else { continue }

                    var cost: Float = 0
                    var samples: Float = 0

                    for dy in -blockRadius...blockRadius {
                        let sy = ly + dy
                        guard sy >= 0, sy < left.height else { continue }
                        for dx in -blockRadius...blockRadius {
                            let sx = lx + dx
                            let tx = rx + dx
                            guard sx >= 0, sx < left.width, tx >= 0, tx < right.width else { continue }
                            cost += abs(left.values[sy * left.width + sx] - right.values[sy * right.width + tx])
                            samples += 1
                        }
                    }

                    guard samples > 0 else { continue }
                    let normalised = cost / samples
                    if normalised < bestCost {
                        secondCost = bestCost
                        bestCost = normalised
                        bestDisparity = disparity
                    } else if normalised < secondCost {
                        secondCost = normalised
                    }
                }

                guard bestCost <= threshold else { continue }
                matched += 1
                depth[gy * width + gx] = Float(bestDisparity) / Float(max(maxDisparity, 1))
            }
        }

        let confidence = Float(matched) / Float(max(width * height, 1))
        return (depth, confidence)
    }

    private static func write(
        depth: [Float],
        gridWidth: Int,
        gridHeight: Int,
        scale: Int,
        into destination: CVPixelBuffer,
        fullWidth: Int,
        fullHeight: Int
    ) {
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return }
        let stride = CVPixelBufferGetBytesPerRow(destination)

        for y in 0..<fullHeight {
            let gy = min(y / scale, gridHeight - 1)
            for x in 0..<fullWidth {
                let gx = min(x / scale, gridWidth - 1)
                PixelBufferOps.writeGrey(
                    into: base,
                    stride: stride,
                    x: x,
                    y: y,
                    value: depth[gy * gridWidth + gx]
                )
            }
        }
    }
}

