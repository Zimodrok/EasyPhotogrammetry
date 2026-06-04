import Foundation
import RoomPlan
import ARKit
import Combine

/// Manages an Apple RoomPlan scan running in parallel with the existing
/// photogrammetry capture.  Shares the same ARSession so there is zero
/// camera contention — RoomPlan piggybacks on the LiDAR/camera feed
/// that CaptureManager is already driving.
@MainActor
final class RoomPlanManager: NSObject, ObservableObject {

    // MARK: - Published state

    /// The latest room snapshot coming from RoomPlan (walls, objects, etc.)
    @Published var capturedRoom: CapturedRoom?

    /// Human-readable live status string for the HUD overlay
    @Published var statusText: String = "Initializing RoomPlan…"

    /// True while a scan is actively running
    @Published var isScanning: Bool = false
    
    /// Set to true if SLAM crashed (World tracking failure). Used to flag metadata.json
    /// so the Mac can fall back to unordered photogrammetry mode.
    @Published private(set) var slamFailed: Bool = false

    // MARK: - Outputs

    /// Final captured room data, set once the scan is stopped
    private(set) var capturedRoomData: CapturedRoomData?

    /// The URL where the parametric room model is exported
    var exportedRoomURL: URL?

    // MARK: - Private

    private var roomSession: RoomCaptureSession?

    // MARK: - Lifecycle

    /// Creates the RoomPlan session backed by the given ARSession.
    /// - Parameter arSession: The ARSession already owned by ARView/CaptureManager.
    func configure(with arSession: ARSession) {
        guard RoomCaptureSession.isSupported else {
            statusText = "⚠️ RoomPlan not supported on this device"
            print("⚠️ RoomPlan requires LiDAR — not available on this device")
            return
        }

        roomSession = RoomCaptureSession(arSession: arSession)
        roomSession?.delegate = self
        statusText = "RoomPlan ready"
        print("✅ RoomPlanManager configured with shared ARSession")
        
        // Start RoomPlan immediately so surfaces populate before the user even taps 'Start Capture'.
        // This stops the ARSession from heavily pausing/re-configuring when Start is tapped.
        let config = RoomCaptureSession.Configuration()
        roomSession?.run(configuration: config)
        isScanning = true
    }

    /// Called when the user hits 'Start Capture'. We don't need to do anything heavy here 
    /// anymore because RoomPlan is already running and detecting surfaces.
    func startScan() {
        guard roomSession != nil else { return }
        print("▶️ Recording photos against RoomPlan geometry...")
        statusText = "Scanning room…"
        print(" RoomPlan scan started")
    }

    /// Stops the scan and finalises the CapturedRoom.
    /// - Parameter pauseAR: If false the shared ARSession stays alive for photogrammetry processing.
    func stopScan(pauseAR: Bool = false) {
        guard let session = roomSession, isScanning else { return }
        session.stop(pauseARSession: pauseAR)
        isScanning = false
        print(" RoomPlan scan stopped")
    }

    /// Exports the captured room as a .usdz file to the given directory.
    /// Returns the URL on success, nil otherwise.
    @discardableResult
    func exportRoom(to directory: URL) -> URL? {
        guard let room = capturedRoom else {
            print("⚠️ No captured room to export")
            return nil
        }

        let url = directory.appendingPathComponent("roomplan.usdz")
        let jsonUrl = directory.appendingPathComponent("roomplan.json")

        do {
            try room.export(to: url, exportOptions: .mesh)
            
            // Also save as JSON so we can reload the CapturedRoom object later for offline reprocessing
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(room)
            try jsonData.write(to: jsonUrl)
            
            exportedRoomURL = url
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            print("✅ RoomPlan exported — \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) at \(url.lastPathComponent)")
            return url
        } catch {
            print("❌ RoomPlan export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Builds the live HUD summary from the current CapturedRoom.
    private func updateStatusFromRoom(_ room: CapturedRoom) {
        let wallCount = room.walls.count
        let doorCount = room.doors.count
        let windowCount = room.windows.count
        let objectCount = room.objects.count

        var parts: [String] = []
        if wallCount > 0  { parts.append(" \(wallCount) walls") }
        if doorCount > 0  { parts.append(" \(doorCount) doors") }
        if windowCount > 0 { parts.append(" \(windowCount) windows") }
        if objectCount > 0 { parts.append(" \(objectCount) objects") }

        statusText = parts.isEmpty ? "Scanning room…" : parts.joined(separator: "  ")
    }
}

// MARK: - RoomCaptureSessionDelegate

extension RoomPlanManager: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor in
            self.capturedRoom = room
            self.updateStatusFromRoom(room)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        switch instruction {
        case .moveCloseToWall:
            print(" RoomPlan: Move closer to wall")
        case .moveAwayFromWall:
            print(" RoomPlan: Move away from wall")
        case .slowDown:
            print(" RoomPlan: Slow down")
        case .turnOnLight:
            print(" RoomPlan: Turn on more light")
        case .normal:
            break
        case .lowTexture:
            print(" RoomPlan: Low texture surface detected")
        @unknown default:
            break
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        Task { @MainActor in
            print(" RoomPlan session started with configuration")
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        Task { @MainActor in
            if let error {
                let desc = error.localizedDescription
                print("❌ RoomPlan ended with error: \(desc)")
                statusText = "RoomPlan error: \(desc)"
                // Mark SLAM as failed so metadata.json carries the flag and the Mac
                // knows NOT to use .sequential photogrammetry ordering.
                if desc.localizedCaseInsensitiveContains("tracking") ||
                   desc.localizedCaseInsensitiveContains("slam") ||
                   desc.localizedCaseInsensitiveContains("worldtracking") {
                    slamFailed = true
                    print("⚠️ SLAM failure detected — will write slamFailed=true to metadata")
                }
            } else {
                self.capturedRoomData = data
                // The best-quality CapturedRoom was already set via didUpdate/didChange callbacks
                if let room = self.capturedRoom {
                    self.updateStatusFromRoom(room)
                }
                print(" RoomPlan session ended — final room captured")
                statusText = "Room scan complete ✅"
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        Task { @MainActor in
            self.capturedRoom = room
            self.updateStatusFromRoom(room)
        }
    }
}
