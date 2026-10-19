#if os(iOS)
import SwiftUI

/// The clip list, standing in for the original app's five hard-coded scene buttons.
struct LibraryView: View {
    @EnvironmentObject private var model: PlayerModel

    var body: some View {
        NavigationStack {
            Group {
                if model.clips.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "film.stack",
                        description: Text("Copy a movie into the app's Documents folder, or add one to the bundle, then refresh.")
                    )
                } else {
                    List(model.clips) { clip in
                        NavigationLink(value: clip) {
                            Label(clip.name, systemImage: "film")
                        }
                    }
                }
            }
            .navigationTitle("Clips")
            .navigationDestination(for: ClipItem.self) { clip in
                PlayerView(clip: clip)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refreshClips()
                    }
                }
            }
        }
    }
}
#endif
