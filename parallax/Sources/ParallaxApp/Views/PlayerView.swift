#if os(iOS)
import SwiftUI
import ParallaxKit

/// The window itself, plus chrome that appears on a long press.
///
/// The original revealed its panel on a force touch. Modern iPhones have no pressure
/// channel, so the trigger is a deliberate 0.35 s press, which is the closest thing
/// Haptic Touch offers.
struct PlayerView: View {
    @EnvironmentObject private var model: PlayerModel
    let clip: ClipItem

    @State private var chromeVisible = false
    @State private var showingSettings = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalVideoView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                unavailable
            }

            if chromeVisible {
                VStack {
                    Spacer()
                    chrome
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12) { revealChrome() }
        .sensoryFeedback(.impact(weight: .light), trigger: chromeVisible)
        .statusBarHidden()
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            model.startDisplayLink()
            model.startTracking()
            await model.open(clip)
        }
        .onDisappear {
            hideTask?.cancel()
            model.stopDisplayLink()
            model.stopTracking()
        }
        .onChange(of: showingSettings) { _, showing in
            if !showing { scheduleHide() }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(model.rendererError ?? "This device cannot render the window.")
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
    }

    private var chrome: some View {
        VStack(spacing: 14) {
            if let name = model.status.clipName {
                Text(name)
                    .font(.headline)
            }

            if case .failed(let message) = model.status {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }

            Slider(
                value: Binding(get: { model.progress }, set: { model.seek(toProgress: $0) }),
                in: 0...1
            )

            HStack(spacing: 22) {
                Button {
                    model.togglePlayback()
                    scheduleHide()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }

                Button {
                    model.resetCentre()
                    scheduleHide()
                } label: {
                    Image(systemName: "scope")
                        .font(.title2)
                }

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2)
                }

                Text(trackingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .padding(.horizontal, 18)
        .padding(.bottom, 22)
    }

    private var trackingLabel: String {
        if model.trackingUnavailable { return "No face tracking" }
        if !model.isTracking { return "Searching" }
        if let ipd = model.eyeDistance { return String(format: "%.1f mm", ipd * 1000) }
        return "Tracked"
    }

    private func revealChrome() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            chromeVisible = true
        }
        scheduleHide()
    }

    /// Chrome springs in, waits, and leaves, so the window is unencumbered while the
    /// viewer is actually looking through it.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !showingSettings else { return }
            withAnimation(.easeOut(duration: 0.25)) { chromeVisible = false }
        }
    }
}
#endif
