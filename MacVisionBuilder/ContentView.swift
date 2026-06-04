import SwiftUI
import RealityKit
@preconcurrency import SceneKit
import Combine
import UniformTypeIdentifiers

struct LogMessage: Identifiable {
    let id = UUID()
    let text: String
}

struct ContentView: View {
    @StateObject private var engine = TransferEngine()
    @State private var cancellables = Set<AnyCancellable>()
    
    @State private var logMessages: [LogMessage] = []
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var activeProcessingTask: Task<Void, Never>? = nil
    
    @State private var runPhotogrammetry = true
    @State private var runRefiner = true
    @State private var runProjector = true
    
    @State private var detailLevel: PhotogrammetrySession.Request.Detail = .raw
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Mac Vision Builder")
                .font(.largeTitle.bold())
            
            HStack(spacing: 40) {
                VStack(spacing: 12) {
                    Text("Live iPhone Transfer").font(.headline)
                    statusView
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                
                VStack(spacing: 12) {
                    Text("Offline Folder Processing").font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Run Photogrammetry", isOn: $runPhotogrammetry)
                        if runPhotogrammetry {
                            Picker("Detail:", selection: $detailLevel) {
                                Text("Raw").tag(PhotogrammetrySession.Request.Detail.raw)
                                Text("Reduced").tag(PhotogrammetrySession.Request.Detail.reduced)
                                Text("Medium").tag(PhotogrammetrySession.Request.Detail.medium)
                                Text("Full").tag(PhotogrammetrySession.Request.Detail.full)
                            }
                            .labelsHidden()
                        }
                        Toggle("Run Mesh Refiner", isOn: $runRefiner)
                        Toggle("Run Texture Projector & Merger", isOn: $runProjector)
                    }
                    .font(.caption)
                    
                    Button("Select Folder & Process...") {
                        selectAndProcessFolder()
                    }
                    .disabled(isProcessing)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            }
            
            if isProcessing {
                ProgressView(value: progress) {
                    Text("Processing: \(Int(progress * 100))%")
                }
            }
            
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(logMessages) { msg in
                        Text(msg.text).font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .frame(height: 200)
            
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            setupEngine()
        }
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch engine.state {
        case .idle:
            ProgressView()
            Text("Initializing Network...")
                .foregroundStyle(.secondary)
        case .advertising:
            ProgressView()
            Text("Server Listening! Waiting for iPhone...")
                .foregroundStyle(.blue)
        case .searching:
            ProgressView()
            Text("Searching for peers...")
        case .connected(let peer):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Connected to \(peer)")
        case .transferring(let p, let detail):
            ProgressView(value: p)
            Text(detail).font(.caption)
        case .processingOnMac:
            ProgressView()
            Text("Processing scans...")
                .foregroundStyle(.purple)
        case .success:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
            Text("Transfer Completed")
        case .failed(let err):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text("Error: \(err)")
        }
    }
    
    private func log(_ msg: String) {
        DispatchQueue.main.async {
            self.logMessages.append(LogMessage(text: msg))
            if self.logMessages.count > 100 { self.logMessages.removeFirst() }
        }
    }
    
    private func setupEngine() {
        log("Starting Bonjour Server...")
        engine.startMacServer()
        
        engine.$state.sink { state in
            switch state {
            case .advertising: log("✅ Server bound to port. Broadcasting _macvision._tcp...")
            case .failed(let err): log("❌ Network Error: \(err)")
            case .connected(let p): log(" Connected to \(p)!")
            default: break
            }
        }.store(in: &cancellables)
        
        engine.onFileReceived = { [self] url in
            log("Received payload at \(url.lastPathComponent)")
            guard activeProcessingTask == nil else { return }
            activeProcessingTask = Task {
                await processPayload(url: url)
                activeProcessingTask = nil
            }
        }
    }
    
    private func processPayload(url: URL) async {
        isProcessing = true
        progress = 0
        let fm = FileManager.default
        let workDir: URL
        if url.pathExtension == "zip" {
            workDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            log("Unzipping payload...")
            do {
                try ArchiveHelper.unzip(file: url, to: workDir)
            } catch {
                log("Unzip error: \(error.localizedDescription)")
                isProcessing = false
                return
            }
        } else {
            // Already a directory (chunked streaming unzipped directly into this directory)
            workDir = url
        }
        await executePipeline(on: workDir, outputTo: workDir, sendBack: true)
    }
    
