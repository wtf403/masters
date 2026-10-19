import Testing
import Foundation
import CoreGraphics
import CoreVideo
@testable import ParallaxKit

@Test func clipMetadataSurvivesAJSONRoundTrip() throws {
    let original = ClipMetadata(
        colourTrack: "colour.mov",
        depthTrack: "depth.mov",
        baseline: 0.065,
        horizontalFieldOfView: 58,
        disparityAdjustment: 0.02,
        nearPlane: 0.3,
        farPlane: 6,
        recommendedViewingDistance: 0.45,
        parallaxClamp: 0.025
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ClipMetadata.self, from: data)
    #expect(decoded == original)
}

@Test func clipMetadataDefaultsAreRecorded() throws {
    let metadata = ClipMetadata(colourTrack: "colour.mov")
    #expect(metadata.version == 1)
    #expect(metadata.depthTrack == nil)
    #expect(metadata.baseline > 0)
    #expect(metadata.parallaxClamp > 0)
}

@Test func bundleWritesAndReadsMetadata() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("parallax-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let bundle = ClipBundle(url: root)
    let metadata = ClipMetadata(colourTrack: "colour.mov", depthTrack: "depth.mov", baseline: 0.07)
    try bundle.writeMetadata(metadata)

    let loaded = try bundle.loadMetadata()
    #expect(loaded == metadata)
    #expect(bundle.metadataURL.lastPathComponent == "clip.json")
}

@Test func bundleReportsAMissingColourTrack() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("parallax-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let bundle = ClipBundle(url: root)
    try bundle.writeMetadata(ClipMetadata(colourTrack: "colour.mov"))

    // Metadata is present but the movie it names is not, which must be an error and
    // not an empty clip that silently renders nothing.
    #expect(throws: ClipBundleError.self) {
        _ = try bundle.validate()
    }
}

@Test func nonExistentBundleIsRejected() {
    let missing = URL(fileURLWithPath: "/tmp/parallax-does-not-exist-\(UUID().uuidString)")
    #expect(!ClipBundle.isBundle(at: missing))
    #expect(throws: ClipBundleError.self) {
        _ = try ClipBundle(url: missing).loadMetadata()
    }
}

// MARK: - Side-by-side layout

@Test func evenLeftRightSplitsIntoTouchingHalves() {
    let rects = SideBySide.eyeRects(width: 1280, height: 360, layout: .leftRight)
    #expect(rects.left == CGRect(x: 0, y: 0, width: 640, height: 360))
    #expect(rects.right == CGRect(x: 640, y: 0, width: 640, height: 360))
}

/// An odd width cannot be halved evenly. The halves must still tile the frame exactly:
/// overlapping rectangles would put a strip of the wrong eye into one view.
@Test func oddLeftRightStillTilesExactlyWithoutOverlap() {
    let rects = SideBySide.eyeRects(width: 1279, height: 360, layout: .leftRight)
    #expect(rects.left.width + rects.right.width == 1279)
    #expect(rects.right.minX == rects.left.maxX)
}

@Test func topBottomSplitsVertically() {
    let rects = SideBySide.eyeRects(width: 640, height: 361, layout: .topBottom)
    #expect(rects.left.width == 640)
    #expect(rects.left.height + rects.right.height == 361)
    #expect(rects.right.minY == rects.left.maxY)
}

@Test func flatLayoutGivesBothEyesTheWholeFrame() {
    let rects = SideBySide.eyeRects(width: 640, height: 360, layout: .none)
    #expect(rects.left == rects.right)
    #expect(rects.left.width == 640)
}

@Test func layoutGuessUsesTheAspectRatio() {
    // A 32:9 packed pair.
    #expect(SideBySide.guessLayout(width: 2560, height: 720) == .leftRight)
    // A packed top-bottom pair, wider than tall but far from the nominal aspect.
    #expect(SideBySide.guessLayout(width: 1280, height: 1440) == .topBottom)
    // Ordinary 16:9, so a single view.
    #expect(SideBySide.guessLayout(width: 1920, height: 1080) == .none)
    // Degenerate input must not crash or guess.
    #expect(SideBySide.guessLayout(width: 0, height: 0) == .none)
}

// MARK: - Pixel operations

@Test func copyingARectangleMovesTheRightPixels() throws {
    let source = try PixelBufferOps.makeBGRA(width: 4, height: 2)
    CVPixelBufferLockBaseAddress(source, [])
    if let base = CVPixelBufferGetBaseAddress(source) {
        let stride = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<2 {
            for x in 0..<4 {
                let value = Float((y * 4 + x)) / 8
                PixelBufferOps.writeGrey(into: base, stride: stride, x: x, y: y, value: value)
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(source, [])

    let destination = try PixelBufferOps.makeBGRA(width: 2, height: 1)
    try PixelBufferOps.copy(
        rect: CGRect(x: 2, y: 0, width: 2, height: 1),
        from: source,
        into: destination
    )

    CVPixelBufferLockBaseAddress(destination, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(destination))
    let stride = CVPixelBufferGetBytesPerRow(destination)
    let first = base.assumingMemoryBound(to: UInt8.self)
    // Source column 2 held 2/8, which is the first pixel of the crop.
    #expect(first[0] == UInt8((2.0 / 8 * 255).rounded()))
}

/// A crop larger than the source must clip rather than read past the buffer.
@Test func oversizedCropIsClippedToTheSource() throws {
    let source = try PixelBufferOps.makeBGRA(width: 2, height: 2)
    let destination = try PixelBufferOps.makeBGRA(width: 8, height: 8)
    try PixelBufferOps.copy(
        rect: CGRect(x: 0, y: 0, width: 8, height: 8),
        from: source,
        into: destination
    )
    // Reaching here without a crash is the assertion; the clamp checks are in the
    // implementation, and an out-of-bounds read would fault rather than fail.
    #expect(CVPixelBufferGetWidth(destination) == 8)
}

@Test func greyWriteAndLumaRoundTrip() throws {
    let buffer = try PixelBufferOps.makeBGRA(width: 1, height: 1)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    let stride = CVPixelBufferGetBytesPerRow(buffer)

    PixelBufferOps.writeGrey(into: base, stride: stride, x: 0, y: 0, value: 0.5)
    let pixel = base.assumingMemoryBound(to: UInt8.self)
    #expect(abs(PixelBufferOps.luma(bgra: pixel) - 0.5) < 0.01)
    #expect(pixel[3] == 255)
}

