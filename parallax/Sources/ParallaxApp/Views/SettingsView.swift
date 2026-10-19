#if os(iOS)
import SwiftUI
import ParallaxKit

/// The original app's sliders, plus the settings the rebuild adds.
struct SettingsView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Parallax") {
                    VStack(alignment: .leading) {
                        Text("Amount")
                        Slider(value: $model.settings.parallaxScale, in: 0...2)
                        Text(amountCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("Content distance")
                        Slider(value: $model.settings.planeDistance, in: 0.1...2)
                        Text(String(format: "%.2f m behind the screen", model.settings.planeDistance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Renderer") {
                    Picker("Path", selection: $model.settings.renderPath) {
                        Text("Projected plane").tag(RenderPath.projectedPlane)
                        Text("Fragment warp").tag(RenderPath.fragmentWarp)
                    }
                    Picker("Debug view", selection: $model.settings.debugMode) {
                        Text("Off").tag(DebugMode.off)
                        Text("Depth").tag(DebugMode.depth)
                        Text("Full screen").tag(DebugMode.fullScreen)
                    }
                }

                Section("Screen") {
                    VStack(alignment: .leading) {
                        Text("Size calibration")
                        Slider(value: $model.settings.calibrationMultiplier, in: 0.5...1.5)
                        Text(calibrationCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Tracking") {
                    LabeledContent("State", value: model.isTracking ? "Tracked" : "Searching")
                    LabeledContent("Poses buffered", value: "\(model.poseCount)")
                    if let ipd = model.eyeDistance {
                        LabeledContent("Interpupillary", value: String(format: "%.1f mm", ipd * 1000))
                    }
                    if let device = model.deviceIdentifier {
                        LabeledContent("Device", value: device)
                    }
                    Button("Re-centre the window") { model.resetCentre() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var amountCaption: String {
        let value = model.settings.parallaxScale
        if value <= 0.01 { return "Flat: the screen stops behaving as a window." }
        if value < 0.8 { return "Softer than authored." }
        if value <= 1.2 { return "As authored." }
        return "Stronger than authored, and likelier to cause discomfort."
    }

    private var calibrationCaption: String {
        let origin = ScreenMetrics.forMachineIdentifier(
            model.deviceIdentifier,
            calibrationMultiplier: model.settings.calibrationMultiplier
        ).origin
        switch origin {
        case .knownDevice:
            return "Panel size taken from the device table."
        case .calibrated:
            return "Table size scaled by \(String(format: "%.2f", model.settings.calibrationMultiplier))."
        case .estimate:
            return "This device is not in the table, so the size is estimated. Tune it against a known object."
        }
    }
}
#endif
