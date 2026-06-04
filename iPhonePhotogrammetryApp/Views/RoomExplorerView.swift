import SwiftUI
@preconcurrency import SceneKit

// MARK: - Room Explorer  (Free-Fly First-Person Camera, no physics)
// Fully isolated — no ARKit, no camera, no CaptureManager.
struct RoomExplorerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    // Left joystick → movement, right drag → look
    @State private var joystick: CGVector = .zero
    @State private var verticalInput: Float = 0
    @State private var isLoading = true
    @State private var loadError: String? = nil

    // Coordinator lives here so we can send it input
    @State private var coordinator = ExplorerCoordinator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 3D View
            ExplorerSceneView(coordinator: coordinator)
                .ignoresSafeArea()

            // Loading
            if isLoading && loadError == nil {
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.4).tint(.white)
                    Text("Loading room…")
                        .font(.headline).foregroundStyle(.white)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }

            // Error
            if let err = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44)).foregroundStyle(.orange)
                    Text(err).font(.headline).multilineTextAlignment(.center).foregroundStyle(.white)
                    Button("Dismiss") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding()
            }

            // HUD
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).foregroundStyle(.white.opacity(0.85))
                            .padding(8).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("Room Explorer")
                        .font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding()

                Spacer()

                HStack(alignment: .bottom) {
                    // Left joystick → move
                    VirtualJoystick(velocity: $joystick)
                        .frame(width: 140, height: 140)
                        .padding(.leading, 24).padding(.bottom, 48)
                        .onChange(of: joystick) { _, v in
                            coordinator.joystick = v
                        }

                    Spacer()

                    if !isLoading {
                        HStack(spacing: 32) {
                            VStack(spacing: 4) {
                                Image(systemName: "hand.draw.fill")
                                    .font(.title2).foregroundStyle(.white.opacity(0.4))
                                Text("Drag to look")
                                    .font(.caption).foregroundStyle(.white.opacity(0.35))
                            }
                            
                            VerticalSlider(value: $verticalInput)
                                .onChange(of: verticalInput) { _, v in
                                    coordinator.verticalInput = v
                                }
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 48)
                    }
                }
            }
        }
        .onAppear {
            coordinator.load(url: url) { err in
                if let err = err {
                    loadError = err
                }
                isLoading = false
            }
        }
        .onDisappear {
            coordinator.stop()
        }
        // Right-side pan (look)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    // Only react to drags starting in the right 60% of the screen, leaving 80pt for the altitude slider
                    let screenW = UIScreen.main.bounds.width
                    if v.startLocation.x > screenW * 0.38 && v.startLocation.x < screenW - 80 {
                        coordinator.applyLookDelta(dx: Float(v.translation.width),
                                                   dy: Float(v.translation.height))
                    }
                }
                .onEnded { _ in
                    coordinator.resetLookAccumulator()
                }
        )
    }
}

// MARK: - Coordinator
@Observable
final class ExplorerCoordinator: NSObject {
    var scnView: SCNView?
    var cameraNode: SCNNode?

    // Input
    var joystick: CGVector = .zero
    var verticalInput: Float = 0

    // Look state
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var lastLookX: Float = 0
    private var lastLookY: Float = 0
    private let pitchLimit: Float = 1.15

    // Game loop
    nonisolated(unsafe) var displayLink: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private let moveSpeed: Float = 1.8   // m/s

    // MARK: Load

