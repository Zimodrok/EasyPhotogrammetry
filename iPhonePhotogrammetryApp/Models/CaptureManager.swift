#if os(iOS)
import Foundation
@preconcurrency import RealityKit
import ARKit
import Combine
import os.log
import CoreImage
import ImageIO
import simd
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Image Processor (Gravity-Based Leveling)
struct ImageProcessor {
    
    /// Snap points for device orientation detection.
    /// Each maps a raw eulerAngles.z region to the correct image orientation
    /// and the "expected" roll for that position.
    struct OrientationResult {
        let imageOrientation: CGImagePropertyOrientation
        let residualRoll: CGFloat   // small tilt to correctz
        let label: String
    }
    
    /// Detects the device orientation from eulerAngles.z and returns:
    /// - The correct `CGImagePropertyOrientation` for the pixel buffer
    /// - The small residual roll to correct (deviation from the nearest 90°)
    static func detectOrientation(rollRadians: Float) -> OrientationResult {
        let roll = CGFloat(rollRadians)
        
        // Snap to nearest 90° increment
        let snaps: [(CGFloat, CGImagePropertyOrientation, String)] = [
            (0,             .right,  "portrait"),        // phone upright
            (-.pi / 2,      .up,     "landscape-right"), // phone rotated CW
            (.pi / 2,       .down,   "landscape-left"),  // phone rotated CCW
            (.pi,           .left,   "upside-down"),     // phone inverted
            (-.pi,          .left,   "upside-down"),     // same, negative side
        ]
        
        // Find the closest snap point
        var bestSnap = snaps[0]
        var bestDist = CGFloat.greatestFiniteMagnitude
        for snap in snaps {
            let dist = abs(roll - snap.0)
            if dist < bestDist {
                bestDist = dist
                bestSnap = snap
            }
        }
        
        let residual = roll - bestSnap.0
        return OrientationResult(
            imageOrientation: bestSnap.1,
            residualRoll: residual,
            label: bestSnap.2
        )
    }
    
    /// Counter-rotates the image by the residual roll angle and crops to remove
    /// black corners. Only corrects the small tilt, not the full 90° orientation.
    static func levelAndCrop(_ image: CIImage, rollAngle: CGFloat) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        let centerX = image.extent.midX
        let centerY = image.extent.midY
        
        let angle = -rollAngle  // counter-rotate
        let rotation = CGAffineTransform(translationX: centerX, y: centerY)
            .rotated(by: angle)
            .translatedBy(x: -centerX, y: -centerY)
        
        let rotated = image.transformed(by: rotation)
        
        let absAngle = abs(angle)
        let cosA = cos(absAngle)
        let sinA = sin(absAngle)
        
        var cropW = w * cosA - h * sinA
        var cropH = h * cosA - w * sinA
        
        if cropW <= 0 || cropH <= 0 {
            cropW = w
            cropH = h
        }
        
        let cropRect = CGRect(
            x: rotated.extent.midX - cropW / 2,
            y: rotated.extent.midY - cropH / 2,
            width: cropW,
            height: cropH
        )
        
        return rotated.cropped(to: cropRect)
    }
}

// MARK: - Ring Configuration (scales with object size)
struct RingConfig {
    let sectorsPerRing: [Int]  // [low, mid, top]
    var totalMarkers: Int { sectorsPerRing.reduce(0, +) }
    
    /// Compute marker density from average camera-to-object distance.
    /// Close = small object = more markers, far = big object = fewer.
    static func forDistance(_ dist: Float) -> RingConfig {
        if dist < 0.25 {
            // Very small object (earbuds, ring) — high detail
            return RingConfig(sectorsPerRing: [12, 10, 6])  // 28
        } else if dist < 0.45 {
            // Small object (phone, shoe) — medium detail
            return RingConfig(sectorsPerRing: [8, 6, 4])    // 18
        } else if dist < 0.7 {
            // Medium object (bag, helmet) — moderate
            return RingConfig(sectorsPerRing: [6, 5, 3])    // 14
        } else {
            // Large object (pillow, chair) — sparse
            return RingConfig(sectorsPerRing: [4, 3, 2])    // 9
        }
    }
}

// MARK: - Sector Key (Ring + Sector)
struct SectorKey: Hashable {
    let ring: Int    // 0 = low, 1 = mid, 2 = top
    let sector: Int  // yaw sector index within the ring
}

// MARK: - Orbit Tracker (Object Detection & Coverage)
struct OrbitTracker {
    
    /// 3D positions where raycasts from screen center hit a surface
    private(set) var hitPoints: [SIMD3<Float>] = []
    /// Camera world position at each capture
    private(set) var cameraPositions: [SIMD3<Float>] = []
    /// Directly captured (ring, sector) pairs
    private(set) var filledSectors: Set<SectorKey> = []
    /// Adjacent to captured — partially covered
    private(set) var partiallyCoveredSectors: Set<SectorKey> = []
    
    /// Average of all raycast hit points — the detected object center
    var orbitCenter: SIMD3<Float>? {
        guard !hitPoints.isEmpty else { return nil }
        let sum = hitPoints.reduce(SIMD3<Float>(0, 0, 0), +)
        return sum / Float(hitPoints.count)
    }
    
    /// Active ring configuration (set when guide dome is placed)
    private(set) var ringConfig = RingConfig(sectorsPerRing: [8, 6, 4])  // default medium
    
    /// Fraction of all markers covered (0.0 – 1.0), partials at 50%
    var coveragePercentage: Double {
        let total = ringConfig.totalMarkers
        guard total > 0 else { return 0 }
        let full = Double(filledSectors.count)
        let partial = Double(partiallyCoveredSectors.subtracting(filledSectors).count) * 0.5
        return min(1.0, (full + partial) / Double(total))
    }
    
    /// Set the ring configuration (called when guides are placed)
    mutating func setRingConfig(_ config: RingConfig) {
        self.ringConfig = config
    }
    
