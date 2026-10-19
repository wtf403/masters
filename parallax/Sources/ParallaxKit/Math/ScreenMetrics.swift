import Foundation
import simd
#if canImport(Darwin)
import Darwin
#endif

/// Physical display geometry for the off-axis projection.
///
/// iOS exposes no API for the physical size of a screen, so the size has to come
/// from a table. The original app hard-coded 135 mm x 62 mm, which is the iPhone X
/// panel in landscape: 2436 x 1125 pixels at 458 per inch, so 135.1 mm x 62.4 mm.
/// The entries below are derived the same way, panel pixels divided by density.
///
/// These values are derived, not measured. Every entry needs verification on real
/// hardware, which is why calibration exists: a single multiplier the user can tune
/// on device without a new build.
public struct ScreenMetrics: Sendable, Equatable {

    public enum Origin: Sendable, Equatable {
        case knownDevice(String)
        case calibrated
        case estimate
    }

    /// A published display panel specification.
    public struct Panel: Sendable, Equatable {
        public var pixelsWide: Float
        public var pixelsHigh: Float
        public var pixelsPerInch: Float

        public var widthMillimetres: Float { pixelsWide / pixelsPerInch * 25.4 }
        public var heightMillimetres: Float { pixelsHigh / pixelsPerInch * 25.4 }

        public init(pixelsWide: Float, pixelsHigh: Float, pixelsPerInch: Float) {
            self.pixelsWide = pixelsWide
            self.pixelsHigh = pixelsHigh
            self.pixelsPerInch = pixelsPerInch
        }
    }

    public var width: Float
    public var height: Float
    public var origin: Origin

    /// Panel orientation, which decides whether width and height are swapped.
    public enum Orientation: Sendable, Equatable {
        case portrait
        case landscape
    }

    public init(width: Float, height: Float, origin: Origin) {
        self.width = width
        self.height = height
        self.origin = origin
    }

    /// Machine identifier to panel. Identifiers come from uname, for example
    /// iPhone17,1. Verify against real hardware before trusting a new entry.
    public static let panels: [String: Panel] = [
        // iPhone X, XS, 11 Pro
        "iPhone10,3": Panel(pixelsWide: 1125, pixelsHigh: 2436, pixelsPerInch: 458),
        "iPhone10,6": Panel(pixelsWide: 1125, pixelsHigh: 2436, pixelsPerInch: 458),
        "iPhone11,2": Panel(pixelsWide: 1125, pixelsHigh: 2436, pixelsPerInch: 458),
        // XS Max, 11 Pro Max
        "iPhone11,4": Panel(pixelsWide: 1242, pixelsHigh: 2688, pixelsPerInch: 458),
        "iPhone11,6": Panel(pixelsWide: 1242, pixelsHigh: 2688, pixelsPerInch: 458),
        // XR, 11
        "iPhone11,8": Panel(pixelsWide: 828, pixelsHigh: 1792, pixelsPerInch: 326),
        "iPhone12,1": Panel(pixelsWide: 828, pixelsHigh: 1792, pixelsPerInch: 326),
        // 11 Pro
        "iPhone12,3": Panel(pixelsWide: 1125, pixelsHigh: 2436, pixelsPerInch: 458),
        // 11 Pro Max
        "iPhone12,5": Panel(pixelsWide: 1242, pixelsHigh: 2688, pixelsPerInch: 458),
        // 12 mini
        "iPhone13,1": Panel(pixelsWide: 1080, pixelsHigh: 2340, pixelsPerInch: 476),
        // 12, 12 Pro, 13, 13 Pro, 14
        "iPhone13,2": Panel(pixelsWide: 1170, pixelsHigh: 2532, pixelsPerInch: 460),
        "iPhone13,3": Panel(pixelsWide: 1170, pixelsHigh: 2532, pixelsPerInch: 460),
        "iPhone14,5": Panel(pixelsWide: 1170, pixelsHigh: 2532, pixelsPerInch: 460),
        "iPhone14,2": Panel(pixelsWide: 1170, pixelsHigh: 2532, pixelsPerInch: 460),
        "iPhone14,7": Panel(pixelsWide: 1170, pixelsHigh: 2532, pixelsPerInch: 460),
        // 12 Pro Max, 13 Pro Max, 14 Plus
        "iPhone13,4": Panel(pixelsWide: 1284, pixelsHigh: 2778, pixelsPerInch: 458),
        "iPhone14,3": Panel(pixelsWide: 1284, pixelsHigh: 2778, pixelsPerInch: 458),
        "iPhone14,8": Panel(pixelsWide: 1284, pixelsHigh: 2778, pixelsPerInch: 458),
        // 14 Pro, 15, 15 Pro
        "iPhone15,2": Panel(pixelsWide: 1179, pixelsHigh: 2556, pixelsPerInch: 460),
        "iPhone15,4": Panel(pixelsWide: 1179, pixelsHigh: 2556, pixelsPerInch: 460),
        "iPhone16,1": Panel(pixelsWide: 1179, pixelsHigh: 2556, pixelsPerInch: 460),
        // 14 Pro Max, 15 Plus, 15 Pro Max
        "iPhone15,3": Panel(pixelsWide: 1290, pixelsHigh: 2796, pixelsPerInch: 460),
        "iPhone15,5": Panel(pixelsWide: 1290, pixelsHigh: 2796, pixelsPerInch: 460),
        "iPhone16,2": Panel(pixelsWide: 1290, pixelsHigh: 2796, pixelsPerInch: 460),
        // 16 Pro
        "iPhone17,1": Panel(pixelsWide: 1206, pixelsHigh: 2622, pixelsPerInch: 460),
        // 16 Pro Max, 16 Plus
        "iPhone17,2": Panel(pixelsWide: 1320, pixelsHigh: 2868, pixelsPerInch: 460),
        "iPhone17,4": Panel(pixelsWide: 1320, pixelsHigh: 2868, pixelsPerInch: 460),
    ]

