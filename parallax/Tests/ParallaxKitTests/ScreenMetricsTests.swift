import Testing
import simd
@testable import ParallaxKit

@Test func iPhoneXPanelReproducesTheHardCodedRectangle() {
    // The original hard-coded 135 mm x 62 mm for landscape. Stored dimensions are
    // portrait, so landscape must produce exactly that rectangle.
    let metrics = ScreenMetrics.forMachineIdentifier("iPhone10,3")
    #expect(metrics.origin == .knownDevice("iPhone10,3"))

    let portrait = metrics.screen(for: .portrait)
    #expect(abs(portrait.width - 0.0624) < 0.001)
    #expect(abs(portrait.height - 0.1351) < 0.001)

    let landscape = metrics.screen(for: .landscape)
    #expect(abs(landscape.width - 0.135) < 0.001)
    #expect(abs(landscape.height - 0.062) < 0.001)
}

@Test func unknownDeviceFallsBackToAnEstimate() {
    let metrics = ScreenMetrics.forMachineIdentifier("iPhone99,9")
    #expect(metrics.origin == .estimate)
    #expect(metrics.width > 0)
    #expect(metrics.height > 0)
}

@Test func calibrationScalesTheScreenAndIsClamped() {
    let scaled = ScreenMetrics.forMachineIdentifier("iPhone10,3", calibrationMultiplier: 1.1)
    #expect(abs(scaled.width - 0.0624 * 1.1) < 0.001)
    #expect(scaled.origin == .calibrated)

    let clamped = ScreenMetrics.forMachineIdentifier("iPhone10,3", calibrationMultiplier: 99)
    #expect(clamped.width <= 0.0624 * 1.5 + 0.001)
}

@Test func everyKnownPanelIsPortraitTaller() {
    for (identifier, panel) in ScreenMetrics.panels {
        #expect(panel.heightMillimetres > panel.widthMillimetres, "panel for \(identifier)")
    }
}