    /// Perform a raycast from screen center, record hit point and camera position.
    mutating func recordCapture(frame: ARFrame, arSession: ARSession) -> Bool {
        let camPos = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        cameraPositions.append(camPos)
        
        // Raycast — try estimatedPlane then existingPlaneInfinite
        let query1 = frame.raycastQuery(
            from: CGPoint(x: 0.5, y: 0.5),
            allowing: .estimatedPlane,
            alignment: .any
        )
        var results = arSession.raycast(query1)
        
        if results.isEmpty {
            let query2 = frame.raycastQuery(
                from: CGPoint(x: 0.5, y: 0.5),
                allowing: .existingPlaneInfinite,
                alignment: .any
            )
            results = arSession.raycast(query2)
        }
        
        guard let hit = results.first else {
            print("⚠️ Raycast miss — no surface detected at screen center")
            return false
        }
        
        let hitPos = SIMD3<Float>(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )
        hitPoints.append(hitPos)
        
        if let center = orbitCenter {
            let dx = camPos.x - center.x
            let dy = camPos.y - center.y
            let dz = camPos.z - center.z
            
            // Yaw sector — FIXED: no +π offset so green appears on camera side
            let yawAngle = atan2(dz, dx)  // -π to π
            
            // Elevation ring from pitch angle
            let horizontalDist = sqrt(dx * dx + dz * dz)
            let elevDeg = atan2(dy, horizontalDist) * 180 / .pi
            
            let ring: Int
            if elevDeg < 25 {
                ring = 0  // low
            } else if elevDeg < 55 {
                ring = 1  // mid
            } else {
                ring = 2  // top
            }
            
            let sectorCount = ringConfig.sectorsPerRing[ring]
            var sectorF = yawAngle / (2 * .pi) * Float(sectorCount)
            if sectorF < 0 { sectorF += Float(sectorCount) }
            let sector = Int(sectorF) % sectorCount
            
            let key = SectorKey(ring: ring, sector: sector)
            filledSectors.insert(key)
            
            // Adjacent sectors as partially covered
            let prev = SectorKey(ring: ring, sector: (sector - 1 + sectorCount) % sectorCount)
            let next = SectorKey(ring: ring, sector: (sector + 1) % sectorCount)
            partiallyCoveredSectors.insert(prev)
            partiallyCoveredSectors.insert(next)
            
            let ringNames = ["low", "mid", "top"]
            print(" ring: \(ringNames[ring]) sector: \(sector) elev: \(String(format: "%.0f", elevDeg))°")
            print(" Coverage: \(Int(coveragePercentage * 100))% (\(filledSectors.count) full + \(partiallyCoveredSectors.subtracting(filledSectors).count) partial / \(ringConfig.totalMarkers))")
        } else {
            print(" First hit — establishing orbit center")
        }
        
        return true
    }
    
    /// Returns the sector key if the camera is currently in a sector that hasn't been captured yet.
    func getNewSector(camPos: SIMD3<Float>, center: SIMD3<Float>) -> SectorKey? {
        let dx = camPos.x - center.x
        let dy = camPos.y - center.y
        let dz = camPos.z - center.z
        
        let yawAngle = atan2(dz, dx)
        let horizontalDist = sqrt(dx * dx + dz * dz)
        let elevDeg = atan2(dy, horizontalDist) * 180 / .pi
        
        let ring: Int
        if elevDeg < 25 { ring = 0 }
        else if elevDeg < 55 { ring = 1 }
        else { ring = 2 }
        
        let sectorCount = ringConfig.sectorsPerRing[ring]
        var sectorF = yawAngle / (2 * .pi) * Float(sectorCount)
        if sectorF < 0 { sectorF += Float(sectorCount) }
        let sector = Int(sectorF) % sectorCount
        
        let key = SectorKey(ring: ring, sector: sector)
        return filledSectors.contains(key) ? nil : key
    }
    
    mutating func reset() {
        hitPoints.removeAll()
        cameraPositions.removeAll()
        filledSectors.removeAll()
        partiallyCoveredSectors.removeAll()
    }
}

// MARK: - Simple Data Models
struct CaptureConfiguration: Sendable {
    let minImageCount: Int = 6
    let maxImageCount: Int = 50
    
    static let `default` = CaptureConfiguration()
}

struct CaptureStatistics: Sendable {
    var imagesCaptured: Int = 0
    var coveragePercentage: Double = 0.0
}

@MainActor
enum CaptureState: Equatable {
    case idle
    case capturing
    case bakingGeometry
    case processingOnMac
    case processing(progress: Double)
    case completed(URL)
    case failed(String)
    
    nonisolated static func == (lhs: CaptureState, rhs: CaptureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.capturing, .capturing): return true
        case (.bakingGeometry, .bakingGeometry): return true
        case (.processingOnMac, .processingOnMac): return true
        case (.processing(let l), .processing(let r)): return l == r
        case (.completed(let l), .completed(let r)): return l == r
        case (.failed(let l), .failed(let r)): return l == r
        default: return false
        }
    }
}

// MARK: - Capture Manager (Using ARKit Camera)
@MainActor
final class CaptureManager: NSObject, ObservableObject {
    @Published var state: CaptureState = .idle
    @Published var statistics = CaptureStatistics()
    @Published var isAutoCaptureEnabled: Bool = false
    @Published var selectedQuality: ModelQuality = .reduced
    
    private var cancellables = Set<AnyCancellable>()
    private var lastAutoCaptureTime: TimeInterval = 0
    private var lastAutoCapturePosition: SIMD3<Float>? = nil
    private var lastAutoCaptureForward: SIMD3<Float>? = nil
    private var lastLiDARExportCenter: SIMD3<Float>? = nil

    // Atomic gate — not actor-isolated so it can be used from the ARKit
    // background delivery thread without any MainActor hop.
    private let _frameGate = FrameGate()
    
    /// Tracks the object the user is orbiting and angular coverage
    private(set) var orbitTracker = OrbitTracker()
    
    /// AR guidance markers showing capture sectors
    private let guidanceOverlay = GuidanceOverlay()
    private let roomGuidanceOverlay = RoomGuidanceOverlay()

    /// The ARView to render guidance markers into
    private var arView: ARView?
    
    /// Derived ARSession from the ARView
    private var arSession: ARSession? { arView?.session }
    
    private let logger = Logger(subsystem: "com.visionscan3d", category: "CaptureManager")
    // Configuration
    let imagesDirectory: URL
    let sessionID = UUID().uuidString
    let configuration: CaptureConfiguration = .default
    var isRoomMode: Bool = false {
        didSet {
            guard oldValue != isRoomMode, let view = arView else { return }
            print(" Switching mode: isRoomMode = \(isRoomMode)")
            if isRoomMode {
                let rpm = RoomPlanManager()
                rpm.configure(with: view.session)
                self.roomPlanManager = rpm
                roomGuidanceOverlay.attach(to: view)
                
                rpm.$capturedRoom
                    .compactMap { $0 }
                    .sink { [weak self] room in
                        self?.roomGuidanceOverlay.update(with: room)
                    }
                    .store(in: &cancellables)
            } else {
                roomGuidanceOverlay.detach()
                roomPlanManager = nil
                cancellables.removeAll()
            }
        }
    }
    
    @Published private(set) var capturedImageURLs: [URL] = []
    /// URLs of photos that failed quality checks (blur, exposure, no raycast)
    @Published private(set) var badImageURLs: Set<URL> = []
    
