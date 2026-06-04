import Foundation
import simd
import CoreVideo

#if os(iOS)
import ARKit
import UIKit
#endif

// MARK: - DepthDataStore
// Persists LiDAR depth maps, confidence maps, and camera parameters alongside
// each captured photo so they can be reloaded later for mesh refinement.
final class DepthDataStore: @unchecked Sendable {
    
    /// Root directory for this capture session's depth data
    let depthDirectory: URL
    
    /// Number of frames saved so far
    private(set) var frameCount: Int = 0
    
    /// Whether the device has LiDAR
    let hasLiDAR: Bool
    
    init(sessionDirectory: URL) {
        self.depthDirectory = sessionDirectory.appendingPathComponent("depth")
        #if os(iOS)
        self.hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #else
        // On macOS, check metadata.json written by the iOS app
        let metaURL = sessionDirectory.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(SessionMetadata.self, from: data) {
            self.hasLiDAR = meta.hasLiDAR
        } else {
            // Fallback: presence of lidar.usdz means LiDAR was available
            self.hasLiDAR = FileManager.default.fileExists(
                atPath: sessionDirectory.appendingPathComponent("lidar.usdz").path
            )
        }
        #endif
    }
    
    func createDirectory() {
        try? FileManager.default.createDirectory(
            at: depthDirectory,
            withIntermediateDirectories: true
        )
        print(" DepthDataStore: created at \(depthDirectory.path) (LiDAR: \(hasLiDAR))")
    }
    
    // MARK: - Save Frame Data
    
    #if os(iOS)
    /// Saves depth map, confidence map, and camera parameters as sidecar files.
    /// Call this from capturePhoto() after saving the HEIC image.
    func saveFrame(
        imageFilename: String,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        imageResolution: CGSize,
        timestamp: TimeInterval
    ) {
        let baseName = (imageFilename as NSString).deletingPathExtension
        
        // Camera JSON
        let cameraJSON = CameraFrameData(
            imageFilename: imageFilename,
            timestamp: timestamp,
            intrinsics: intrinsics.toArray(),
            extrinsics: cameraTransform.toArray(),
            imageWidth: Int(imageResolution.width),
            imageHeight: Int(imageResolution.height),
            hasDepth: depthMap != nil,
            hasConfidence: confidenceMap != nil
        )
        
        let cameraURL = depthDirectory.appendingPathComponent("\(baseName)_camera.json")
        if let data = try? JSONEncoder().encode(cameraJSON) {
            try? data.write(to: cameraURL)
        }
        
        // Depth Map (.bin)
        if let depthMap = depthMap {
            let depthURL = depthDirectory.appendingPathComponent("\(baseName)_depth.bin")
            savePixelBuffer(depthMap, to: depthURL)
        }
        
        // Confidence Map (.bin)
        if let confidenceMap = confidenceMap {
            let confURL = depthDirectory.appendingPathComponent("\(baseName)_confidence.bin")
            savePixelBuffer(confidenceMap, to: confURL)
        }
        
        frameCount += 1
    }
    
    // MARK: - Save Session Metadata
    
    /// Writes a top-level metadata.json describing the capture session.
    @MainActor func saveSessionMetadata(
        to sessionDirectory: URL,
        imageCount: Int,
        lidarExportCenter: SIMD3<Float>? = nil,
        slamFailed: Bool = false
    ) {
        let metadata = SessionMetadata(
            deviceModel: deviceModelName(),
            hasLiDAR: hasLiDAR,
            imageCount: imageCount,
            depthFrameCount: frameCount,
            captureDate: ISO8601DateFormatter().string(from: Date()),
            iosVersion: UIDevice.current.systemVersion,
            lidarExportCenter: lidarExportCenter.map { [$0.x, $0.y, $0.z] },
            slamFailed: slamFailed
        )
        
        let url = sessionDirectory.appendingPathComponent("metadata.json")
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: url)
            print(" Session metadata saved: \(imageCount) images, \(frameCount) depth frames, slamFailed=\(slamFailed)")
        }
    }
    #endif
    
    // MARK: - Load (for Phase 3 mesh refinement)
    
    /// Loads all camera frame data from the depth directory.
    func loadAllCameraData() -> [CameraFrameData] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: depthDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix("_camera.json") }
            .compactMap { url -> CameraFrameData? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CameraFrameData.self, from: data)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    /// Loads a raw depth map from .bin file as [Float] array.
    func loadDepthMap(for imageFilename: String) -> (data: [Float], width: Int, height: Int)? {
        let baseName = (imageFilename as NSString).deletingPathExtension
        let url = depthDirectory.appendingPathComponent("\(baseName)_depth.bin")
        
        guard let rawData = try? Data(contentsOf: url) else { return nil }
        
        // Read header: width (UInt32) + height (UInt32) + Float32 pixels
        guard rawData.count >= 8 else { return nil }
        
        let width = Int(rawData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        let height = Int(rawData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        
        let pixelCount = width * height
        let expectedSize = 8 + pixelCount * MemoryLayout<Float>.size
        guard rawData.count >= expectedSize else { return nil }
        
        let floats = rawData.advanced(by: 8).withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(pixelCount))
        }
        
        return (floats, width, height)
    }
    
    // MARK: - Private Helpers
    
    #if os(iOS)
    /// Saves a CVPixelBuffer to disk as raw binary with a simple width+height header.
    private func savePixelBuffer(_ buffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        
        var data = Data()
        // Header: width + height as UInt32
        var w = UInt32(width)
        var h = UInt32(height)
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        
        // Pixel data row by row (handles stride != width * bpp)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let bytesPerPixel: Int
        
        switch pixelFormat {
        case kCVPixelFormatType_DepthFloat32:
            bytesPerPixel = 4
        case kCVPixelFormatType_OneComponent8:  // confidence map
            bytesPerPixel = 1
        default:
            bytesPerPixel = bytesPerRow / max(width, 1)
        }
        
        for row in 0..<height {
            let rowStart = base.advanced(by: row * bytesPerRow)
            data.append(Data(bytes: rowStart, count: width * bytesPerPixel))
        }
        
        try? data.write(to: url)
    }
    
    private func deviceModelName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
    }
    #endif
}