    func load(url: URL, completion: @escaping (String?) -> Void) {
        print(" Explorer: Starting to load URL: \(url)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print(" Explorer: Instantiating SCNScene...")
                let scene = try SCNScene(url: url, options: [
                    SCNSceneSource.LoadingOption.checkConsistency: false,
                    SCNSceneSource.LoadingOption.createNormalsIfAbsent: true
                ])
                print(" Explorer: SCNScene instantiated successfully.")
                DispatchQueue.main.async {
                    print(" Explorer: Switching to main thread to build scene.")
                    guard let view = self.scnView else {
                        print(" Explorer: Error - scnView is nil.")
                        completion("Scene view not ready")
                        return
                    }
                    print(" Explorer: Calling buildScene...")
                    self.buildScene(scene, in: view)
                    print(" Explorer: buildScene completed.")
                    completion(nil)
                }
            } catch {
                print(" Explorer: Error instantiating SCNScene: \(error)")
                DispatchQueue.main.async {
                    completion("Failed to load model: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        print(" Explorer: Stopping CADisplayLink.")
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Build Scene

    @MainActor private func buildScene(_ scene: SCNScene, in view: SCNView) {
        print(" Explorer: Inside buildScene.")
        view.scene = scene
        scene.background.contents = UIColor(white: 0.06, alpha: 1)

        // Make ALL materials double-sided + unlit
        // Photogrammetry meshes have baked lighting in their textures.
        // Using `.constant` means SceneKit shows the texture colour as-is
        // without applying additional lighting math (no wash-out).
        // `isDoubleSided = true` ensures back-faces render when you're
        // standing INSIDE the model looking outward.
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            for mat in geo.materials {
                mat.isDoubleSided = true
                mat.lightingModel = .constant   // show baked textures as-is
            }
        }

        // Soft ambient fill (only needed so untextured faces aren't pitch black)
        let ambient = SCNNode(); ambient.light = SCNLight()
        ambient.light!.type = .ambient; ambient.light!.intensity = 300
        ambient.light!.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        // Measure bounds for spawn point
        print(" Explorer: Measuring bounding box...")
        let (minB, maxB) = scene.rootNode.boundingBox
        print(" Explorer bounds: X[\(minB.x)…\(maxB.x)] Y[\(minB.y)…\(maxB.y)] Z[\(minB.z)…\(maxB.z)]")

        let cx = (minB.x + maxB.x) / 2
        let cz = (minB.z + maxB.z) / 2
        // Spawn at floor level + 1.65m eye height
        let spawnY = minB.y + 1.65
        print(" Explorer: Setting camera at (X: \(cx), Y: \(spawnY), Z: \(cz))")

        // Camera node (free-fly — no physics body)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera!.fieldOfView = 82
        cam.camera!.automaticallyAdjustsZRange = true
        cam.position = SCNVector3(cx, spawnY, cz)
        cam.name = "explorerCamera"
        scene.rootNode.addChildNode(cam)
        cameraNode = cam
        view.pointOfView = cam

        // Apply initial rotation
        updateCameraRotation()

        // Start game loop
        print(" Explorer: Starting CADisplayLink game loop.")
        displayLink?.invalidate()
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
        lastTime = CACurrentMediaTime()
        print(" Explorer: buildScene fully setup.")
    }

    // MARK: Game Loop

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 1.0 / 20.0))
        lastTime = now
        guard let cam = cameraNode else { return }

        let jx = Float(joystick.dx)   // strafe
        let jz = Float(joystick.dy)   // forward (+y = backward on screen)

        guard abs(jx) > 0.02 || abs(jz) > 0.02 || abs(verticalInput) > 0.02 else { return }

        // Rotate the local joystick direction (X = right, Z = back/forward) by the camera's yaw angle
        let dist = moveSpeed * dt
        let dx = (jx * cos(yaw) + jz * sin(yaw)) * dist
        let dz = (-jx * sin(yaw) + jz * cos(yaw)) * dist

        let dy = verticalInput * moveSpeed * dt

        cam.position = SCNVector3(
            cam.position.x + dx,
            cam.position.y + dy,
            cam.position.z + dz
        )
    }

    // MARK: Look

    func applyLookDelta(dx: Float, dy: Float) {
        let sens: Float = 0.004
        yaw   -= (dx - lastLookX) * sens
        pitch -= (dy - lastLookY) * sens
        pitch = max(-pitchLimit, min(pitchLimit, pitch))
        lastLookX = dx; lastLookY = dy
        updateCameraRotation()
    }

    func resetLookAccumulator() {
        lastLookX = 0; lastLookY = 0
    }

    private func updateCameraRotation() {
        // Apply yaw+pitch as euler angles
        cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
    }

    deinit { displayLink?.invalidate() }
}

// MARK: - SCNView UIViewRepresentable
struct ExplorerSceneView: UIViewRepresentable {
    let coordinator: ExplorerCoordinator

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = UIColor(white: 0.06, alpha: 1)
        v.antialiasingMode = .multisampling4X
        v.allowsCameraControl = false
        v.showsStatistics = false
        coordinator.scnView = v
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
    func makeCoordinator() -> Void { () }
}

// MARK: - Virtual Joystick
struct VirtualJoystick: View {
    @Binding var velocity: CGVector
    @State private var knobOffset: CGSize = .zero
    private let radius: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
            Circle()
                .fill(.white.opacity(0.65))
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .offset(knobOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let x = max(-radius, min(radius, v.translation.width))
                    let y = max(-radius, min(radius, v.translation.height))
                    knobOffset = CGSize(width: x, height: y)
                    velocity = CGVector(dx: x / radius, dy: y / radius)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { knobOffset = .zero }
                    velocity = .zero
                }
        )
    }
}

// MARK: - Vertical Slider
struct VerticalSlider: View {
    @Binding var value: Float // -1 to 1 (up is 1, down is -1)
    @State private var knobOffset: CGFloat = 0
    private let trackHeight: CGFloat = 100
    private let knobSize: CGFloat = 40
    
    var body: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: 16, height: trackHeight)
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1.5))
            
            // Middle tick
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 24, height: 2)
            
            Circle()
                .fill(.white.opacity(0.65))
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .offset(y: knobOffset)
            
            VStack {
                Image(systemName: "chevron.up").font(.caption2).bold().foregroundStyle(.white.opacity(0.7)).padding(.bottom, 22)
                Spacer()
                Image(systemName: "chevron.down").font(.caption2).bold().foregroundStyle(.white.opacity(0.7)).padding(.top, 22)
            }
            .frame(height: trackHeight + 40)
        }
        .frame(width: 44, height: trackHeight + 40)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let maxOffset = trackHeight / 2
                    let y = max(-maxOffset, min(maxOffset, v.translation.height))
                    knobOffset = y
                    // y is negative when dragging up -> means ascend (positive value)
                    value = Float(-y / maxOffset)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { knobOffset = 0 }
                    value = 0
                }
        )
    }
}