    private func selectAndProcessFolder() {
        guard activeProcessingTask == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a VisionScan folder containing images, depth, and roomplan.json"
        
        if panel.runModal() == .OK, let folderURL = panel.url {
            log("Selected offline folder: \(folderURL.lastPathComponent)")
            guard folderURL.startAccessingSecurityScopedResource() else {
                log("❌ Error: Permission denied to access folder.")
                return
            }
            isProcessing = true
            activeProcessingTask = Task {
                await executePipeline(on: folderURL, outputTo: folderURL, sendBack: false)
                folderURL.stopAccessingSecurityScopedResource()
                activeProcessingTask = nil
            }
        }
    }
    

    // MARK: - Core Pipeline
    private func executePipeline(on workDir: URL, outputTo outDir: URL, sendBack: Bool) async {
        await MainActor.run { self.progress = 0.1 }
        let fm = FileManager.default
        log(" Starting processing pipeline...")
        
        let modelUSDZ = outDir.appendingPathComponent("model.usdz")
        let refinedUSDZ = outDir.appendingPathComponent("model_refined.usdz")
        let roomplanJSON = workDir.appendingPathComponent("roomplan.json")
        let texturedUSDZ = outDir.appendingPathComponent("room_textured.usdz")
        let lidarUSDZ = workDir.appendingPathComponent("lidar.usdz")
        let roomScanMergedLiDARUSDZ = outDir.appendingPathComponent("roomscanmergedlidar.usdz")
        let mergedUSDZ = outDir.appendingPathComponent("room_merged.usdz")
        
        var finalNetworkModel = modelUSDZ
        var photogrammetrySucceeded = false
        
        do {
            if runRefiner { try? fm.removeItem(at: refinedUSDZ) }
            
            let preBakedToClean = ["room_textured.usdz", "room_merged.usdz", "roomscanmergedlidar.usdz"]
            for name in preBakedToClean {
                let path = workDir.appendingPathComponent(name)
                if fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: path)
                }
            }
            