struct CameraFrameData: Codable {
    let imageFilename: String
    let timestamp: TimeInterval
    let intrinsics: [Float]       // 3x3 = 9 values, column-major
    let extrinsics: [Float]       // 4x4 = 16 values, column-major
    let imageWidth: Int
    let imageHeight: Int
    let hasDepth: Bool
    let hasConfidence: Bool
}

struct SessionMetadata: Codable {
    let deviceModel: String
    let hasLiDAR: Bool
    let imageCount: Int
    let depthFrameCount: Int
    let captureDate: String
    let iosVersion: String
    let lidarExportCenter: [Float]?
    /// True if RoomPlan/ARKit SLAM crashed during the capture session.
    /// When true, the Mac must NOT use .sequential ordering — lidar.usdz
    /// may exist on disk but contain no valid point cloud data.
    let slamFailed: Bool

    enum CodingKeys: String, CodingKey {
        case deviceModel, hasLiDAR, imageCount, depthFrameCount, captureDate, iosVersion, lidarExportCenter, slamFailed
    }

    init(
        deviceModel: String,
        hasLiDAR: Bool,
        imageCount: Int,
        depthFrameCount: Int,
        captureDate: String,
        iosVersion: String,
        lidarExportCenter: [Float]? = nil,
        slamFailed: Bool = false
    ) {
        self.deviceModel = deviceModel
        self.hasLiDAR = hasLiDAR
        self.imageCount = imageCount
        self.depthFrameCount = depthFrameCount
        self.captureDate = captureDate
        self.iosVersion = iosVersion
        self.lidarExportCenter = lidarExportCenter
        self.slamFailed = slamFailed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceModel = (try? container.decode(String.self, forKey: .deviceModel)) ?? "Unknown"
        if let boolValue = try? container.decode(Bool.self, forKey: .hasLiDAR) {
            hasLiDAR = boolValue
        } else if let intValue = try? container.decode(Int.self, forKey: .hasLiDAR) {
            hasLiDAR = intValue != 0
        } else {
            hasLiDAR = false
        }
        imageCount = (try? container.decode(Int.self, forKey: .imageCount)) ?? 0
        depthFrameCount = (try? container.decode(Int.self, forKey: .depthFrameCount)) ?? 0
        captureDate = (try? container.decode(String.self, forKey: .captureDate)) ?? ""
        iosVersion = (try? container.decode(String.self, forKey: .iosVersion)) ?? ""
        lidarExportCenter = try? container.decode([Float].self, forKey: .lidarExportCenter)
        slamFailed = (try? container.decode(Bool.self, forKey: .slamFailed)) ?? false
    }
}

extension simd_float3x3 {
    func toArray() -> [Float] {
        // Column-major: col0, col1, col2
        [columns.0.x, columns.0.y, columns.0.z,
         columns.1.x, columns.1.y, columns.1.z,
         columns.2.x, columns.2.y, columns.2.z]
    }
    
    static func fromArray(_ a: [Float]) -> simd_float3x3 {
        guard a.count >= 9 else { return matrix_identity_float3x3 }
        return simd_float3x3(
            SIMD3(a[0], a[1], a[2]),
            SIMD3(a[3], a[4], a[5]),
            SIMD3(a[6], a[7], a[8])
        )
    }
}

extension simd_float4x4 {
    func toArray() -> [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }
    
    static func fromArray(_ a: [Float]) -> simd_float4x4 {
        guard a.count >= 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(
            SIMD4(a[0], a[1], a[2], a[3]),
            SIMD4(a[4], a[5], a[6], a[7]),
            SIMD4(a[8], a[9], a[10], a[11]),
            SIMD4(a[12], a[13], a[14], a[15])
        )
    }
}
