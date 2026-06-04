import Foundation
import RealityKit
import ImageIO
import CoreGraphics
import SceneKit
import UniformTypeIdentifiers

// MARK: - RoomPhotogrammetry
// Simple wrapper around PhotogrammetrySession optimized for room-scale scenes.
// Feeds ALL photos — no subsampling, no chunking.
// Uses .sequential ordering for spatial continuity.
final class RoomPhotogrammetry {

    /// Process all images in a directory through a single PhotogrammetrySession.
    func process(
        imagesDirectory: URL,
        outputURL: URL,
        detail: RealityKit.PhotogrammetrySession.Request.Detail = .reduced,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        var config = RealityKit.PhotogrammetrySession.Configuration()
        
        let lidarURL = imagesDirectory.appendingPathComponent("lidar.usdz")
        let hasValidLidar = fileManager.fileExists(atPath: lidarURL.path) &&
        (try! fileManager.attributesOfItem(atPath: lidarURL.path)[.size] as? UInt64 ?? 0) > 0

        if hasValidLidar {
            print(" RoomPhotogrammetry: LiDAR track confirmed. Running hybrid reconstruction.")
            config.sampleOrdering = .sequential
            config.featureSensitivity = .high
        } else {
            print("ℹ️ RoomPhotogrammetry: NO LiDAR data found. Swapping to UNORDERED photo-mode.")
            config.sampleOrdering = .unordered
            config.featureSensitivity = .high
            if #available(iOS 17.0, macOS 14.0, *) {
                config.isObjectMaskingEnabled = false
            }
        }

        let session = try RealityKit.PhotogrammetrySession(
            input: imagesDirectory,
            configuration: config
        )

        let request = RealityKit.PhotogrammetrySession.Request.modelFile(
            url: outputURL,
            detail: detail
        )
        let posesRequest = RealityKit.PhotogrammetrySession.Request.poses

        // Count images for logging
        let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
        let imageCount = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)
            .filter { imageExts.contains($0.pathExtension.lowercased()) }.count) ?? 0
        print(" RoomPhotogrammetry: processing \(imageCount) images")

        try session.process(requests: [request, posesRequest])

        var gotModel = false
        var posesDict: [String: [Float]] = [:]
        outputLoop: for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                onProgress(fraction)
            case .requestComplete(_, let result):
                if case .modelFile(let url) = result {
                    gotModel = true
                    print("✅ requestComplete: \(url.lastPathComponent)")
                } else if case .poses(let posesObject) = result {
                    var collected: [String: [Float]] = [:]
                    let posesMap = posesObject.posesBySample
                    print(" Extracted \(posesMap.count) camera poses on iOS.")
                    for (id, pose) in posesMap {
                        let m = pose.transform.matrix
                        collected["\(id)"] = [
                            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
                        ]
                    }
                    posesDict = collected
                    
                    // Write pg_poses.json
                    let posesURL = imagesDirectory.appendingPathComponent("pg_poses.json")
                    if let data = try? JSONSerialization.data(withJSONObject: posesDict) {
                        try? data.write(to: posesURL, options: .atomic)
                        print(" Saved stable pg_poses.json to \(posesURL.lastPathComponent)")
                    }
                }
            case .requestError(_, let error):
                print("⚠️ requestError (continuing): \(error.localizedDescription)")
            case .processingComplete:
                print(" processingComplete — gotModel: \(gotModel)")
                break outputLoop
            default:
                break
            }
        }
    }
}