            // 1. Photogrammetry Step
            if runPhotogrammetry {
                log("Starting Background PhotogrammetrySession (\(detailLevel))...")
                
                try? fm.removeItem(at: workDir.appendingPathComponent("pg_poses.json"))
                try? fm.removeItem(at: modelUSDZ)
                
                let processor = MacPhotogrammetryProcessor()
                
                var posesDict: [String: [Float]] = [:]
                do {
                    posesDict = try await processor.process(
                        inputURL: workDir,
                        outputModelURL: modelUSDZ,
                        detail: detailLevel,
                        onProgress: { (frac: Double) in
                            Task { @MainActor in self.progress = 0.1 + (frac * 0.5) }
                        },
                        onLog: { (msg: String) in
                            Task { @MainActor in self.log(msg) }
                        }
                    )
                    photogrammetrySucceeded = true
                    
                    let nativePosesURL = workDir.appendingPathComponent("pg_poses.json")
                    if let data = try? JSONSerialization.data(withJSONObject: posesDict) {
                        try? data.write(to: nativePosesURL, options: .atomic)
                        log(" Saved stable pg_poses.json")
                    }
                } catch {
                    log("❌ Photogrammetry failed: \(error.localizedDescription)")
                    photogrammetrySucceeded = false
                }
                
                log("⏳ Letting GPU release session memory...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                
                if !photogrammetrySucceeded {
                    log("❌ Photogrammetry failed to produce a valid model.")
                }
                
                log("⏳ Releasing GPU resources before next step...")
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            } else {
                log("Skipping Photogrammetry...")
                await MainActor.run { self.progress = 0.6 }
            }
            
            // 2. Mesh Refinement
            if runRefiner && fm.fileExists(atPath: modelUSDZ.path) {
                log("Running Mesh Refiner with LiDAR Depth...")
                let depthStore = DepthDataStore(sessionDirectory: workDir)
                let refiner = MeshRefiner()
                
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try refiner.refine(modelURL: modelUSDZ, depthStore: depthStore, outputURL: refinedUSDZ)
                    }.value
                    log("✅ Mesh Refiner completed successfully.")
                    finalNetworkModel = refinedUSDZ
                } catch {
                    log("⚠️ Mesh refiner failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run { self.progress = 0.8 }
            
            // 3. Texture Projector & Merger
            if runProjector {
                if fm.fileExists(atPath: roomplanJSON.path) {
                    log("Loading RoomPlan geometry from roomplan.json...")
                    let jsonData = try Data(contentsOf: roomplanJSON)
                    let room = try JSONDecoder().decode(ArchivedRoom.self, from: jsonData)
                    
                    let photogrammetryModel = finalNetworkModel
                    var scaffoldForProjection: URL = texturedUSDZ
                    
                    do {
                        // Step 3a: Merge RoomScan with LiDAR or just project RoomScan
                        if fm.fileExists(atPath: lidarUSDZ.path) {
                            log("Step 3a: Merging RoomScan structure with LiDAR objects...")
                            let projector = MacRoomTextureProjector()
                            
                            let flatResult = try await projector.projectTextures(
                                room: room,
                                sessionDirectory: workDir,
                                outputURL: texturedUSDZ,
                                progressHandler: { (frac: Double) in
                                    Task { @MainActor in
                                        self.progress = 0.8 + (frac * 0.05)
                                    }
                                }
                            )
                            log("   RoomScan textured: \(flatResult.texturedSurfaceCount)/\(flatResult.totalSurfaceCount) surfaces")
                            await MainActor.run { self.progress = 0.85 }
                            
                            try await Task.detached(priority: .userInitiated) {
                                try MacCaptureManagerHelpers.mergeRoomWithLiDAR(
                                    room: room,
                                    roomSceneURL: texturedUSDZ,
                                    lidarURL: lidarUSDZ,
                                    sessionDirectory: workDir,
                                    outputURL: roomScanMergedLiDARUSDZ
                                )
                            }.value
                            
                            log("✅ RoomScan + LiDAR model created.")
                            scaffoldForProjection = roomScanMergedLiDARUSDZ
                            finalNetworkModel = roomScanMergedLiDARUSDZ
                        } else {
                            log("Step 3a: No LiDAR, projecting textures onto RoomScan only...")
                            let projector = MacRoomTextureProjector()
                            let result = try await projector.projectTextures(
                                room: room,
                                sessionDirectory: workDir,
                                outputURL: texturedUSDZ
                            )
                            log("✅ Textured room: \(result.texturedSurfaceCount)/\(result.totalSurfaceCount) surfaces")
                            scaffoldForProjection = texturedUSDZ
                            finalNetworkModel = texturedUSDZ
                        }
                        await MainActor.run { self.progress = 0.88 }
                        
                        // Step 3b: Snap photogrammetry onto the scaffold
                        if fm.fileExists(atPath: photogrammetryModel.path) {
                            log("Step 3b: Aligning photogrammetry onto scaffold...")
                            let lidarForMerge = fm.fileExists(atPath: lidarUSDZ.path) ? lidarUSDZ : scaffoldForProjection
                            
                            try await Task.detached(priority: .userInitiated) {
                                try MacCaptureManagerHelpers.mergeRoomWithPhotogrammetry(
                                    room: room,
                                    roomSceneURL: scaffoldForProjection,
                                    photogrammetryURL: photogrammetryModel,
                                    lidarURL: lidarForMerge,
                                    sessionDirectory: workDir,
                                    outputURL: mergedUSDZ
                                )
                            }.value
                            
                            log("✅ Step 3b done: Final composite model created: \(mergedUSDZ.lastPathComponent)")
                            finalNetworkModel = mergedUSDZ
                        } else {
                            log("ℹ️ No photogrammetry model — using RoomScan + LiDAR scaffold as final.")
                        }
                        
                    } catch {
                        log("⚠️ Projector/Merger failed: \(error.localizedDescription)")
                    }
                } else {
                    log("⚠️ Skipping projection: roomplan.json not found.")
                }
            }
            
            await MainActor.run { self.progress = 1.0 }
            
            if !fm.fileExists(atPath: finalNetworkModel.path) {
                throw NSError(domain: "Pipeline", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Processing failed: Not enough photos for Photogrammetry, and no RoomScan data found."
                ])
            }
            
            log(" Pipeline complete!")
            
            if sendBack {
                engine.send(fileURL: finalNetworkModel, contextTag: "model.usdz")
            }
            
        } catch {
            log("❌ Pipeline Error: \(error.localizedDescription)")
        }
        
        await MainActor.run { self.isProcessing = false }
    }
}
