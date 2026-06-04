import Foundation
import SceneKit
import simd
import CoreImage
import UIKit

// MARK: - MacRoomTextureProjector
// Port of RoomTextureProjector for iOS, using ArchivedRoom and UIKit/CoreGraphics.
struct SendableCIContext: @unchecked Sendable {
    let context: CIContext
}

final class MacRoomTextureProjector {
    
    // Shared CoreImage context (hardware-accelerated) to avoid massive overhead of recreating it thousands of times.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    struct Result {
        let sceneURL: URL
        let texturedSurfaceCount: Int
        let totalSurfaceCount: Int
    }
    
    struct TexturedSurfaceResult: Sendable {
        let label: String
        let width: CGFloat
        let height: CGFloat
        let transform: simd_float4x4
        let isFloor: Bool
        let texture: UIImage?
        let bestScore: Float
    }
    
    enum ProjectionError: LocalizedError {
        case noCameraData
        case exportFailed
        
        var errorDescription: String? {
            switch self {
            case .noCameraData: return "No camera frame data found for texture projection"
            case .exportFailed: return "Failed to export textured room USDZ"
            }
        }
    }
    
    // MARK: - Public API
    
    func projectTextures(
        room: ArchivedRoom,
        sessionDirectory: URL,
        outputURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> Result {
        let cameraFrames = loadAllCameraData(sessionDirectory: sessionDirectory)
        
        guard !cameraFrames.isEmpty else {
            throw ProjectionError.noCameraData
        }
        
        print(" MacRoomTextureProjector: \(cameraFrames.count) camera frames, \(room.walls.count) walls")
        
        let scene = SCNScene()
        let rootNode = scene.rootNode
        var texturedCount = 0
        var totalCount = 0
        
        let totalSurfacesToProcess = room.walls.count + room.floors.count
        var surfacesProcessed = 0
        
        // Use a concurrent task group to process surfaces
        let sendableContext = SendableCIContext(context: self.ciContext)
        try await withThrowingTaskGroup(of: TexturedSurfaceResult.self) { group in
            
            // Walls
            for (i, wall) in room.walls.enumerated() {
                group.addTask {
                    return Self.computeTexture(
                        label: "wall_\(i)",
                        width: CGFloat(wall.dimensions.x),
                        height: CGFloat(wall.dimensions.y),
                        transform: wall.transform,
                        cameraFrames: cameraFrames,
                        sessionDirectory: sessionDirectory,
                        isFloor: false,
                        ciContext: sendableContext
                    )
                }
            }
            
            // Floor
            for (i, floor) in room.floors.enumerated() {
                group.addTask {
                    return Self.computeTexture(
                        label: "floor_\(i)",
                        width: CGFloat(floor.dimensions.x),
                        height: CGFloat(floor.dimensions.y),
                        transform: floor.transform,
                        cameraFrames: cameraFrames,
                        sessionDirectory: sessionDirectory,
                        isFloor: true,
                        ciContext: sendableContext
                    )
                }
            }
            
            // Collect results and build SCNNodes on this thread
            for try await res in group {
                let plane = SCNPlane(width: res.width, height: res.height)
                let node = SCNNode(geometry: plane)
                node.name = res.label
                node.simdTransform = res.transform
                
                let mat = SCNMaterial()
                mat.isDoubleSided = true
                
                if let texture = res.texture {
                    mat.diffuse.contents = texture
                    mat.lightingModel = .physicallyBased
                    texturedCount += 1
                    print("   \(res.label): textured from result (score: \(String(format: "%.3f", res.bestScore)))")
                } else {
                    mat.diffuse.contents = res.isFloor ? UIColor(white: 0.85, alpha: 1.0) : UIColor(white: 0.92, alpha: 1.0)
                    print("  ⬜ \(res.label): no good camera frame found")
                }
                
                plane.materials = [mat]
                rootNode.addChildNode(node)
                totalCount += 1
                
                surfacesProcessed += 1
                if totalSurfacesToProcess > 0 {
                    progressHandler?(Double(surfacesProcessed) / Double(totalSurfacesToProcess))
                }
            }
        }
        
        // Doors
        for (i, door) in room.doors.enumerated() {
            let dims = door.dimensions
            let node = SCNNode(geometry: SCNBox(width: CGFloat(dims.x), height: CGFloat(dims.y), length: 0.08, chamferRadius: 0))
            node.name = "door_\(i)"
            node.simdTransform = door.transform
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor(red: 0.55, green: 0.35, blue: 0.2, alpha: 0.6)
            mat.isDoubleSided = true
            node.geometry?.materials = [mat]
            rootNode.addChildNode(node)
        }
        
        // Windows
        for (i, window) in room.windows.enumerated() {
            let dims = window.dimensions
            let node = SCNNode(geometry: SCNBox(width: CGFloat(dims.x), height: CGFloat(dims.y), length: 0.05, chamferRadius: 0))
            node.name = "window_\(i)"
            node.simdTransform = window.transform
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 0.3)
            mat.transparency = 0.5
            mat.isDoubleSided = true
            node.geometry?.materials = [mat]
            rootNode.addChildNode(node)
        }
        
        // Export
        let success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
        guard success else {
            throw ProjectionError.exportFailed
        }
        
        print("✅ MacRoomTextureProjector: \(texturedCount)/\(totalCount) surfaces textured → \(outputURL.lastPathComponent)")
        return Result(sceneURL: outputURL, texturedSurfaceCount: texturedCount, totalSurfaceCount: totalCount)
    }
    
    // MARK: - Helpers
    
    private func loadAllCameraData(sessionDirectory: URL) -> [CameraFrameData] {
        let depthDir = sessionDirectory.appendingPathComponent("depth")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: depthDir.path) else { return [] }
        
        var frames: [CameraFrameData] = []
        let decoder = JSONDecoder()
        
        for file in files where file.hasSuffix("_camera.json") {
            let url = depthDir.appendingPathComponent(file)
            if let data = try? Data(contentsOf: url),
               let frame = try? decoder.decode(CameraFrameData.self, from: data) {
                frames.append(frame)
            }
        }
        return frames.sorted { $0.timestamp < $1.timestamp }
    }
    
    private static func projectToPixel(
        worldPoint: SIMD4<Float>,
        viewMatrix: simd_float4x4,
        intrinsics: simd_float3x3,
        arWidth: Int, arHeight: Int,
        imgWidth: CGFloat, imgHeight: CGFloat
    ) -> CGPoint? {
        let camSpace = viewMatrix * worldPoint
        guard camSpace.z < -0.01 else { return nil }
        
        let arPx = intrinsics[0][0] * (-camSpace.x / camSpace.z) + intrinsics[2][0]
        let arPy = intrinsics[1][1] * (-camSpace.y / camSpace.z) + intrinsics[2][1]
        
        let scaleX = imgWidth / CGFloat(arWidth)
        let scaleY = imgHeight / CGFloat(arHeight)
        
        return CGPoint(x: CGFloat(arPx) * scaleX, y: CGFloat(arPy) * scaleY)
    }
    
    private static func uiToCIPoint(_ pt: CGPoint, imageHeight: CGFloat) -> CGPoint {
        return CGPoint(x: pt.x, y: imageHeight - pt.y)
    }
    
    // MARK: - Surface Texturing (Static / Concurrent Thread-Safe)
    
    private static func computeTexture(
        label: String,
        width: CGFloat,
        height: CGFloat,
        transform: simd_float4x4,
        cameraFrames: [CameraFrameData],
        sessionDirectory: URL,
        isFloor: Bool,
        ciContext: SendableCIContext
    ) -> TexturedSurfaceResult {
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let normalPosZ = normalize(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let normalNegZ = -normalPosZ
        
        let hw = Float(width) * 0.5
        let hh = Float(height) * 0.5
        let localCorners: [SIMD4<Float>] = [
            SIMD4(-hw, -hh, 0, 1),
            SIMD4( hw, -hh, 0, 1),
            SIMD4( hw,  hh, 0, 1),
            SIMD4(-hw,  hh, 0, 1)
        ]
        let worldCorners = localCorners.map { transform * $0 }
        
        var bestScore: Float = -1
        var bestFrame: CameraFrameData?
        
        for frame in cameraFrames {
            let camTransform = simd_float4x4(
                simd_float4(frame.extrinsics[0], frame.extrinsics[1], frame.extrinsics[2], frame.extrinsics[3]),
                simd_float4(frame.extrinsics[4], frame.extrinsics[5], frame.extrinsics[6], frame.extrinsics[7]),
                simd_float4(frame.extrinsics[8], frame.extrinsics[9], frame.extrinsics[10], frame.extrinsics[11]),
                simd_float4(frame.extrinsics[12], frame.extrinsics[13], frame.extrinsics[14], frame.extrinsics[15])
            )
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            let camForward = normalize(SIMD3<Float>(-camTransform.columns.2.x, -camTransform.columns.2.y, -camTransform.columns.2.z))
            
            let toSurface = normalize(center - camPos)
            let facingDot = simd_dot(toSurface, camForward)
            guard facingDot > 0.2 else { continue }
            
            let surfaceFacingA = -simd_dot(normalPosZ, toSurface)
            let surfaceFacingB = -simd_dot(normalNegZ, toSurface)
            let surfaceFacing = max(surfaceFacingA, surfaceFacingB)
            guard surfaceFacing > 0.05 else { continue }
            
            let distance = simd_distance(camPos, center)
            let distScore = 1.0 / (1.0 + distance)
            
            let intrinsics = simd_float3x3(
                simd_float3(frame.intrinsics[0], frame.intrinsics[1], frame.intrinsics[2]),
                simd_float3(frame.intrinsics[3], frame.intrinsics[4], frame.intrinsics[5]),
                simd_float3(frame.intrinsics[6], frame.intrinsics[7], frame.intrinsics[8])
            )
            let viewMatrix = simd_inverse(camTransform)
            var inFrameCount = 0
            
            for corner in worldCorners {
                if let pt = projectToPixel(
                    worldPoint: corner, viewMatrix: viewMatrix, intrinsics: intrinsics,
                    arWidth: frame.imageWidth, arHeight: frame.imageHeight,
                    imgWidth: CGFloat(frame.imageWidth), imgHeight: CGFloat(frame.imageHeight)
                ) {
                    if pt.x >= 0 && pt.x < CGFloat(frame.imageWidth) && pt.y >= 0 && pt.y < CGFloat(frame.imageHeight) {
                        inFrameCount += 1
                    }
                }
            }
            
            let coverageFrac = Float(max(1, inFrameCount)) / 4.0
            let score = facingDot * surfaceFacing * distScore * coverageFrac
            
            if score > bestScore {
                bestScore = score
                bestFrame = frame
            }
        }
        
        var extractedImage: UIImage? = nil
        if let frame = bestFrame {
            extractedImage = extractTexture(
                for: worldCorners,
                from: frame,
                sessionDirectory: sessionDirectory,
                ciContext: ciContext.context
            )
        }
        
        return TexturedSurfaceResult(
            label: label,
            width: width,
            height: height,
            transform: transform,
            isFloor: isFloor,
            texture: extractedImage,
            bestScore: bestScore
        )
    }
    
    // MARK: - Texture Extraction (Static / Concurrent Thread-Safe)
    
    private static func extractTexture(
        for worldCorners: [SIMD4<Float>],
        from frame: CameraFrameData,
        sessionDirectory: URL,
        ciContext: CIContext
    ) -> UIImage? {
        let imageURL = sessionDirectory.appendingPathComponent(frame.imageFilename)
        
        // Use CIImage(contentsOf:) to automatically apply EXIF orientation from HEIC files.
        guard let orientedCI = CIImage(contentsOf: imageURL) else { return nil }
        guard let cgImage = ciContext.createCGImage(orientedCI, from: orientedCI.extent) else { return nil }
        
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        
        let intrinsics = simd_float3x3(
            simd_float3(frame.intrinsics[0], frame.intrinsics[1], frame.intrinsics[2]),
            simd_float3(frame.intrinsics[3], frame.intrinsics[4], frame.intrinsics[5]),
            simd_float3(frame.intrinsics[6], frame.intrinsics[7], frame.intrinsics[8])
        )
        let camTransform = simd_float4x4(
            simd_float4(frame.extrinsics[0], frame.extrinsics[1], frame.extrinsics[2], frame.extrinsics[3]),
            simd_float4(frame.extrinsics[4], frame.extrinsics[5], frame.extrinsics[6], frame.extrinsics[7]),
            simd_float4(frame.extrinsics[8], frame.extrinsics[9], frame.extrinsics[10], frame.extrinsics[11]),
            simd_float4(frame.extrinsics[12], frame.extrinsics[13], frame.extrinsics[14], frame.extrinsics[15])
        )
        let viewMatrix = simd_inverse(camTransform)
        
        var uiPixelPoints: [CGPoint] = []
        for corner in worldCorners {
            if let pt = projectToPixel(
                worldPoint: corner, viewMatrix: viewMatrix, intrinsics: intrinsics,
                arWidth: frame.imageWidth, arHeight: frame.imageHeight, imgWidth: imgW, imgHeight: imgH
            ) {
                uiPixelPoints.append(CGPoint(x: min(max(pt.x, 0), imgW - 1), y: min(max(pt.y, 0), imgH - 1)))
            } else {
                uiPixelPoints.append(CGPoint(x: imgW * 0.5, y: imgH * 0.5))
            }
        }
        
        let minX = uiPixelPoints.map(\.x).min()!
        let maxX = uiPixelPoints.map(\.x).max()!
        let minY = uiPixelPoints.map(\.y).min()!
        let maxY = uiPixelPoints.map(\.y).max()!
        guard (maxX - minX) > 10, (maxY - minY) > 10 else { return nil }
        
        let ciPoints = uiPixelPoints.map { uiToCIPoint($0, imageHeight: imgH) }
        
        let ciImage = CIImage(cgImage: cgImage) // Already orientation-corrected
        
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            let cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
            return UIImage(cgImage: cropped)
        }
        
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: ciPoints[0]), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: ciPoints[1]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciPoints[2]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciPoints[3]), forKey: "inputTopLeft")
        
        guard let outputCI = filter.outputImage else { return nil }
        
        guard let outputCG = ciContext.createCGImage(outputCI, from: outputCI.extent) else { return nil }
        
        // Scale down to 1024 to save memory
        let maxDim: CGFloat = 1024
        let scale = min(maxDim / CGFloat(outputCG.width), maxDim / CGFloat(outputCG.height), 1.0)
        let finalW = Int(CGFloat(outputCG.width) * scale)
        let finalH = Int(CGFloat(outputCG.height) * scale)
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: finalW, height: finalH, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return UIImage(cgImage: outputCG)
        }
        context.interpolationQuality = .high
        context.draw(outputCG, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))
        
        guard let scaledCG = context.makeImage() else { return nil }
        return UIImage(cgImage: scaledCG)
    }
}

// Conform value-typed structures explicitly to @unchecked Sendable
extension ArchivedRoom: @unchecked Sendable {}
extension ArchivedSurface: @unchecked Sendable {}
extension ArchivedObject: @unchecked Sendable {}
extension CameraFrameData: @unchecked Sendable {}
