import Foundation
import SwiftUI
import RoomPlan
import RealityKit
import SceneKit
import ModelIO

// MARK: - FolderReprocessor
// Replicates the EXACT same pipeline as a live room scan, but from a folder
// of previously exported raw data.
@MainActor
final class FolderReprocessor: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""
    @Published var error: String? = nil
    @Published var resultURL: URL? = nil
    @Published var selectedQuality: ModelQuality = .reduced
    
    func reprocessFolder(at url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            self.error = "Permission denied to access folder."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        isProcessing = true
        progress = 0.02
        statusMessage = "Copying raw data to working directory..."
        error = nil
        resultURL = nil
        
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("VisionScan_Reprocess_\(UUID().uuidString)")
        
        do {
            // 1. Copy folder to a writable temp directory
            try fm.copyItem(at: url, to: tempDir)
            
            // 2. Validate raw data files
            let roomplanJSON = tempDir.appendingPathComponent("roomplan.json")
            let depthDir     = tempDir.appendingPathComponent("depth")
            
            guard fm.fileExists(atPath: roomplanJSON.path) else {
                throw ReprocessError.missingFile(
                    "roomplan.json missing. The scan must save RoomPlan data in JSON format.")
            }
            guard fm.fileExists(atPath: depthDir.path) else {
                throw ReprocessError.missingFile(
                    "depth/ directory with camera data is missing.")
            }
            
            // Count available photos
            let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
            let allFiles = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            let photoCount = allFiles.filter { imageExts.contains($0.pathExtension.lowercased()) }.count
            print(" Reprocessor: found \(photoCount) photos in folder")
            
            guard photoCount >= 3 else {
                throw ReprocessError.missingFile(
                    "Need at least 3 photos. Found \(photoCount).")
            }
            
            // 3. Delete ALL pre-baked models so we start fresh
            statusMessage = "Cleaning pre-baked models..."
            progress = 0.05
            
            let filesToDelete = [
                "model.usdz",
                "room_textured.usdz",
                "room_merged.usdz",
                "roomplan.usdz"
            ]
            for name in filesToDelete {
                let path = tempDir.appendingPathComponent(name)
                if fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: path)
                    print(" Deleted pre-baked: \(name)")
                }
            }
            
            // 4. Decode ArchivedRoom from JSON
            statusMessage = "Loading RoomPlan geometry..."
            progress = 0.08
            
            let jsonData = try Data(contentsOf: roomplanJSON)
            let archivedRoom = try JSONDecoder().decode(ArchivedRoom.self, from: jsonData)
            print(" RoomPlan: \(archivedRoom.walls.count) walls, \(archivedRoom.doors.count) doors, \(archivedRoom.windows.count) windows")
            
            // 5. Run Photogrammetry — rebuild model.usdz from photos
            statusMessage = "Building 3D model from photos..."
            progress = 0.1
            
            let modelURL = tempDir.appendingPathComponent("model.usdz")
            let roomPhotogrammetry = RoomPhotogrammetry()
            
            do {
                try await roomPhotogrammetry.process(
                    imagesDirectory: tempDir,
                    outputURL: modelURL,
                    detail: selectedQuality.detail,
                    onProgress: { @Sendable [weak self] fraction in
                        Task { @MainActor in
                            guard let self = self else { return }
                            // Photogrammetry is 10% → 80% of total progress
                            self.progress = 0.1 + (fraction * 0.7)
                            self.statusMessage = "Building 3D model: \(Int(fraction * 100))%"
                        }
                    }
                )
            } catch {
                print("⚠️ Photogrammetry processing failed fallback active: \(error.localizedDescription)")
            }
            
            let modelExists = fm.fileExists(atPath: modelURL.path)
            if modelExists {
                let size = (try? fm.attributesOfItem(atPath: modelURL.path))?[.size] as? Int ?? 0
                print("✅ Photogrammetry model: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            } else {
                print("⚠️ Photogrammetry produced no model — will use textured room only")
            }
            
            // 5b. Run Mesh Refinement (Step 2)
            var finalModelURL = modelURL
            let refinedURL = tempDir.appendingPathComponent("model_refined.usdz")
            
            let runRefiner = true
            if runRefiner && modelExists && fm.fileExists(atPath: depthDir.path) {
                statusMessage = "Refining mesh with LiDAR depth..."
                progress = 0.80
                
                let depthStore = DepthDataStore(sessionDirectory: tempDir)
                var refinerConfig = MeshRefiner.Config()
                refinerConfig.snapRadius = 0.02
                let refiner = MeshRefiner(config: refinerConfig)
                
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try refiner.refine(modelURL: modelURL, depthStore: depthStore, outputURL: refinedURL)
                    }.value
                    if fm.fileExists(atPath: refinedURL.path) {
                        finalModelURL = refinedURL
                        print("✅ Folder reprocess: Mesh Refiner completed successfully.")
                    }
                } catch {
                    print("⚠️ Folder reprocess: Mesh refiner failed: \(error.localizedDescription)")
                }
            }
            
            // 6. Project textures onto RoomPlan walls
            statusMessage = "Projecting textures onto walls..."
            progress = 0.82
            
            let texturedURL = tempDir.appendingPathComponent("room_textured.usdz")
            
            let projector = MacRoomTextureProjector()
            let projResult = try await Task.detached {
                return try await projector.projectTextures(
                    room: archivedRoom,
                    sessionDirectory: tempDir,
                    outputURL: texturedURL
                )
            }.value
            
            print("✅ Textured room: \(projResult.texturedSurfaceCount)/\(projResult.totalSurfaceCount) surfaces")
            
            statusMessage = "Cooling down memory..."
            try await Task.yield()
            
            // 7. Merge textured room + photogrammetry mesh
            var finalSource = texturedURL
            let lidarURL = tempDir.appendingPathComponent("lidar.usdz")
            let scaffoldURL = tempDir.appendingPathComponent("room_lidar_merged.usdz")
            var scaffoldURLToUse = texturedURL
            
            if fm.fileExists(atPath: lidarURL.path) {
                statusMessage = "Merging room with LiDAR scaffold..."
                progress = 0.85
                
                try await Task.detached(priority: .medium) {
                    try autoreleasepool {
                        try MacCaptureManagerHelpers.mergeRoomWithLiDAR(
                            room: archivedRoom,
                            roomSceneURL: texturedURL,
                            lidarURL: lidarURL,
                            sessionDirectory: tempDir,
                            outputURL: scaffoldURL
                        )
                    }
                }.value
                
                if fm.fileExists(atPath: scaffoldURL.path) {
                    scaffoldURLToUse = scaffoldURL
                    finalSource = scaffoldURL
                    print("✅ Built RoomScan + LiDAR scaffold.")
                }
            }
            
            if modelExists {
                statusMessage = "Merging photogrammetry into room..."
                progress = 0.90
                
                let mergedURL = tempDir.appendingPathComponent("room_merged.usdz")
                let hasLidar = fm.fileExists(atPath: lidarURL.path)
                let lidarForMerge = hasLidar ? lidarURL : scaffoldURLToUse
                
                try await Task.detached(priority: .medium) {
                    try autoreleasepool {
                        try MacCaptureManagerHelpers.mergeRoomWithPhotogrammetry(
                            room: archivedRoom,
                            roomSceneURL: scaffoldURLToUse,
                            photogrammetryURL: finalModelURL,
                            lidarURL: lidarForMerge,
                            sessionDirectory: tempDir,
                            outputURL: mergedURL
                        )
                    }
                }.value
                
                if fm.fileExists(atPath: mergedURL.path) {
                    finalSource = mergedURL
                    let size = (try? fm.attributesOfItem(atPath: mergedURL.path))?[.size] as? Int ?? 0
                    print("✅ Merged scene: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                }
            }
            
            // 8. Copy result to Documents (QuickLook can't read NSIRD temp)
            statusMessage = "Saving result..."
            progress = 0.96
            
            let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let outputDir = docsDir.appendingPathComponent("Reprocessed")
            try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
            
            let finalURL = outputDir.appendingPathComponent("room_result.usdz")
            try? fm.removeItem(at: finalURL)
            
            let cleanSourceURL = URL(fileURLWithPath: finalSource.path)
            let cleanOutputURL = URL(fileURLWithPath: finalURL.path)
            
            let asset = MDLAsset(url: cleanSourceURL)
            for i in 0..<asset.count {
                if let mesh = asset.object(at: i) as? MDLMesh {
                    for submesh in mesh.submeshes as? [MDLSubmesh] ?? [] {
                        if let mat = submesh.material {
                            for j in 0..<mat.count {
                                if let prop = mat[j] {
                                    if prop.type == .texture, let urlTexture = prop.textureSamplerValue?.texture as? MDLURLTexture {
                                        let url = urlTexture.url
                                        if url.lastPathComponent.contains("rematerial") {
                                             prop.textureSamplerValue = nil
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            do {
                try asset.export(to: cleanOutputURL)
                print("✅ Successfully exported clean USDZ via ModelIO")
            } catch {
                print("⚠️ ModelIO export failed, falling back to basic copy: \(error.localizedDescription)")
                try? fm.copyItem(at: cleanSourceURL, to: cleanOutputURL)
            }
            
            if modelExists {
                let modelCopy = outputDir.appendingPathComponent("model_result.usdz")
                try? fm.removeItem(at: modelCopy)
                try? fm.copyItem(at: finalModelURL, to: modelCopy)
            }
            
            statusMessage = "Done!"
            progress = 1.0
            
            resultURL = finalURL
            print("✅ Reprocess complete → \(finalURL.path)")
            
            // Clean up the large temp copy
            try? fm.removeItem(at: tempDir)
            
        } catch {
            print("❌ Reprocess error: \(error)")
            self.error = error.localizedDescription
            try? fm.removeItem(at: tempDir)
        }
        
        isProcessing = false
    }
    
    enum ReprocessError: LocalizedError {
        case missingFile(String)
        
        var errorDescription: String? {
            switch self {
            case .missingFile(let msg): return msg
            }
        }
    }
}
