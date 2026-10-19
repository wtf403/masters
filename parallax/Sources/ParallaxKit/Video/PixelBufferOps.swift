import Foundation
import CoreVideo
import CoreGraphics

public enum PixelBufferError: Error, Equatable {
    case allocationFailed(Int32)
    case lockFailed(Int32)
    case unsupportedFormat(OSType)
    case emptyRect
}

/// Small, dependency-free pixel operations shared by the authoring tools.
///
/// Deliberately CPU-only. The authoring tools run offline once per clip, so the
/// clarity of a plain row loop beats a Metal or vImage path that cannot be read
/// without a GPU present.
public enum PixelBufferOps {

    /// A 32-bit BGRA buffer backed by an IOSurface and usable as a Metal texture.
    public static func makeBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        var buffer: CVPixelBuffer?
        var status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )

        // An IOSurface-backed buffer is what lets the renderer wrap this memory as a
        // Metal texture without a copy. Some environments refuse IOSurface allocation
        // outright, so fall back to an ordinary buffer rather than failing: a slower
        // path is better than no path, and the authoring tools do not need the texture
        // sharing at all.
        if status != kCVReturnSuccess {
            buffer = nil
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
        }

        guard status == kCVReturnSuccess, let buffer else {
            throw PixelBufferError.allocationFailed(status)
        }
        return buffer
    }

    /// Copy a rectangle out of one BGRA buffer into another.
    ///
    /// The destination is filled from its origin, so this is a crop and place rather
    /// than a blit. Rows are copied individually because the two buffers rarely share
    /// a row stride once the width changes.
    public static func copy(
        rect: CGRect,
        from source: CVPixelBuffer,
        into destination: CVPixelBuffer
    ) throws {
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        let destinationFormat = CVPixelBufferGetPixelFormatType(destination)
        guard sourceFormat == kCVPixelFormatType_32BGRA else {
            throw PixelBufferError.unsupportedFormat(sourceFormat)
        }
        guard destinationFormat == kCVPixelFormatType_32BGRA else {
            throw PixelBufferError.unsupportedFormat(destinationFormat)
        }

        let originX = Int(rect.origin.x)
        let originY = Int(rect.origin.y)
        let requestedWidth = Int(rect.width)
        let requestedHeight = Int(rect.height)
        guard requestedWidth > 0, requestedHeight > 0 else { throw PixelBufferError.emptyRect }

        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else { throw PixelBufferError.lockFailed(sourceLock) }

        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            throw PixelBufferError.lockFailed(destinationLock)
        }

        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard
            let sourceBase = CVPixelBufferGetBaseAddress(source),
            let destinationBase = CVPixelBufferGetBaseAddress(destination)
        else {
            throw PixelBufferError.lockFailed(-1)
        }

        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)

        // Never read outside the source, whatever the caller asked for.
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let width = min(
            requestedWidth,
            max(sourceWidth - originX, 0),
            CVPixelBufferGetWidth(destination)
        )
        let height = min(
            requestedHeight,
            max(sourceHeight - originY, 0),
            CVPixelBufferGetHeight(destination)
        )
        guard width > 0, height > 0 else { throw PixelBufferError.emptyRect }

        let rowBytes = width * 4
        for row in 0..<height {
            let sourceRow = sourceBase.advanced(by: (originY + row) * sourceStride + originX * 4)
            let destinationRow = destinationBase.advanced(by: row * destinationStride)
            memcpy(destinationRow, sourceRow, rowBytes)
        }
    }

    // MARK: - Greyscale access, used by the depth builder

    /// Rec. 601 luma of a BGRA pixel, normalised to 0...1.
    public static func luma(bgra pixel: UnsafePointer<UInt8>) -> Float {
        let blue = Float(pixel[0])
        let green = Float(pixel[1])
        let red = Float(pixel[2])
        return (0.114 * blue + 0.587 * green + 0.299 * red) / 255
    }

    /// Write a normalised value as an opaque grey BGRA pixel.
    public static func writeGrey(
        into base: UnsafeMutableRawPointer,
        stride: Int,
        x: Int,
        y: Int,
        value: Float
    ) {
        let level = UInt8(max(0, min(255, (value * 255).rounded())))
        let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        pixel[0] = level
        pixel[1] = level
        pixel[2] = level
        pixel[3] = 255
    }
}

