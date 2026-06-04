import SwiftUI
import RoomPlan
import RealityKit
import ARKit
import SceneKit

@available(iOS 16.0, *)
struct RoomCaptureModeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = RoomCaptureManager()
    
    var onModelReady: ((URL) -> Void)?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // AR feed with live mesh overlay
            HeadlessRoomCaptureViewRepresentable(captureSession: manager.captureSession,
                                                 meshOverlay: manager.meshOverlay)
                .ignoresSafeArea()
            
            // UI Overlay
            VStack {
                HStack {
                    // Coverage indicator (top-left)
                    if manager.isScanning {
                        CoverageIndicator(ratio: manager.coverageRatio)
                            .padding(.leading)
                    }
                    
                    Spacer()
                    
                    Button {
                        manager.stopSession()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                
                // Legend (shown during scanning)
                if manager.isScanning {
                    MeshLegendView()
                        .padding(.top, 4)
                }
                
                Spacer()
                
                // Bottom controls
                VStack(spacing: 20) {
                    if manager.isExporting {
                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("Assembling Room Model...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                    } else if manager.isScanning {
                        Button {
                            manager.finishScanning()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Done Scanning")
                                    .fontWeight(.bold)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        }
                    } else {
                        Button {
                            manager.startSession()
                        } label: {
                            HStack {
                                Image(systemName: "camera.viewfinder")
                                Text("Start Room Scan")
                                    .fontWeight(.bold)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        }
                    }
                }
                .padding()
            }
        }
        .onDisappear {
            manager.stopSession()
        }
        .onChange(of: manager.finalURL) { _, url in
            if let url = url {
                onModelReady?(url)
                dismiss()
            }
        }
    }
}

// MARK: - Coverage Indicator
struct CoverageIndicator: View {
    let ratio: Float   // 0..1

    var color: Color {
        if ratio > 0.7 { return .green }
        if ratio > 0.4 { return .yellow }
        return .orange
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text("Coverage \(Int(ratio * 100))%")
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Mesh Legend
struct MeshLegendView: View {
    var body: some View {
        HStack(spacing: 12) {
            legendDot(.green,  "High")
            legendDot(.yellow, "Medium")
            legendDot(.red,    "Low")
            legendDot(.cyan,   "No LiDAR")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.white)
        }
    }
}

// MARK: - ARSCNView Representable (with mesh overlay coordinator)
@available(iOS 16.0, *)
struct HeadlessRoomCaptureViewRepresentable: UIViewRepresentable {
    let captureSession: RoomCaptureSession
    let meshOverlay: LiveMeshOverlay

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = captureSession.arSession
        view.autoenablesDefaultLighting = true
        view.automaticallyUpdatesLighting = true
        // Attach the live mesh overlay as the delegate
        meshOverlay.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        // Detach is handled by manager.stopSession()
    }
}

// MARK: - RoomCaptureManager
@MainActor
@available(iOS 16.0, *)
class RoomCaptureManager: NSObject, ObservableObject, RoomCaptureSessionDelegate {
    let captureSession: RoomCaptureSession
    let meshOverlay = LiveMeshOverlay()

    @Published var isScanning = false
    @Published var isExporting = false
    @Published var finalURL: URL?
    @Published var coverageRatio: Float = 0

    // Refresh coverage from overlay periodically
    private var coverageTimer: Timer?

    override init() {
        self.captureSession = RoomCaptureSession()
        super.init()
        self.captureSession.delegate = self
    }

    func startSession() {
        // Enable LiDAR scene reconstruction if available
        let config = RoomCaptureSession.Configuration()
        captureSession.run(configuration: config)
        isScanning = true
        isExporting = false
        finalURL = nil

        // Poll coverage every 0.5s
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.coverageRatio = self?.meshOverlay.highConfidenceRatio ?? 0
            }
        }
    }

    func stopSession() {
        captureSession.stop()
        isScanning = false
        coverageTimer?.invalidate()
        coverageTimer = nil
        meshOverlay.detach()
    }

    func finishScanning() {
        isScanning = false
        isExporting = true
        coverageTimer?.invalidate()
        coverageTimer = nil
        captureSession.stop()
    }

    // MARK: - RoomCaptureSessionDelegate

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error = error {
            print("⚠️ RoomCaptureSession ended with error: \(error.localizedDescription)")
            Task { @MainActor in self.isExporting = false }
            return
        }

        Task {
            do {
                print(" Building parametric Room USDZ...")
                let builder = RoomBuilder(options: [.beautifyObjects])
                let capturedRoom = try await builder.capturedRoom(from: data)

                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RoomScan_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("room.usdz")

                try capturedRoom.export(to: url)
                print("✅ Room scan exported to: \(url.path)")

                await MainActor.run {
                    self.isExporting = false
                    self.finalURL = url
                }
            } catch {
                print("❌ Failed to build or export room: \(error.localizedDescription)")
                await MainActor.run { self.isExporting = false }
            }
        }
    }
}
