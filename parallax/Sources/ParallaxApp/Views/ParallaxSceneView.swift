#if os(iOS)
import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import ParallaxKit

struct ParallaxSceneView: View {
    @StateObject private var model: SceneWindowModel
    init(clip: ClipItem) {
        _model = StateObject(wrappedValue: SceneWindowModel(url: clip.url))
    }
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SceneWindow(model: model).ignoresSafeArea()
            VStack {
                HStack {
                    Button("Videos", systemImage: "chevron.left") { dismiss() }
                    Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
                    Slider(value: $model.strength, in: 0...1.5)
                        .frame(width: 120)
                        .accessibilityLabel("Depth strength")
                    Spacer()
                    Text(model.status)
                        .font(.caption.monospacedDigit())
                        .padding(8)
                        .background(.black.opacity(0.65), in: Capsule())
                }
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Close your other eye. Move your head slowly.")
                        Text(model.videoStatus)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.caption)
                    Spacer()
                    Picker("Viewing eye", selection: $model.leftEye) {
                        Text("Left eye").tag(true)
                        Text("Right eye").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 185)
                    Button("Centre") { model.recentre() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.2))
                }
                .padding(10)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .foregroundStyle(.white)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: phase) { _, value in
            if value == .active {
                Task { await model.start() }
            } else { model.stop() }
        }
    }
}

private struct SceneWindow: UIViewRepresentable {
    @ObservedObject var model: SceneWindowModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.scene = model.scene
        view.pointOfView = model.cameraNode
        model.view = view
        model.loadScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        model.loadScene()
    }
}

@MainActor
final class SceneWindowModel: NSObject, ObservableObject {
    @Published var strength: Float = 1 { didSet { videoScene?.strength = strength } }
    @Published private(set) var isPlaying = true
    @Published private(set) var videoStatus = "Opening spatial video…"
    private let url: URL
    @Published var leftEye = false {
        didSet { recentre() }
    }
    @Published private(set) var status = "Looking for your face…"

    let scene = SCNScene()
    let cameraNode = SCNNode()
    weak var view: SCNView?

    private let session = ARSession()
    private var content: SCNNode?
    private var origin: SIMD2<Float>?
    private var filteredEye: SIMD3<Float>?
    private var previousOrientation: UIInterfaceOrientation?
    private var running = false
    private var trackedFrames = 0
    private var lastDiagnosticTime = 0.0
    private var videoScene: VideoMeshScene?
    private let displayProxy = DisplayLinkProxy()
    private var displayLink: CADisplayLink?

    init(url: URL) {
        self.url = url
        super.init()
        let camera = SCNCamera()
        camera.zNear = 0.005
        camera.zFar = 10
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = UIColor.black
        session.delegate = self
        session.delegateQueue = .main
        displayProxy.onTick = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.videoScene?.update()
                let value = self.videoScene?.status ?? "Opening spatial video…"
                if self.videoStatus != value { self.videoStatus = value }
                self.updateCamera(eye: self.filteredEye ?? SIMD3<Float>(0, 0, 0.4))
                self.writeDiagnostics()
            }
        }
        updateCamera(eye: SIMD3<Float>(0, 0, 0.4))
    }

    func start() async {
        guard !running else { return }
        if displayLink == nil {
            let link = CADisplayLink(target: displayProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        videoScene?.play()
        guard ARFaceTrackingConfiguration.isSupported else {
            status = "TrueDepth face tracking is unavailable."
            return
        }
        let allowed: Bool
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
        guard allowed else {
            status = "Allow camera access in Settings → Parallax."
            return
        }
        guard !running else { return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        recentre()
    }

    func stop() {
        session.pause()
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        videoScene?.pause()
        displayLink?.invalidate()
        displayLink = nil
    }

    func recentre() {
        origin = nil
        filteredEye = nil
    }

    func togglePlayback() {
        videoScene?.toggle()
        isPlaying = videoScene?.isPlaying ?? false
    }

    func loadScene() {
        guard videoScene == nil else { return }
        do {
            let video = try VideoMeshScene(url: url)
            videoScene = video
            content = video.node
            scene.rootNode.addChildNode(video.node)
            updateCamera(eye: filteredEye ?? SIMD3<Float>(0, 0, 0.4))
            video.play()
        } catch { videoStatus = "Could not open spatial video: \(error.localizedDescription)" }
    }

    private func writeDiagnostics() {
        guard ProcessInfo.processInfo.arguments.contains("--fishtank-test"),
              CACurrentMediaTime()-lastDiagnosticTime > 2 else { return }
        lastDiagnosticTime = CACurrentMediaTime()
        let value: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "trackedFrames": trackedFrames,
            "videoFrames": videoScene?.processedFrames ?? 0,
            "processingMilliseconds": videoScene?.lastProcessingMilliseconds ?? 0,
            "tracking": status,
            "video": videoStatus,
            "eye": [filteredEye?.x ?? 0, filteredEye?.y ?? 0, filteredEye?.z ?? 0]
        ]
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) {
            try? data.write(to: directory.appendingPathComponent("fishtank-diagnostics.json"), options: .atomic)
        }
    }

    private func updateCamera(eye: SIMD3<Float>) {
        let orientation = view?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .landscapeRight
        let screen = ScreenMetrics.current().screen(
            for: orientation.isLandscape ? .landscape : .portrait
        )
        let aspect = videoScene?.aspect ?? 16.0/9.0
        let width = min(screen.width, screen.height*aspect)
        content?.simdScale = SIMD3<Float>(width / 0.135, width/aspect / 0.062, 1)
        content?.simdPosition = .zero
        let projection = OffAxisProjection(screen: screen, nearPlane: 0.005, farPlane: 10)
        cameraNode.simdPosition = eye
        cameraNode.camera?.projectionTransform = SCNMatrix4(projection.projectionMatrix(head: eye))
    }
}

extension SceneWindowModel: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked else {
            status = "Looking for your face…"
            return
        }
        let orientation = view?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .landscapeRight
        if previousOrientation != orientation {
            previousOrientation = orientation
            recentre()
        }
        // Use the selected physical eye, expressed relative to the CURRENT camera.
        // viewMatrix handles interface rotation; head rotation must not rotate the window.
        let eyeTransform = leftEye ? face.leftEyeTransform : face.rightEyeTransform
        let eyeInWorld = face.transform * eyeTransform.columns.3
        let cameraEye = frame.camera.viewMatrix(for: orientation) * eyeInWorld
        let raw = SIMD3<Float>(cameraEye.x, cameraEye.y, abs(cameraEye.z))
        guard raw.z.isFinite, raw.z > 0.12, raw.z < 1.5 else { return }
        if origin == nil { origin = SIMD2<Float>(raw.x, raw.y) }
        let centre = origin ?? .zero
        let eye = SIMD3<Float>(raw.x - centre.x, raw.y - centre.y, raw.z)
        let smoothed = filteredEye.map { $0 + (eye - $0) * 0.4 } ?? eye
        filteredEye = smoothed
        trackedFrames += 1
        updateCamera(eye: smoothed)
        status = "Tracking · \(Int(smoothed.z * 100)) cm"
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        running = false
        status = "Tracking failed: \(error.localizedDescription)"
    }

    func sessionWasInterrupted(_ session: ARSession) {
        status = "Tracking interrupted"
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        recentre()
    }
}
#endif
