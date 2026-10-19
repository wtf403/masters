#if os(iOS)
import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct SpatialVideoLibraryView: View {
    @State private var clips: [ClipItem] = []
    @State private var importing = false
    @State private var diagnosticClip: ClipItem?
    @State private var didOpenDiagnosticClip = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(clips) { clip in
                        NavigationLink {
                            ParallaxSceneView(clip: clip)
                        } label: {
                            Label(clip.name, systemImage: "play.rectangle")
                        }
                    }
                } header: {
                    Text("Videos")
                } footer: {
                    Text("Open an MV-HEVC spatial video. Allow camera access, then move your head or phone to look into the video.")
                }
            }
            .navigationTitle("Spatial Videos")
            .toolbar {
                Button("Import video", systemImage: "plus") { importing = true }
            }
            .navigationDestination(item: $diagnosticClip) { clip in
                ParallaxSceneView(clip: clip)
            }
            .onAppear {
                refresh()
                if !didOpenDiagnosticClip, ProcessInfo.processInfo.arguments.contains("--fishtank-test"),
                   let url = Bundle.main.url(forResource: "Hummingbird", withExtension: "mov") {
                    didOpenDiagnosticClip = true
                    diagnosticClip = ClipItem(url: url)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                do {
                    for url in try result.get() { try importVideo(url) }
                    refresh()
                } catch { errorMessage = error.localizedDescription }
            }
            .onOpenURL { url in
                do { try importVideo(url); refresh() }
                catch { errorMessage = error.localizedDescription }
            }
            .alert("Couldn’t import video", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func refresh() {
        clips = ClipLibrary.clips().filter { $0.url.pathExtension.lowercased() != "scpak" }
    }

    private func importVideo(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        if destination.standardizedFileURL == url.standardizedFileURL { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        }
        try FileManager.default.copyItem(at: url, to: destination)
    }
}

#endif