    private(set) var depthStore: DepthDataStore!
    
    /// RoomPlan manager — runs silently in parallel during Room Mode scans
    @Published private(set) var roomPlanManager: RoomPlanManager?
    
    /// URL of the exported RoomPlan model (set after stopCapture in Room Mode)
    @Published var roomPlanURL: URL?
    
    override init() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.imagesDirectory = docDir.appendingPathComponent("VisionScan_\(sessionID)")
        
        super.init()
        
        // Initialize depth data store (directories are created in startCapture)
        depthStore = DepthDataStore(sessionDirectory: imagesDirectory)
    }
    
    /// Connect to the ARView to access both its session and scene
    func connectToARView(_ view: ARView) {
        self.arView = view
        view.session.delegate = self
        
        // Run a config that enables sceneDepth so frame.sceneDepth is non-nil on LiDAR devices
        let config = ARWorldTrackingConfiguration()
        config.isAutoFocusEnabled = true
        
        // Enable LiDAR depth semantics
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            print("✅ sceneDepth enabled")
        } else {
            print("⚠️ sceneDepth not supported on this device")
        }
        
        // Enable mesh reconstruction for the live overlay
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            print("✅ sceneReconstruction enabled")
        }
        
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        // Force faster shutter speed to eliminate motion blur
        if let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            do {
                try captureDevice.lockForConfiguration()
                // Fast shutter speed (1/60s) to freeze motion
                let targetDuration = CMTime(value: 1, timescale: 60)
                // Boost ISO to compensate for less light
                let maxISO = captureDevice.activeFormat.maxISO
                let targetISO = min(maxISO, 1200)
                
                captureDevice.setExposureModeCustom(duration: targetDuration, iso: targetISO, completionHandler: nil)
                captureDevice.unlockForConfiguration()
                print(" Camera exposure locked: 1/60s at ISO \(targetISO)")
            } catch {
                print("⚠️ Failed to lock camera for exposure configuration: \(error)")
            }
        }
        
        // If in Room Mode, configure RoomPlan on the shared ARSession
        if isRoomMode {
            let rpm = RoomPlanManager()
            rpm.configure(with: view.session)
            self.roomPlanManager = rpm
            roomGuidanceOverlay.attach(to: view)
            print(" RoomPlan configured for Room Mode")
            
            // Listen to RoomPlan updates to feed the guidance overlay
            rpm.$capturedRoom
                .compactMap { $0 }
                .sink { [weak self] room in
                    self?.roomGuidanceOverlay.update(with: room)
                }
                .store(in: &cancellables)
        }
    }
    
    func startCapture() {
        guard state == .idle else { return }
        
        do {
            try FileManager.default.createDirectory(
                at: imagesDirectory,
                withIntermediateDirectories: true
            )
            print(" Saving images to: \(imagesDirectory.path)")
            depthStore.createDirectory()
        } catch {
            logger.error("Failed to create directory: \(error.localizedDescription)")
        }
        
        state = .capturing
        statistics = CaptureStatistics()
        logger.info("Started capture session")
        
        // Start RoomPlan scan if available
        roomPlanManager?.startScan()
    }
    
    func capturePhoto() {
        guard state == .capturing,
              let frame = arSession?.currentFrame,
              let session = arSession else { return }
            
        let pixelBuffer = frame.capturedImage
        let euler = frame.camera.eulerAngles
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileURL = imagesDirectory.appendingPathComponent("image_\(timestamp).heic")
        
        // Capture depth data from LiDAR
        let depthData = frame.sceneDepth?.depthMap
        let confidenceMap = frame.sceneDepth?.confidenceMap
        let cameraIntrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        let imageResolution = frame.camera.imageResolution
        
        // Detect device orientation and compute residual tilt
        let orient = ImageProcessor.detectOrientation(rollRadians: euler.z)
        
        let hasDepth = depthData != nil
        print(" Euler — pitch: \(String(format: "%.1f", euler.x * 180 / .pi))° yaw: \(String(format: "%.1f", euler.y * 180 / .pi))° roll: \(String(format: "%.1f", euler.z * 180 / .pi))° → \(orient.label) depth: \(hasDepth ? "YES" : "NO")")
        
        // Track orbit: raycast to find object, compute coverage
        let raycastHit = orbitTracker.recordCapture(frame: frame, arSession: session)
        statistics.coveragePercentage = orbitTracker.coveragePercentage
        
        // Place or update AR guidance markers
        updateGuidanceMarkers()
        
        Task {
            do {
                // Quality check on the raw image
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let quality = ImageQualityChecker.check(ciImage)
                let isBad = !quality.isAcceptable || !raycastHit
                
                if isBad {
                    let reasons = quality.issues + (raycastHit ? [] : ["No surface detected"])
                    print("⚠️ Quality issue: \(reasons.joined(separator: ", "))")
                } else {
                    print("✅ Quality OK — blur: \(String(format: "%.0f", quality.blurScore)) brightness: \(String(format: "%.2f", quality.brightness))")
                }
                
                try await saveFrameWithDepth(
                    pixelBuffer: pixelBuffer,
                    depthMap: depthData,
                    confidenceMap: confidenceMap,
                    intrinsics: cameraIntrinsics,
                    cameraTransform: cameraTransform,
                    imageResolution: imageResolution,
                    orientation: orient.imageOrientation,
                    to: fileURL
                )
                
                // Save depth sidecar files for persistent LiDAR data
                self.depthStore.saveFrame(
                    imageFilename: fileURL.lastPathComponent,
                    depthMap: depthData,
                    confidenceMap: confidenceMap,
                    intrinsics: cameraIntrinsics,
                    cameraTransform: cameraTransform,
                    imageResolution: imageResolution,
                    timestamp: Date().timeIntervalSince1970
                )
                
                await MainActor.run {
                    self.capturedImageURLs.append(fileURL)
                    if isBad {
                        self.badImageURLs.insert(fileURL)
                    }
                    self.statistics.imagesCaptured = self.capturedImageURLs.count
                    print(" Photo \(self.capturedImageURLs.count) saved\(isBad ? " [FLAGGED]" : "") (depth: \(hasDepth ? "embedded+sidecar" : "none"))")
                }
            } catch {
                logger.error("Save failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Places igloo dome on first orbit detection, updates marker colors each capture
    private func updateGuidanceMarkers() {
        guard !isRoomMode else { return }
        
        guard let center = orbitTracker.orbitCenter,
              orbitTracker.hitPoints.count >= 2 else { return }
        
        if !guidanceOverlay.isPlaced, let arView = arView {
            // Compute radius and marker density from camera distance
            let distances = orbitTracker.cameraPositions.map { cam in
                simd_distance(cam, center)
            }
            let avgDist = distances.reduce(0, +) / Float(distances.count)
            let guideRadius = max(0.08, min(0.25, avgDist * 0.35))
            
            // Scale marker count by object size
            let config = RingConfig.forDistance(avgDist)
            orbitTracker.setRingConfig(config)
            
            let anchor = guidanceOverlay.createIglooDome(
                center: center,
                radius: guideRadius,
                config: config
            )
            arView.scene.addAnchor(anchor)
            
            print(" Object distance: \(String(format: "%.2f", avgDist))m → \(config.totalMarkers) markers")
        }
        
        // Update sector marker colors
        guidanceOverlay.updateSectors(
            filledSectors: orbitTracker.filledSectors,
            partiallyCoveredSectors: orbitTracker.partiallyCoveredSectors
        )
    }
    
    /// - Parameter exportOnly: If true, exports all structural data and pauses AR but does NOT
    ///   launch local photogrammetry. Use this when sending to Mac for remote processing.
    func stopCapture(exportOnly: Bool = false) async throws {
        guard case .capturing = state else { return }
        
        let imageCount = self.capturedImageURLs.count
        
        guard imageCount >= configuration.minImageCount else {
            let error = "Need \(configuration.minImageCount)+ images. Got \(imageCount)."
            state = .failed(error)
            throw CaptureError.insufficientImages
        }
        
        // Force an absolute pause/flush sequence
        state = .bakingGeometry
        logger.info("Processing \(imageCount) images: Baking Geometry...")
        
        let dir = imagesDirectory
        let outputURL = dir.appendingPathComponent("model.usdz")
        let lidarURL = dir.appendingPathComponent("lidar.usdz")
        
        // Capture properties on the main thread for the detached Task
        let capturedRoom = roomPlanManager?.capturedRoom
        let currentFrame = arView?.session.currentFrame
        let rpm = roomPlanManager
        
        var dataExported = false
        
        // Await the physical writing of structural assets
        try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            if let rpm = rpm {
                await MainActor.run { rpm.stopScan(pauseAR: false) }
                
                if let capturedRoom = capturedRoom {
                    // Export parametric RoomPlan geometry structure to JSON
                    if let encodedRoom = try? JSONEncoder().encode(capturedRoom) {
                        try? encodedRoom.write(to: dir.appendingPathComponent("roomplan.json"), options: .atomic)
                    }
                    
                    // Export structural RoomPlan 3D skeletal frame to USDZ
                    do {
                        try capturedRoom.export(to: dir.appendingPathComponent("roomplan.usdz"), exportOptions: .mesh)
                        print(" [RoomPlan] Exported roomplan.usdz + roomplan.json")
                        dataExported = true
                    } catch {
                        print("❌ RoomPlan export failed: \(error.localizedDescription)")
                    }
                } else {
                    // Fallback: capturedRoom may be nil (SLAM died mid-scan), but
                    // the last partial room snapshot from the delegate may still be available.
                    print("⚠️ [RoomPlan] capturedRoom is nil — attempting partial data export")
                    let jsonURL = dir.appendingPathComponent("roomplan.json")
                    if let lastRoom = await rpm.capturedRoom,
                       let jsonData = try? JSONEncoder().encode(lastRoom) {
                        try? jsonData.write(to: jsonURL)
                        print(" [RoomPlan] Partial roomplan.json written from last known room snapshot")
                        dataExported = true
                    } else {
                        print("⚠️ [RoomPlan] No room data at all — roomplan.json will be absent.")
                    }
                }
            }
            
            // Ensure targetMesh completely finishes extraction and serialization
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                if let frame = currentFrame {
                    await MainActor.run {
                        self.extractLiDARMsh(from: frame, to: lidarURL)
                    }
                    
                    let lidarSize = (try? FileManager.default.attributesOfItem(atPath: lidarURL.path))?[.size] as? Int ?? 0
                    if lidarSize > 1024 {
                        print(" [LiDAR Mesh] lidar.usdz written (\(ByteCountFormatter.string(fromByteCount: Int64(lidarSize), countStyle: .file)))")
                        dataExported = true
                    } else {
                        try? FileManager.default.removeItem(at: lidarURL)
                        print("⚠️ [LiDAR Mesh] LiDAR mesh was empty (no anchors) — lidar.usdz removed.")
                    }
                }
            }
        }.value
        
        if !dataExported {
            print("ℹ️ [Fallback] No LiDAR/RoomPlan data. Mac will run pure photogrammetry from photos.")
        }

        let slamDidFail = roomPlanManager?.slamFailed ?? false
        depthStore.saveSessionMetadata(
            to: dir,
            imageCount: imageCount,
            lidarExportCenter: lastLiDARExportCenter,
            slamFailed: slamDidFail
        )
        
        // Stop the AR camera
        arView?.session.pause()
        print(" AR session paused for processing")
        
        // If exporting for Mac, stop here — Mac handles processing.
        // The .processing state will show the transfer overlay.
        guard !exportOnly else {
            print(" exportOnly=true: skipping local photogrammetry — Mac will process.")
            return
        }
        
        // Subscribe to results from the nonisolated processing task
        NotificationCenter.default.addObserver(
            forName: .photogrammetryProgress,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let fraction = note.userInfo?["fraction"] as? Double else { return }
            MainActor.assumeIsolated { self.state = .processing(progress: fraction) }
        }
        
        NotificationCenter.default.addObserver(
            forName: .photogrammetryFinished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            NotificationCenter.default.removeObserver(self, name: .photogrammetryProgress, object: nil)
            NotificationCenter.default.removeObserver(self, name: .photogrammetryFinished, object: nil)
            
            let success = note.userInfo?["success"] as? Bool ?? false
            let url = note.userInfo?["url"] as? URL ?? outputURL
            let errorMsg = note.userInfo?["error"] as? String
            
            MainActor.assumeIsolated {
                if success {
                    self.state = .completed(url)
                    print("✅ UI updated to completed")
                } else {
                    self.state = .failed(errorMsg ?? "Reconstruction failed. Take more overlapping photos.")
                }
            }
        }
        
        // Launch processing entirely off @MainActor
        let roomMode = isRoomMode
        let detail = selectedQuality.detail
        Task.detached { [weak self] in
            await self?.processPhotogrammetry(
                imagesDirectory: dir,
                outputURL: outputURL,
                imageCount: imageCount,
                isRoomMode: roomMode,
                detail: detail
            )
        }
    }
    
    // MARK: - Private Helpers
    
    private func extractLiDARMsh(from frame: ARFrame, to url: URL) {
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else {
            print("⚠️ No LiDAR mesh anchors found to export.")
            return
        }
        
        // Define bounding region based on orbit center (or fallback to camera forward)
        let center: SIMD3<Float>
        let radius: Float
        if !isRoomMode, let orbit = orbitTracker.orbitCenter {
            center = orbit
            let distances = orbitTracker.cameraPositions.map { simd_distance($0, orbit) }
            let avgDist = distances.reduce(0, +) / Float(distances.count)
            radius = max(0.15, min(0.5, avgDist * 0.8)) // Crop radius around object
        } else {
            // Room mode: Export everything. Use camera start as a very large placeholder radius.
            let cameraTransform = frame.camera.transform
            let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
            let translation = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            center = translation + (forward * 0.5)
            radius = isRoomMode ? 1000.0 : 0.5 // Massive radius practically uncropped for room
        }
        
        let modeStr = isRoomMode ? "ROOM" : "OBJECT"
        print(" Extracting \(meshAnchors.count) LiDAR chunks (\(modeStr)), cropping to radius \(String(format: "%.2f", radius))m at \(center)...")
        lastLiDARExportCenter = center
        
        let scene = SCNScene()
        
        // Wrap everything so we can recenter the origin to match Photogrammetry models
        let wrapperNode = SCNNode()
        wrapperNode.simdPosition = -center
        scene.rootNode.addChildNode(wrapperNode)
        
        // Material for LiDAR mesh
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.8)
        mat.lightingModel = .physicallyBased
        mat.isDoubleSided = true
        
        var addedAnyGeometry = false
        
        for anchor in meshAnchors {
            let geom = anchor.geometry
            let sourceVertices = geom.vertices
            let sourceFaces = geom.faces
            
            // Raw bytes
            let vertexBuffer = sourceVertices.buffer.contents()
            let faceBuffer = sourceFaces.buffer.contents()
            
            var croppedVertices: [SIMD3<Float>] = []
            var croppedFaces: [Int32] = []
            var vertexMap: [Int: Int32] = [:] // Old index -> New index
            
            let anchorTransform = anchor.transform
            
            // Iterate faces and keep only those that fall within the bounding sphere
            let faceCount = sourceFaces.count
            let bytesPerIndex = sourceFaces.bytesPerIndex
            
            for f in 0..<faceCount {
                // Read 3 indices for this triangle
                let faceOffset = f * 3 * bytesPerIndex
                
                let i0: Int
                let i1: Int
                let i2: Int
                
                if bytesPerIndex == 4 {
                    let ptr = faceBuffer.advanced(by: faceOffset).assumingMemoryBound(to: UInt32.self)
                    i0 = Int(ptr[0])
                    i1 = Int(ptr[1])
                    i2 = Int(ptr[2])
                } else {
                    let ptr = faceBuffer.advanced(by: faceOffset).assumingMemoryBound(to: UInt16.self)
                    i0 = Int(ptr[0])
                    i1 = Int(ptr[1])
                    i2 = Int(ptr[2])
                }
                
                // Read 3 vertices
                func getVertex(index: Int) -> SIMD3<Float> {
                    let ptr = vertexBuffer.advanced(by: index * sourceVertices.stride + sourceVertices.offset).assumingMemoryBound(to: Float.self)
                    return SIMD3<Float>(ptr[0], ptr[1], ptr[2])
                }
                
                let v0Local = getVertex(index: i0)
                let v1Local = getVertex(index: i1)
                let v2Local = getVertex(index: i2)
                
                // Convert to world space to check distance
                let v0World = simd_make_float3(anchorTransform * simd_float4(v0Local, 1))
                let v1World = simd_make_float3(anchorTransform * simd_float4(v1Local, 1))
                let v2World = simd_make_float3(anchorTransform * simd_float4(v2Local, 1))
                
                let d0 = simd_distance(v0World, center)
                let d1 = simd_distance(v1World, center)
                let d2 = simd_distance(v2World, center)
                
                // If the entire triangle is outside the radius, discard it
                if d0 > radius && d1 > radius && d2 > radius { continue }
                
                // Add vertices and remap indices
                for idx in [i0, i1, i2] {
                    if vertexMap[idx] == nil {
                        let newIdx = Int32(croppedVertices.count)
                        vertexMap[idx] = newIdx
                        croppedVertices.append(getVertex(index: idx))
                    }
                    croppedFaces.append(vertexMap[idx]!)
                }
            }
            
            if croppedVertices.isEmpty { continue }
            
            // Build new SCNGeometry from structural arrays
            let vertexData = Data(bytes: croppedVertices, count: croppedVertices.count * MemoryLayout<SIMD3<Float>>.stride)
            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: croppedVertices.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride
            )
            
            let elementsData = Data(bytes: croppedFaces, count: croppedFaces.count * MemoryLayout<Int32>.stride)
            let geometryElement = SCNGeometryElement(
                data: elementsData,
                primitiveType: .triangles,
                primitiveCount: croppedFaces.count / 3,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            
            let scnGeom = SCNGeometry(sources: [vertexSource], elements: [geometryElement])
            scnGeom.materials = [mat]
            
            let node = SCNNode(geometry: scnGeom)
            node.simdTransform = anchor.transform
            wrapperNode.addChildNode(node)
            addedAnyGeometry = true
        }
        
        if !addedAnyGeometry {
            print("⚠️ LiDAR mesh completely empty after cropping to object.")
            // Create a small placeholder box so the user knows where the center was
            let box = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0)
            box.materials = [mat]
            let node = SCNNode(geometry: box)
            node.simdPosition = center
            wrapperNode.addChildNode(node)
        }
        
        let success = scene.write(
            to: url,
            options: nil,
            delegate: nil,
            progressHandler: nil
        )
        if success {
            print(" Successfully exported CROPPED LiDAR mesh to: \(url.lastPathComponent)")
        } else {
            print("❌ Failed to export LiDAR mesh")
        }
    }
    
    
    /// Saves the camera frame as HEIC with embedded depth data for PhotogrammetrySession.
    private func saveFrameWithDepth(
        pixelBuffer: CVPixelBuffer,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        imageResolution: CGSize,
        orientation: CGImagePropertyOrientation
        to url: URL
    ) async throws {
        // Create CGImage from pixel buffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureError.imageRenderFailed
        }
        
        // Write as HEIC with depth auxiliary data
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            AVFileType.heic.rawValue as CFString,
            1,
            nil
        ) else {
            throw CaptureError.imageRenderFailed
        }
        
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue
        ]
        
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        
        // Add depth data if available from LiDAR
        if let depthMap = depthMap {
            // Lock the depth pixel buffer to read raw bytes
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            
            let depthWidth = CVPixelBufferGetWidth(depthMap)
            let depthHeight = CVPixelBufferGetHeight(depthMap)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
            
            if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                let depthData = Data(bytes: baseAddress, count: bytesPerRow * depthHeight)
                
                // Build the auxiliary data dictionary with CoreGraphics keys
                let description: [String: Any] = [
                    kCGImagePropertyPixelFormat as String: kCVPixelFormatType_DepthFloat32,
                    kCGImagePropertyWidth as String: depthWidth,
                    kCGImagePropertyHeight as String: depthHeight,
                    kCGImagePropertyBytesPerRow as String: bytesPerRow,
                ]
                
                let auxDict: [String: Any] = [
                    kCGImageAuxiliaryDataInfoData as String: depthData as CFData,
                    kCGImageAuxiliaryDataInfoDataDescription as String: description as CFDictionary,
                ]
                
                CGImageDestinationAddAuxiliaryDataInfo(
                    dest,
                    kCGImageAuxiliaryDataTypeDepth,
                    auxDict as CFDictionary
                )
                print(" Depth map embedded: \(depthWidth)x\(depthHeight)")
            }
        }
        
        
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.imageRenderFailed
        }
    }
    
    /// Fallback: saves without depth (for gallery-imported images)
    private func savePixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        residualRoll: CGFloat,
        to url: URL
    ) async throws {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(orientation)

        // Only correct the small residual tilt
        if abs(residualRoll) > 0.01 {
            ciImage = ImageProcessor.levelAndCrop(ciImage, rollAngle: residualRoll)
        }

        let context = CIContext()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try context.writeJPEGRepresentation(
            of: ciImage,
            to: url,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        )
    }
    
    // MARK: - Photogrammetry (runs off main actor to avoid deadlock)
    
    nonisolated private func processPhotogrammetry(
        imagesDirectory: URL,
        outputURL: URL,
        imageCount: Int,
        isRoomMode: Bool = false,
        detail: RealityKit.PhotogrammetrySession.Request.Detail
    ) async {
        let fileManager = FileManager.default
        var finalURL = outputURL
        let lidarURL = imagesDirectory.appendingPathComponent("lidar.usdz")
        var hasValidLidar = false
        
        do {
            if fileManager.fileExists(atPath: lidarURL.path),
               let attrs = try? fileManager.attributesOfItem(atPath: lidarURL.path),
               let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                hasValidLidar = true
            }
            
            var sessionConfig = RealityKit.PhotogrammetrySession.Configuration()
            
            if hasValidLidar {
                print(" Pipeline: LiDAR mesh discovered. Running hybrid sequential tracking.")
                sessionConfig.sampleOrdering = .sequential
                sessionConfig.featureSensitivity = .high
            } else {
                print("ℹ️ Pipeline: No valid LiDAR track. Forcing clean RGB .unordered photo-mode.")
                sessionConfig.sampleOrdering = .unordered
                sessionConfig.featureSensitivity = .high
                if #available(iOS 17.0, macOS 14.0, *) {
                    sessionConfig.isObjectMaskingEnabled = false
                }
            }

            if isRoomMode {
                // Room mode: sequential ordering, ALL photos, no limits
                print(" Room Mode: processing ALL \(imageCount) images")
                let room = RoomPhotogrammetry()
                
                let quality = await MainActor.run { self.selectedQuality }
                try await room.process(
                    imagesDirectory: imagesDirectory,
                    outputURL: outputURL,
                    detail: quality.detail,
                    onProgress: { @Sendable fraction in
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: .photogrammetryProgress,
                                object: nil,
                                userInfo: ["fraction": fraction]
                            )
                        }
                    }
                )
            } else {
                // Object mode: single session
                let parentDir = imagesDirectory.deletingLastPathComponent()
                let quarantineURL = parentDir.appendingPathComponent(imagesDirectory.lastPathComponent + "_quarantine")
                
                if fileManager.fileExists(atPath: quarantineURL.path) {
                    try? fileManager.removeItem(at: quarantineURL)
                }
                try fileManager.createDirectory(at: quarantineURL, withIntermediateDirectories: true, attributes: nil)
                
                defer { try? fileManager.removeItem(at: quarantineURL) }
                
        let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
                let items = try fileManager.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)
                for item in items {
                    let ext = item.pathExtension.lowercased()
                    if imageExts.contains(ext) {
                        let dest = quarantineURL.appendingPathComponent(item.lastPathComponent)
                        try fileManager.copyItem(at: item, to: dest)
                    }
                }
                
                let session = try RealityKit.PhotogrammetrySession(
                    input: quarantineURL,
                    configuration: sessionConfig
                )
                
                let request = RealityKit.PhotogrammetrySession.Request.modelFile(
                    url: outputURL,
                    detail: detail
                )
                
                var requests: [RealityKit.PhotogrammetrySession.Request] = [request]
                if #available(iOS 17.0, macOS 14.0, *) {
                    requests.append(.poses)
                }
                
                print(" Starting photogrammetry engine for \(imageCount) frames...")
                try session.process(requests: requests)
                
                outputLoop: for try await output in session.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .photogrammetryProgress,
                                object: nil,
                                userInfo: ["fraction": fraction]
                            )
                        }
                    case .requestComplete(_, let result):
                        if case .modelFile(let url) = result {
                            print("✅ requestComplete: \(url.lastPathComponent)")
                        } else if case .poses(let posesObject) = result {
                            var collected: [String: [Float]] = [:]
                            let posesMap = posesObject.posesBySample
                            print(" Extracted \(posesMap.count) camera poses during fresh scan.")
                            for (id, pose) in posesMap {
                                let m = pose.transform.matrix
                                collected["\(id)"] = [
                                    m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                                    m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                                    m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                                    m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
                                ]
                            }
                            let posesURL = imagesDirectory.appendingPathComponent("pg_poses.json")
                            if let data = try? JSONSerialization.data(withJSONObject: collected) {
                                try? data.write(to: posesURL, options: .atomic)
                                print(" Saved stable pg_poses.json to \(posesURL.lastPathComponent)")
                            }
                        }
                    case .requestError(_, let error):
                        print("⚠️ Photogrammetry warning: \(error.localizedDescription)")
                    case .processingComplete:
                        print(" processingComplete — exiting output loop")
                        break outputLoop
                    default:
                        break
                    }
                }
            }
            
            let fileExists = fileManager.fileExists(atPath: outputURL.path)
            
            // Mesh Refinement step (Step 2)
            var finalModelURL = outputURL
            let refinedURL = imagesDirectory.appendingPathComponent("model_refined.usdz")
            let runRefiner = true
            
            if runRefiner && fileExists, let store = await MainActor.run(resultType: DepthDataStore?.self, body: { [weak self] in self?.depthStore }), hasValidLidar {
                print(" Starting mesh refinement using phone LiDAR buffer...")
                var refinerConfig = MeshRefiner.Config()
                refinerConfig.snapRadius = 0.02
                let refiner = MeshRefiner(config: refinerConfig)
                do {
                    try refiner.refine(modelURL: outputURL, depthStore: store, outputURL: refinedURL)
                    if fileManager.fileExists(atPath: refinedURL.path) {
                        finalModelURL = refinedURL
                        print("✅ Using refined mesh: \(refinedURL.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ Mesh refinement failed (using original): \(error.localizedDescription)")
                }
            }
            
            if isRoomMode {
                let roomplanJSON = imagesDirectory.appendingPathComponent("roomplan.json")
                if fileManager.fileExists(atPath: roomplanJSON.path) {
                    do {
                        let jsonData = try Data(contentsOf: roomplanJSON)
                        let archivedRoom = try JSONDecoder().decode(ArchivedRoom.self, from: jsonData)
                        print(" Loaded RoomPlan geometry from roomplan.json")
                        
                        let texturedURL = imagesDirectory.appendingPathComponent("room_textured.usdz")
                        let projector = MacRoomTextureProjector()
                        
                        print(" Room Mode — generating textured room from RoomPlan via MacRoomTextureProjector...")
                        let result = try await projector.projectTextures(
                            room: archivedRoom,
                            sessionDirectory: imagesDirectory,
                            outputURL: texturedURL
                        )
                        print("✅ Textured room: \(result.texturedSurfaceCount)/\(result.totalSurfaceCount) surfaces")
                        
                        let lidarURL = imagesDirectory.appendingPathComponent("lidar.usdz")
                        let scaffoldURL = imagesDirectory.appendingPathComponent("room_lidar_merged.usdz")
                        var scaffoldURLToUse = texturedURL
                        
                        if fileManager.fileExists(atPath: lidarURL.path) {
                            print("Merging room with LiDAR scaffold...")
                            do {
                                try MacCaptureManagerHelpers.mergeRoomWithLiDAR(
                                    room: archivedRoom,
                                    roomSceneURL: texturedURL,
                                    lidarURL: lidarURL,
                                    sessionDirectory: imagesDirectory,
                                    outputURL: scaffoldURL
                                )
                                if fileManager.fileExists(atPath: scaffoldURL.path) {
                                    scaffoldURLToUse = scaffoldURL
                                    print("✅ Built RoomScan + LiDAR scaffold.")
                                }
                            } catch {
                                print("⚠️ LiDAR merge failed: \(error.localizedDescription)")
                            }
                        }
                        
                        if fileExists {
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .photogrammetryProgress,
                                    object: nil,
                                    userInfo: ["fraction": 0.96]
                                )
                            }
                            
                            let mergedURL = imagesDirectory.appendingPathComponent("room_merged.usdz")
                            print(" Merging photogrammetry mesh into textured room using Mac SVD poses registration and spatial snapper...")
                            let lidarForMerge = fileManager.fileExists(atPath: lidarURL.path) ? lidarURL : scaffoldURLToUse
                            do {
                                try MacCaptureManagerHelpers.mergeRoomWithPhotogrammetry(
                                    room: archivedRoom,
                                    roomSceneURL: scaffoldURLToUse,
                                    photogrammetryURL: finalModelURL,
                                    lidarURL: lidarForMerge,
                                    sessionDirectory: imagesDirectory,
                                    outputURL: mergedURL
                                )
                                if fileManager.fileExists(atPath: mergedURL.path) {
                                    finalURL = mergedURL
                                    print("✅ Merged room+photogrammetry → \(mergedURL.lastPathComponent)")
                                } else {
                                    finalURL = scaffoldURLToUse
                                }
                            } catch let mergeError {
                                finalURL = scaffoldURLToUse
                                print("⚠️ Merge failed, using textured room only: \(mergeError.localizedDescription)")
                            }
                        } else {
                            print("ℹ️ Photogrammetry model missing. Fallback to pure textured RoomPlan model.")
                            finalURL = scaffoldURLToUse
                        }
                    } catch let parseError {
                        print("❌ Failed to parse or process room: \(parseError.localizedDescription)")
                        finalURL = fileExists ? finalModelURL : imagesDirectory.appendingPathComponent("room_textured.usdz")
                    }
                } else {
                    print("⚠️ roomplan.json not found in session folder")
                    finalURL = fileExists ? finalModelURL : imagesDirectory.appendingPathComponent("room_textured.usdz")
                }
            } else {
                finalURL = finalModelURL
            }
            
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .photogrammetryFinished,
                    object: nil,
                    userInfo: ["url": finalURL, "success": fileManager.fileExists(atPath: finalURL.path)]
                )
            }
            
        } catch {
            print("❌ Photogrammetry failed: \(error)")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .photogrammetryFinished,
                    object: nil,
                    userInfo: ["url": URL(fileURLWithPath: "/"), "success": false, "error": error.localizedDescription]
                )
            }
        }
    }
    
    func reset() {
        state = .idle
        statistics = CaptureStatistics()
        capturedImageURLs.removeAll()
        orbitTracker.reset()
        guidanceOverlay.removeGuidance()
        roomPlanManager = nil
        
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? FileManager.default.createDirectory(
            at: imagesDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Room + Photogrammetry Merge
        nonisolated static func mergeRoomWithPhotogrammetry(
        roomURL: URL,
        photogrammetryURL: URL,
        outputURL: URL
    ) throws {
        // Load both scenes
        let roomScene = try SCNScene(url: roomURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])
        let pgScene = try SCNScene(url: photogrammetryURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])
        
        // Compute bounding boxes to align models
        let roomBB = roomScene.rootNode.boundingBox
        let pgBB = pgScene.rootNode.boundingBox
        
        let roomCenter = SCNVector3(
            (roomBB.min.x + roomBB.max.x) / 2,
            (roomBB.min.y + roomBB.max.y) / 2,
            (roomBB.min.z + roomBB.max.z) / 2
        )
        let pgCenter = SCNVector3(
            (pgBB.min.x + pgBB.max.x) / 2,
            (pgBB.min.y + pgBB.max.y) / 2,
            (pgBB.min.z + pgBB.max.z) / 2
        )
        
        print(" RoomPlan center: (\(roomCenter.x), \(roomCenter.y), \(roomCenter.z))")
        print(" Photogrammetry center: (\(pgCenter.x), \(pgCenter.y), \(pgCenter.z))")
        
        // Wrap the photogrammetry mesh in alignment nodes
        let pgWrapper = SCNNode()
        pgWrapper.name = "photogrammetry_fill"
        
        // Step 1: Move photogrammetry model so its center is at origin
        let centeringNode = SCNNode()
        centeringNode.position = SCNVector3(-pgCenter.x, -pgCenter.y, -pgCenter.z)
        
        for child in pgScene.rootNode.childNodes {
            let clone = child.clone()
            
            // Make photogrammetry slightly transparent where it overlaps with RoomPlan
            clone.enumerateChildNodes { node, _ in
                node.geometry?.materials.forEach { mat in
                    mat.transparency = 0.85
                    mat.isDoubleSided = true
                }
            }
            // Also make the top-level clone's own geometry transparent
            clone.geometry?.materials.forEach { mat in
                mat.transparency = 0.85
                mat.isDoubleSided = true
            }
            centeringNode.addChildNode(clone)
        }
        
        // Step 2: Apply 180° rotation around Z-axis to fix upside-down + mirrored
        // (This flips both X and Y, which corrects "upside down and mirrored left-to-right")
        let rotationNode = SCNNode()
        rotationNode.eulerAngles = SCNVector3(0, 0, Float.pi) // 180° around Z
        rotationNode.addChildNode(centeringNode)
        
        // Step 3: Move to RoomPlan center
        pgWrapper.position = roomCenter
        pgWrapper.addChildNode(rotationNode)
        
        roomScene.rootNode.addChildNode(pgWrapper)
        
        // Export merged scene
        autoreleasepool {
            let success = roomScene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
            if !success {
                print("⚠️ Failed to write merged scene")
            }
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? Int ?? 0
        print(" Merged scene: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
    }
}

// MARK: - ARSessionDelegate
extension CaptureManager: ARSessionDelegate {

    // MARK: Session failure + hard hardware recovery
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let desc = error.localizedDescription
        print("❌ ARSession failed: \(desc)")
        
        // Attempt hardware-level reset to flush dirty Metal/IOSurface buffers.
        // This handles "World tracking failure" without requiring the user to
        // restart the whole app.
        let nsError = error as NSError
        let isTrackingFailure = nsError.domain == "com.apple.arkit.error" ||
                                desc.localizedCaseInsensitiveContains("tracking") ||
                                desc.localizedCaseInsensitiveContains("slam")
        
        if isTrackingFailure {
            print("⚠️ Tracking failure detected — attempting hard session reset")
            let config = ARWorldTrackingConfiguration()
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
            // Run with full reset: flushes all hardware buffers, clears anchors,
            // reinitialises the SLAM map from scratch.
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            print(" ARSession hard reset complete — SLAM restarting")
            // Don't set state = .failed; let the session recover silently.
        } else {
            Task { @MainActor in
                self.logger.error("AR Session failed: \(desc)")
                self.state = .failed(desc)
            }
        }
    }

    // MARK: Frame delivery — zero-retain guarantee via atomic gate
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Gate check (non-blocking, O(1))
        // If a previous frame is still being processed we drop this one
        // immediately, releasing it back to ARKit before this function returns.
        // This guarantees ARKit never accumulates more than 1 retained frame
        // in our delegate, preventing the "retaining N ARFrames" black-screen bug.
        guard _frameGate.tryClaim() else { return }
        
        // Extract ALL needed values synchronously, right now
        // We must read everything from `frame` before we spawn any async work,
        // because once this function returns ARKit may reuse the frame buffer.
        let trackingState   = frame.camera.trackingState
        let camTransform    = frame.camera.transform
        let camPos          = SIMD3<Float>(camTransform.columns.3.x,
                                          camTransform.columns.3.y,
                                          camTransform.columns.3.z)
        let camForward      = SIMD3<Float>(-camTransform.columns.2.x,
                                          -camTransform.columns.2.y,
                                          -camTransform.columns.2.z)
        let now             = Date().timeIntervalSince1970
        
        // Frame is fully read — release the gate reference. ARKit can reclaim
        // the buffer as soon as this function returns (which happens right after
        // the Task below is enqueued, not when it completes).
        // Note: we still hold _frameGateOccupied = true until the Task finishes
        // to rate-limit how often we enter MainActor work.
        
        // Dispatch lightweight decision to MainActor
        Task { @MainActor [weak self] in
            defer { self?._frameGate.release() }
            guard let self else { return }
            guard case .capturing = self.state else { return }

            // Room guidance: only needs the transform (already copied above)
            if self.isRoomMode {
                self.roomGuidanceOverlay.paintFromCamera(cameraTransform: camTransform)
            }

            // Auto-capture gating
            guard self.isAutoCaptureEnabled else { return }
            guard now - self.lastAutoCaptureTime > 0.4 else { return }

            // Only capture when tracking is fully normal
            guard case .normal = trackingState else { return }

            var shouldCapture = false
            if self.isRoomMode {
                if let lastPos = self.lastAutoCapturePosition,
                   let lastFwd = self.lastAutoCaptureForward {
                    let move  = simd_distance(camPos, lastPos)
                    let dot   = simd_dot(normalize(camForward), normalize(lastFwd))
                    let angle = acos(min(1.0, max(-1.0, dot))) * (180.0 / .pi)
                    if move > 0.08 || angle > 8.0 { shouldCapture = true }
                } else {
                    shouldCapture = true
                }
            } else {
                if let center = self.orbitTracker.orbitCenter,
                   self.orbitTracker.getNewSector(camPos: camPos, center: center) != nil {
                    shouldCapture = true
                }
            }

            if shouldCapture {
                self.lastAutoCaptureTime        = now
                self.lastAutoCapturePosition    = camPos
                self.lastAutoCaptureForward      = camForward
                print(" Auto-Capture (tracking: normal)")
                self.capturePhoto()
            }
        }
        // Function returns here ── ARKit can reclaim the frame buffer
    }
}

// MARK: - Errors
enum CaptureError: LocalizedError {
    case insufficientImages
    case imageRenderFailed
    
    var errorDescription: String? {
        switch self {
        case .insufficientImages:
            return "Not enough images"
        case .imageRenderFailed:
            return "Failed to render and save image"
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let photogrammetryProgress = Notification.Name("photogrammetryProgress")
    static let photogrammetryFinished = Notification.Name("photogrammetryFinished")
}

// MARK: - FrameGate
/// Thread-safe non-blocking gate for ARFrame processing.
/// Not actor-isolated so it can be called directly from any thread
/// (including ARKit's background delivery thread) without an await hop.
final class FrameGate: @unchecked Sendable {
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>
    private var occupied: Bool = false

    init() {
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    deinit { lockPtr.deallocate() }

    /// Non-blocking. Returns true if this call claimed the gate (caller must call release()).
    func tryClaim() -> Bool {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        if occupied { return false }
        occupied = true
        return true
    }

    func release() {
        os_unfair_lock_lock(lockPtr)
        occupied = false
        os_unfair_lock_unlock(lockPtr)
    }
}

#endif
