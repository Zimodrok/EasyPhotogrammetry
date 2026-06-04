import SwiftUI
import ARKit
import SceneKit
import RealityKit

// MARK: - Measurement Mode (Fully Isolated — no CaptureManager)
struct MeasurementModeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = MeasurementSession()

    var body: some View {
        ZStack {
            // AR Camera feed
            ARMeasurementView(session: session)
                .ignoresSafeArea()

            // Instruction overlay
            VStack {
                // Top bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.5).background(Material.thin))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
                    }
                    Spacer()
                    Text("Measure Object")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5).background(Material.thin))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
                    Spacer()
                    Button {
                        session.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.5).background(Material.thin))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                Spacer()

                // Main distance readout
                if let dist = session.measuredDistance {
                    VStack(spacing: 6) {
                        Text(formatDistance(dist))
                            .font(.system(size: 46, weight: .black, design: .rounded))
                            .foregroundStyle(Color("ClassicSaddle")) // Highlight measurement with Saddle Accent!
                        Text(formatDistanceAlt(dist))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 20)
                    .background(Color.black.opacity(0.6).background(Material.thin))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color("ClassicSaddle").opacity(0.35), lineWidth: 1.0))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .padding(.bottom, 36)
                } else {
                    // Status pill
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color("ClassicSaddle"))
                        Text(session.pointA == nil ? "Tap to place Point A" : "Tap to place Point B")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.black.opacity(0.6).background(Material.thin))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .padding(.bottom, 36)
                }
            }

            // Crosshair in the center
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    // MARK: Formatting

    private func formatDistance(_ meters: Float) -> String {
        if meters < 1.0 {
            return String(format: "%.1f cm", meters * 100)
        } else {
            return String(format: "%.2f m", meters)
        }
    }

    private func formatDistanceAlt(_ meters: Float) -> String {
        let inches = meters * 39.3701
        if inches < 12 {
            return String(format: "%.1f in", inches)
        } else {
            let feet = inches / 12
            return String(format: "%.1f ft", feet)
        }
    }
}

// MARK: - Session ViewModel
@MainActor
final class MeasurementSession: NSObject, ObservableObject {
    @Published var pointA: SIMD3<Float>? = nil
    @Published var pointB: SIMD3<Float>? = nil
    @Published var measuredDistance: Float? = nil

    // Strong ref so the coordinator can find it
    var scnView: ARSCNView?

    private var lineNode: SCNNode?
    private var ballNodeA: SCNNode?
    private var ballNodeB: SCNNode?
    private var labelNode: SCNNode?

    let arSession = ARSession()

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        arSession.run(config)
    }

    func stop() {
        arSession.pause()
    }

    func reset() {
        pointA = nil
        pointB = nil
        measuredDistance = nil
        lineNode?.removeFromParentNode()
        ballNodeA?.removeFromParentNode()
        ballNodeB?.removeFromParentNode()
        labelNode?.removeFromParentNode()
        lineNode = nil
        ballNodeA = nil
        ballNodeB = nil
        labelNode = nil
    }

    /// Called when user taps the AR view
    func handleTap(at screenPoint: CGPoint, in view: ARSCNView) {
        // Raycast against real-world geometry (LiDAR mesh preferred)
        let query = arSession.currentFrame?.raycastQuery(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: .any
        )
        guard let q = query else { return }
        let results = arSession.raycast(q)
        guard let hit = results.first else { return }

        let pos = SIMD3<Float>(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )

        if pointA == nil {
            pointA = pos
            placeMarker(at: pos, color: .systemGreen, node: &ballNodeA, in: view)
        } else if pointB == nil {
            pointB = pos
            placeMarker(at: pos, color: .systemRed, node: &ballNodeB, in: view)
            drawLine(from: pointA!, to: pos, in: view)
            measuredDistance = simd_distance(pointA!, pos)
        } else {
            // Third tap: reset and start new measurement
            reset()
            pointA = pos
            placeMarker(at: pos, color: .systemGreen, node: &ballNodeA, in: view)
        }
    }

    // MARK: SceneKit helpers

    private func placeMarker(at pos: SIMD3<Float>, color: UIColor, node: inout SCNNode?, in view: ARSCNView) {
        let sphere = SCNSphere(radius: 0.008)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .physicallyBased

        let n = SCNNode(geometry: sphere)
        n.simdPosition = pos
        view.scene.rootNode.addChildNode(n)
        node = n
    }

    private func drawLine(from a: SIMD3<Float>, to b: SIMD3<Float>, in view: ARSCNView) {
        lineNode?.removeFromParentNode()

        let distance = simd_distance(a, b)
        let midpoint = (a + b) / 2

        // Cylinder representing the line
        let cyl = SCNCylinder(radius: 0.002, height: CGFloat(distance))
        cyl.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.9)
        cyl.firstMaterial?.lightingModel = .physicallyBased

        let lineN = SCNNode(geometry: cyl)
        lineN.simdPosition = midpoint

        // Orient from a → b
        let dir = normalize(b - a)
        let up = SIMD3<Float>(0, 1, 0)
        let axis = normalize(cross(up, dir))
        let dot = simd_dot(up, dir)
        let angle = acos(dot)
        if !axis.x.isNaN && !axis.y.isNaN && !axis.z.isNaN {
            lineN.simdRotation = SIMD4<Float>(axis.x, axis.y, axis.z, angle)
        }

        view.scene.rootNode.addChildNode(lineN)
        lineNode = lineN
    }
}

// MARK: - UIViewRepresentable
struct ARMeasurementView: UIViewRepresentable {
    @ObservedObject var session: MeasurementSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session.arSession
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X

        session.scnView = view

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    class Coordinator: NSObject {
        let session: MeasurementSession
        init(session: MeasurementSession) { self.session = session }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let view = gr.view as? ARSCNView else { return }
            let pt = gr.location(in: view)
            Task { @MainActor in
                self.session.handleTap(at: pt, in: view)
            }
        }
    }
}
