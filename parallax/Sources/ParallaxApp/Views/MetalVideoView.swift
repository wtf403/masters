#if os(iOS)
import SwiftUI
import MetalKit
import ParallaxKit

/// Hosts the renderer's `MTKView` in SwiftUI.
///
/// This is the only view that is not SwiftUI, which is why it is isolated here: the
/// renderer needs a drawable it can present to, and everything around it stays in
/// SwiftUI.
struct MetalVideoView: UIViewRepresentable {
    let renderer: ParallaxRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif
