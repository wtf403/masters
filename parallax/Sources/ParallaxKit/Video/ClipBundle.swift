import Foundation
import CoreGraphics

public enum ClipBundleError: Error, Equatable {
    case notADirectory(String)
    case missingMetadata(String)
    case missingColour(String)
    case missingDepth(String)
    case unreadableMetadata(String)
}

/// A .scpak clip: a directory holding clip.json plus one movie per track.
///
/// A directory rather than a single container, because the colour and depth tracks
/// are ordinary movies that any tool can read, write or inspect, and the metadata is
/// plain JSON rather than opaque boxes. Bundling them as a package keeps the clip
/// draggable as one item while leaving every part debuggable.
public struct ClipBundle: Sendable {

    public static let metadataName = "clip.json"
    public static let defaultColourName = "colour.mov"
    public static let defaultDepthName = "depth.mov"
    public static let fileExtension = "scpak"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var metadataURL: URL { url.appendingPathComponent(Self.metadataName) }
    public var defaultColourURL: URL { url.appendingPathComponent(Self.defaultColourName) }
    public var defaultDepthURL: URL { url.appendingPathComponent(Self.defaultDepthName) }

    /// Resolve a track file by the name recorded in the metadata.
    public func trackURL(named name: String) -> URL {
        url.appendingPathComponent(name)
    }

    public static func isBundle(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return present && isDirectory.boolValue
    }

    public func loadMetadata() throws -> ClipMetadata {
        guard Self.isBundle(at: url) else { throw ClipBundleError.notADirectory(url.path) }
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ClipBundleError.missingMetadata(metadataURL.path)
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            return try JSONDecoder().decode(ClipMetadata.self, from: data)
        } catch {
            throw ClipBundleError.unreadableMetadata(String(describing: error))
        }
    }

    public func writeMetadata(_ metadata: ClipMetadata) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    /// Every track present in the bundle, with its file existence checked.
    public func validate() throws -> ClipMetadata {
        let metadata = try loadMetadata()

        let colour = trackURL(named: metadata.colourTrack)
        guard FileManager.default.fileExists(atPath: colour.path) else {
            throw ClipBundleError.missingColour(colour.path)
        }

        if let depth = metadata.depthTrack {
            let depthURL = trackURL(named: depth)
            guard FileManager.default.fileExists(atPath: depthURL.path) else {
                throw ClipBundleError.missingDepth(depthURL.path)
            }
        }

        return metadata
    }

    /// Open the colour track for playback.
    public func makeReader() async throws -> MovieClipReader {
        let metadata = try validate()
        return try await MovieClipReader.open(url: trackURL(named: metadata.colourTrack))
    }
}

/// Side-by-side stereo, the most portable way 3D video is distributed.
///
/// A spatial video from an iPhone is MV-HEVC, one track with two layers, which needs
/// tagged-buffer reading. Anything else in the wild is a flat frame with the two eyes
/// packed side by side, so this is the widest input the authoring tools accept.
public enum SideBySide {

    /// Raw values are the names the command line tools accept, so the two cannot drift
    /// apart: the enum is the single source of truth for the spelling.
    public enum Layout: String, Sendable, CaseIterable {
        /// Guess from the frame shape. Resolved by the packager once the size is known.
        case auto
        /// Left eye on the left half, right eye on the right half.
        case leftRight = "left-right"
        /// Left eye on the top half, right eye on the bottom half.
        case topBottom = "top-bottom"
        /// One frame, one eye. The degenerate case, for flat video.
        case none
    }

    public struct EyeRects: Sendable, Equatable {
        public var left: CGRect
        public var right: CGRect
    }

    /// Pixel rectangles for the two eyes within a packed frame.
    ///
    /// An odd dimension cannot be halved evenly; the extra row or column is given to
    /// the first eye so the two rectangles tile the frame exactly and never overlap.
    /// Overlapping rectangles would put a strip of the wrong eye into one view, which
    /// reads as a vertical band of doubled edges rather than as a clean error.
    public static func eyeRects(width: Int, height: Int, layout: Layout) -> EyeRects {
        let safeWidth = max(width, 0)
        let safeHeight = max(height, 0)

        switch layout {
        case .leftRight:
            let leftWidth = (safeWidth + 1) / 2
            return EyeRects(
                left: CGRect(x: 0, y: 0, width: leftWidth, height: safeHeight),
                right: CGRect(x: leftWidth, y: 0, width: safeWidth - leftWidth, height: safeHeight)
            )
        case .topBottom:
            let topHeight = (safeHeight + 1) / 2
            return EyeRects(
                left: CGRect(x: 0, y: 0, width: safeWidth, height: topHeight),
                right: CGRect(x: 0, y: topHeight, width: safeWidth, height: safeHeight - topHeight)
            )
        case .none:
            let full = CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
            return EyeRects(left: full, right: full)
        case .auto:
            // Not meaningful without a frame to inspect; the caller resolves it first.
            let full = CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
            return EyeRects(left: full, right: full)
        }
    }

    /// Guess the layout from the frame's shape.
    ///
    /// A left-right pair is roughly twice as wide as the nominal aspect, and a
    /// top-bottom pair is roughly half. The thresholds are deliberately loose,
    /// because this only picks a default that the caller can override.
    public static func guessLayout(
        width: Int,
        height: Int,
        nominalAspect: Float = 16.0 / 9.0
    ) -> Layout {
        guard width > 0, height > 0 else { return .none }
        let aspect = Float(width) / Float(height)
        if aspect > nominalAspect * 1.6 { return .leftRight }
        if aspect < nominalAspect / 1.6 { return .topBottom }
        return .none
    }
}