    /// Panel size in metres for a machine identifier, or a fallback estimate.
    ///
    /// - Parameters:
    ///   - identifier: machine identifier such as iPhone17,1, or nil when unknown.
    ///   - calibrationMultiplier: user-tuned scale applied on top, default 1.
    public static func forMachineIdentifier(
        _ identifier: String?,
        calibrationMultiplier: Float = 1
    ) -> ScreenMetrics {
        let clamped = min(max(calibrationMultiplier, 0.5), 1.5)

        if let identifier, let panel = panels[identifier] {
            return ScreenMetrics(
                width: panel.widthMillimetres / 1000 * clamped,
                height: panel.heightMillimetres / 1000 * clamped,
                origin: clamped == 1 ? .knownDevice(identifier) : .calibrated
            )
        }

        // Fallback: a typical modern phone panel, 6.1 inch class.
        return ScreenMetrics(
            width: 0.0651 * clamped,
            height: 0.1411 * clamped,
            origin: clamped == 1 ? .estimate : .calibrated
        )
    }

    /// Machine identifier from the kernel, for example iPhone17,1.
    ///
    /// `hw.machine` is the documented way to identify a device without asking the
    /// user or the App Store, and it is what the panel table is keyed on.
    public static func machineIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else { return nil }

        // String(cString:) is deprecated for this shape of buffer; decode the
        // bytes up to the null terminator explicitly instead.
        let bytes = machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let identifier = String(decoding: bytes, as: UTF8.self)
        return identifier.isEmpty ? nil : identifier
    }

    /// Screen geometry for the device the app is running on, with the user's
    /// calibration applied.
    public static func current(calibrationMultiplier: Float = 1) -> ScreenMetrics {
        forMachineIdentifier(machineIdentifier(), calibrationMultiplier: calibrationMultiplier)
    }

    /// Screen rectangle for the projection, in the device's frame.
    ///
    /// width and height are always the panel's portrait dimensions. Landscape
    /// swaps them, which is what reproduces the original's 135 x 62 mm rectangle.
    public func screen(
        for orientation: Orientation = .portrait,
        centreOffset: SIMD2<Float> = .zero
    ) -> OffAxisProjection.Screen {
        switch orientation {
        case .portrait:
            return OffAxisProjection.Screen(width: width, height: height, centreOffset: centreOffset)
        case .landscape:
            return OffAxisProjection.Screen(width: height, height: width, centreOffset: centreOffset)
        }
    }
}

