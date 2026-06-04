import Foundation
import RealityKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

@available(macOS 12.0, *)
public actor MacPhotogrammetryProcessor {
    
    public init() {}
    
    // MARK: - Metadata helpers
    
    private struct SessionMeta {
        let depthFrameCount: Int
        let slamFailed: Bool
    }
    
    private func readSessionMeta(from dir: URL) -> SessionMeta {
        let metaURL = dir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SessionMeta(depthFrameCount: 0, slamFailed: false)
        }
        let depth = dict["depthFrameCount"] as? Int ?? 0
        let slam  = dict["slamFailed"] as? Bool ?? false
        return SessionMeta(depthFrameCount: depth, slamFailed: slam)
    }
    
    // MARK: - Public API
    
    /// Runs photogrammetry on the given input directory, returns dictionary of camera poses.
    /// Automatically retries with .unordered if .sequential mode produces too many skipped samples.
    public func process(
        inputURL: URL,
        outputModelURL: URL,
        detail: PhotogrammetrySession.Request.Detail,
        onProgress: @Sendable @escaping (Double) -> Void,
        onLog: @Sendable @escaping (String) -> Void
    ) async throws -> [String: [Float]] {
        
        let meta = readSessionMeta(from: inputURL)
        
        // LiDAR sanity check:
        // Only use sequential ordering if we have valid depth frames AND SLAM didn't crash.
        // If SLAM crashed on the iPhone, lidar.usdz may exist but contain no point cloud,
        // and .sequential mode will reject every sample with "not registered".
        let useSequential = meta.depthFrameCount > 0 && !meta.slamFailed
        
        if meta.slamFailed {
            onLog("⚠️ metadata.json reports slamFailed=true — forcing .unordered mode.")
        } else if meta.depthFrameCount == 0 {
            onLog(" No depth frames found — using .unordered mode.")
        } else {
            onLog(" LiDAR path: \(meta.depthFrameCount) depth frames, slamFailed=\(meta.slamFailed) → .sequential")
        }
        
        do {
            return try await runSession(
                inputURL: inputURL,
                outputModelURL: outputModelURL,
                detail: detail,
                sequential: false,
                onProgress: onProgress,
                onLog: onLog
            )
        } catch let err as NSError where err.domain == "MacPhotogrammetryProcessor" && err.code == -3 {
            // Too many samples skipped in sequential mode — retry with unordered
            onLog(" Too many samples skipped in unordered mode. Retrying with .sequential ...")
            return try await runSession(
                inputURL: inputURL,
                outputModelURL: outputModelURL,
                detail: detail,
                sequential: useSequential,
                onProgress: onProgress,
                onLog: onLog
            )
        }
    }
    
    // MARK: - Core session runner
    
    private func runSession(
        inputURL: URL,
        outputModelURL: URL,
        detail: PhotogrammetrySession.Request.Detail,
        sequential: Bool,
        onProgress: @Sendable @escaping (Double) -> Void,
        onLog: @Sendable @escaping (String) -> Void
    ) async throws -> [String: [Float]] {
        
        var config = PhotogrammetrySession.Configuration()
        config.featureSensitivity = .high
        config.sampleOrdering = sequential ? .sequential : .unordered
        
        if #available(macOS 14.0, *) {
            config.isObjectMaskingEnabled = true
        }
        
        onLog(" Starting PhotogrammetrySession (\(detail), \(sequential ? "sequential" : "unordered"))...")
        
        let session = try PhotogrammetrySession(input: inputURL, configuration: config)
        let tempUSDZ = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_model.usdz")
        
        try session.process(requests: [.modelFile(url: tempUSDZ, detail: detail), .poses])
        
        let totalImageCount = (try? FileManager.default.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil).filter {
            ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased())
        }.count) ?? 100
        let maxAllowedSkips = max(20, Int(Double(totalImageCount) * 0.13))
        onLog(" Total image count: \(totalImageCount). Dynamic sequential skip threshold: \(maxAllowedSkips) (13%).")
        
        var posesDict: [String: [Float]] = [:]
        var photogrammetrySucceeded = false
        var skippedCount = 0
        var fatalErrorOccurred = false
        var lastProgress: Double = -1
        var lastProgressTime = Date()
        
        // Timeout watchdog
        // If session.outputs stalls (IOSurface/Metal VRAM OOM) the loop blocks forever
        // at 60%. The watchdog fires if no progress arrives for 90 seconds.
        let outputsTask = Task<Void, Error> {
            outputLoop: for try await output in session.outputs {
                // Check for task cancellation between each output event
                try Task.checkCancellation()
                
                switch output {
                case .requestProgress(_, let frac):
                    onProgress(frac)
                    if abs(frac - lastProgress) > 0.001 {
                        lastProgress = frac
                        lastProgressTime = Date()
                    }
                    
                case .requestComplete(_, let result):
                    if case .modelFile(let url) = result {
                        onLog("✅ Photogrammetry done: \(url.lastPathComponent)")
                        try? FileManager.default.removeItem(at: outputModelURL)
                        try FileManager.default.copyItem(at: url, to: outputModelURL)
                        photogrammetrySucceeded = true
                        
                        // DEADLOCK ESCAPE: In .unordered mode Apple's session.outputs stream
                        // may never emit .processingComplete after .requestComplete, leaving
                        // the for-await loop pinned at 100% CPU/GPU indefinitely.
                        // Once the model file is verified on disk, we hard-break the loop
                        // immediately so the pipeline flows into texture projection (Step 3).
                        if !sequential {
                            onLog(" Unordered mode: model written — short-circuiting output loop to release GPU.")
                            break outputLoop
                        }
                    } else if case .poses(let posesObject) = result {
                        var collected: [String: [Float]] = [:]
                        let posesMap = posesObject.posesBySample
                        onLog(" Extracted \(posesMap.count) camera poses.")
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
                    }
                    
                case .requestError(_, let error):
                    // HARD BREAK: .requestError with a Metal/IOSurface failure indicates
                    // the GPU is in an unrecoverable state. Don't wait — exit the loop now
                    // and let the caller decide whether to retry.
                    let desc = error.localizedDescription
                    onLog("❌ Fatal photogrammetry error: \(desc)")
                    if desc.localizedCaseInsensitiveContains("iosurface") ||
                       desc.localizedCaseInsensitiveContains("metal") ||
                       desc.localizedCaseInsensitiveContains("alloc") {
                        onLog(" GPU resource failure detected — breaking output loop immediately.")
                        fatalErrorOccurred = true
                        session.cancel()
                        break outputLoop
                    }
                    
                case .invalidSample(let id, let reason):
                    onLog("⚠️ Sample [\(id)] dropped: \(reason)")
                    skippedCount += 1
                    
                case .skippedSample(let id):
                    skippedCount += 1
                    onLog("⚠️ Sample [\(id)] skipped by Tracker (\(skippedCount) total)")
                    // Dynamic sequential skip failure check: allow up to 13% failure rate before falling back
                    if sequential && skippedCount >= maxAllowedSkips {
                        onLog(" Too many skipped samples (\(skippedCount)/\(totalImageCount)) in unordered mode — aborting for retry.")
                        session.cancel()
                        break outputLoop
                    }
                    
                case .processingComplete:
                    onLog("✅ Session processing complete.")
                    break outputLoop
                    
                case .processingCancelled:
                    onLog("⚠️ Session cancelled.")
                    break outputLoop
                    
                @unknown default:
                    break
                }
                
                // Watchdog: check progress staleness inside the loop (no separate task needed)
                let stalledFor = Date().timeIntervalSince(lastProgressTime)
                if lastProgress >= 0 && stalledFor > 90 {
                    onLog("⏱️ Timeout: no progress for \(Int(stalledFor))s — aborting stalled session.")
                    session.cancel()
                    throw NSError(domain: "MacPhotogrammetryProcessor", code: -2, userInfo: [
                        NSLocalizedDescriptionKey: "Photogrammetry timed out (\(Int(stalledFor))s no progress). GPU may be out of VRAM. Try 'Reduced' quality."
                    ])
                }
            }
        }
        
        do {
            try await outputsTask.value
        } catch is CancellationError {
            // Task was externally cancelled
        }
        
        // Signal caller to retry with unordered if too many samples were skipped
        if sequential && skippedCount >= maxAllowedSkips && !photogrammetrySucceeded {
            throw NSError(domain: "MacPhotogrammetryProcessor", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Too many samples skipped in sequential mode (\(skippedCount)/\(totalImageCount))."
            ])
        }
        
        if fatalErrorOccurred {
            throw NSError(domain: "MacPhotogrammetryProcessor", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "GPU resource failure (IOSurface/Metal). Close other GPU-intensive apps and retry."
            ])
        }
        
        if !photogrammetrySucceeded {
            throw NSError(domain: "MacPhotogrammetryProcessor", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Photogrammetry failed: not enough valid photos. Capture more overlapping shots with slower movement."
            ])
        }
        
        return posesDict
    }
}
