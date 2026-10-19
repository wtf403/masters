#if os(iOS)
import SwiftUI

@main
struct ParallaxApp: App {
    var body: some Scene {
        WindowGroup { SpatialVideoLibraryView() }
    }
}
#endif
