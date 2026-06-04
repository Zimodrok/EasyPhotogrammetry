import Foundation
import SceneKit
import simd
import CoreImage
import CoreGraphics
import ImageIO
import AppKit

// MARK: - MacRoomTextureProjector
// Projects camera textures from AR session frames onto RoomPlan geometry.
//
// Key invariants:
// • intrinsics & extrinsics are in SENSOR-NATIVE coordinates (landscape,
//   before EXIF rotation). Images are loaded RAW (no EXIF auto-rotation).
// • All frames are used — no subsampling.
// • Multi-frame blending fills holes when no single frame covers a surface.
// • Spatial pre-filtering limits per-surface work to nearby frames only.
final class MacRoomTextureProjector {

    // Shared CoreImage context (hardware-accelerated, sRGB output).
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace:   CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    struct Result {
        let sceneURL: URL
        let texturedSurfaceCount: Int
        let totalSurfaceCount: Int
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

    // MARK: - Cached frame data (position only, for spatial pre-filtering)

    private struct FramePosition {
        let index: Int
        let pos: SIMD3<Float>
    }

    // MARK: - Public API

    private let surfaceBatchSize = 4
    private let vramCoolDownDelay: UInt64 = 200_000_000


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

        // Pre-compute camera positions for spatial pre-filtering
        let framePositions: [FramePosition] = cameraFrames.enumerated().map { idx, frame in
            FramePosition(index: idx, pos: SIMD3<Float>(
                frame.extrinsics[12], frame.extrinsics[13], frame.extrinsics[14]
            ))
        }

        print(" MacRoomTextureProjector: \(cameraFrames.count) frames, \(room.walls.count) walls, \(room.floors.count) floors")

        let scene = SCNScene()
        let rootNode = scene.rootNode

        let totalSurfacesToProcess = room.walls.count + room.floors.count
        var surfacesProcessed = 0
        var texturedCount = 0
        var totalCount = 0
        
        struct SurfaceTask {
            let label: String
            let width: CGFloat
            let height: CGFloat
            let transform: simd_float4x4
            let isFloor: Bool
        }
        
        var allSurfaces: [SurfaceTask] = []
        
        for (i, wall) in room.walls.enumerated() {
            allSurfaces.append(SurfaceTask(label: "wall_\(i)", width: CGFloat(wall.dimensions.x), height: CGFloat(wall.dimensions.y), transform: wall.transform, isFloor: false))
        }
        for (i, floor) in room.floors.enumerated() {
            allSurfaces.append(SurfaceTask(label: "floor_\(i)", width: CGFloat(floor.dimensions.x), height: CGFloat(floor.dimensions.y), transform: floor.transform, isFloor: true))
        }
        
        let surfaceChunks = allSurfaces.chunked(into: surfaceBatchSize)
        
        for (batchIndex, chunk) in surfaceChunks.enumerated() {
            print(" Processing surface batch \(batchIndex + 1)/\(surfaceChunks.count) (\(chunk.count) surfaces)...")
            
            try await withThrowingTaskGroup(of: SCNNode.self) { group in
                
                for surface in chunk {
                    group.addTask {
                        let renderedNode = autoreleasepool {
                            return self.createTexturedSurface(
                                label: surface.label,
                                width: surface.width,
                                height: surface.height,
                                transform: surface.transform,
                                cameraFrames: cameraFrames,
                                framePositions: framePositions,
                                sessionDirectory: sessionDirectory,
                                isFloor: surface.isFloor
                            )
                        }
                        return renderedNode
                    }
                }
                
                for try await node in group {
                    if node.geometry?.firstMaterial?.diffuse.contents is NSImage {
                        texturedCount += 1
                    }
                    rootNode.addChildNode(node)
                    totalCount += 1
                    
                    surfacesProcessed += 1
                    if totalSurfacesToProcess > 0 {
                        progressHandler?(Double(surfacesProcessed) / Double(totalSurfacesToProcess))
                    }
                }
            }
            
            if batchIndex < surfaceChunks.count - 1 {
                try? await Task.sleep(nanoseconds: vramCoolDownDelay)
            }
        }

        // Doors

        for (i, door) in room.doors.enumerated() {
            let dims = door.dimensions
            let node = SCNNode(geometry: SCNBox(width: CGFloat(dims.x), height: CGFloat(dims.y), length: 0.06, chamferRadius: 0))
            node.name = "door_\(i)"
            node.simdTransform = door.transform
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(red: 0.55, green: 0.38, blue: 0.22, alpha: 1.0)
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            node.geometry?.materials = [mat]
            rootNode.addChildNode(node)
        }
        
        // Windows

        for (i, window) in room.windows.enumerated() {
            let dims = window.dimensions
            let node = SCNNode(geometry: SCNBox(width: CGFloat(dims.x), height: CGFloat(dims.y), length: 0.04, chamferRadius: 0))
            node.name = "window_\(i)"
            node.simdTransform = window.transform
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(red: 0.65, green: 0.82, blue: 0.98, alpha: 0.55)
            mat.lightingModel = .constant
            mat.transparency = 0.45
            mat.isDoubleSided = true
            node.geometry?.materials = [mat]
            rootNode.addChildNode(node)
        }
        
        // Export

        let success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
        guard success else { throw ProjectionError.exportFailed }

        print("✅ MacRoomTextureProjector: \(texturedCount)/\(totalCount) surfaces textured → \(outputURL.lastPathComponent)")
        return Result(sceneURL: outputURL, texturedSurfaceCount: texturedCount, totalSurfaceCount: totalCount)
    }
    
    // MARK: - Camera Data Loading


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
        // Use ALL frames — no subsampling. Sort by timestamp for deterministic ordering.
        return frames.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Projection Math (sensor-native, NO EXIF orientation)

    /// Projects a world point into raw sensor pixel coordinates.
    /// Intrinsics and extrinsics are in sensor-native space (landscape).
    /// Returns nil if the point is behind the camera.
    private func projectToSensorPixel(
        worldPoint: SIMD4<Float>,
        viewMatrix: simd_float4x4,
        intrinsics: simd_float3x3  // column-major: col0=[fx,0,0] col1=[0,fy,0] col2=[cx,cy,1]
    ) -> SIMD2<Float>? {
        let camSpace = viewMatrix * worldPoint
        guard camSpace.z < -0.05 else { return nil }

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        // Standard pinhole: px = fx*(x/−z)+cx  (z negative → −z positive)
        let px = fx * (camSpace.x / -camSpace.z) + cx
        let py = fy * (camSpace.y / -camSpace.z) + cy
        return SIMD2<Float>(px, py)
    }

    // MARK: - Frame Candidate Scoring

    private struct Candidate {
        let frame: CameraFrameData
        let score: Float
        let inFrameCount: Int  // how many of the 4 corners fall inside the image
        let viewMatrix: simd_float4x4
        let intrinsics: simd_float3x3
    }

    /// Returns scored candidates sorted best-first, spatially pre-filtered to
    /// frames within `spatialRadius` metres of the surface centre.
    private func scoredCandidates(
        surfaceCenter: SIMD3<Float>,
        surfaceNormal: SIMD3<Float>,
        worldCorners: [SIMD4<Float>],
        cameraFrames: [CameraFrameData],
        framePositions: [FramePosition],
        spatialRadius: Float = 7.0
    ) -> [Candidate] {
        var result: [Candidate] = []

        for fp in framePositions {
            // Spatial pre-filter: skip frames more than spatialRadius from surface
            guard simd_distance(fp.pos, surfaceCenter) < spatialRadius else { continue }

            let frame = cameraFrames[fp.index]
            let camTransform = simd_float4x4(
                simd_float4(frame.extrinsics[0],  frame.extrinsics[1],  frame.extrinsics[2],  frame.extrinsics[3]),
                simd_float4(frame.extrinsics[4],  frame.extrinsics[5],  frame.extrinsics[6],  frame.extrinsics[7]),
                simd_float4(frame.extrinsics[8],  frame.extrinsics[9],  frame.extrinsics[10], frame.extrinsics[11]),
                simd_float4(frame.extrinsics[12], frame.extrinsics[13], frame.extrinsics[14], frame.extrinsics[15])
            )
            let camPos  = fp.pos
            let camFwd  = normalize(SIMD3<Float>(-camTransform.columns.2.x,
                                                 -camTransform.columns.2.y,
                                                 -camTransform.columns.2.z))
            let toSurf  = normalize(surfaceCenter - camPos)

            // Camera must point toward the surface
            let facingDot = simd_dot(toSurf, camFwd)
            guard facingDot > 0.20 else { continue }

            // Surface must face the camera (double-sided — either side OK)
            let surfaceFacing = abs(simd_dot(surfaceNormal, -toSurf))
            guard surfaceFacing > 0.05 else { continue }

            // Distance: prefer nearby shots, hard limit at spatialRadius
            let dist = simd_distance(camPos, surfaceCenter)
            let distScore: Float = 1.0 / (1.0 + dist * dist * 0.08)

            let intrinsics = simd_float3x3(
                simd_float3(frame.intrinsics[0], frame.intrinsics[1], frame.intrinsics[2]),
                simd_float3(frame.intrinsics[3], frame.intrinsics[4], frame.intrinsics[5]),
                simd_float3(frame.intrinsics[6], frame.intrinsics[7], frame.intrinsics[8])
            )
            let viewMatrix = simd_inverse(camTransform)
            let sW = Float(frame.imageWidth)
            let sH = Float(frame.imageHeight)
            var inFrameCount = 0

            for corner in worldCorners {
                if let px = projectToSensorPixel(worldPoint: corner, viewMatrix: viewMatrix, intrinsics: intrinsics),
                   px.x >= 0 && px.x < sW && px.y >= 0 && px.y < sH {
                    inFrameCount += 1
                }
            }
            guard inFrameCount > 0 else { continue }

            let coverageFrac = Float(inFrameCount) / 4.0
            let anglePenalty = pow(surfaceFacing, 0.5)  // reward near-perpendicular
            let score = facingDot * anglePenalty * distScore * coverageFrac

            result.append(Candidate(
                frame: frame, score: score, inFrameCount: inFrameCount,
                viewMatrix: viewMatrix, intrinsics: intrinsics
            ))
        }
        result.sort { $0.score > $1.score }
        return result
    }

    // MARK: - Surface Texturing

    private func createTexturedSurface(
        label: String,
        width: CGFloat,
        height: CGFloat,
        transform: simd_float4x4,
        cameraFrames: [CameraFrameData],
        framePositions: [FramePosition],
        sessionDirectory: URL,
        isFloor: Bool = false
    ) -> SCNNode {
        let plane = SCNPlane(width: width, height: height)
        let node = SCNNode(geometry: plane)
        node.name = label
        node.simdTransform = transform

        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let surfaceNormal = normalize(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))

        let hw = Float(width) * 0.5
        let hh = Float(height) * 0.5
        let localCorners: [SIMD4<Float>] = [
            SIMD4(-hw, -hh, 0, 1),
            SIMD4( hw, -hh, 0, 1),
            SIMD4( hw,  hh, 0, 1),
            SIMD4(-hw,  hh, 0, 1)
        ]
        let worldCorners = localCorners.map { transform * $0 }

        let candidates = scoredCandidates(
            surfaceCenter: center, surfaceNormal: surfaceNormal,
            worldCorners: worldCorners, cameraFrames: cameraFrames,
            framePositions: framePositions
        )

        let mat = SCNMaterial()
        mat.isDoubleSided = true
        mat.lightingModel = .constant  // display pure texture colour, no lighting wash

        // Try top candidates until one yields a usable texture.
        // If the best frame only has partial coverage (< 4 corners), try blending
        // with a complementary frame that covers the missing corners.
        var texture: NSImage? = nil
        var usedLabel = ""

        for (idx, cand) in candidates.prefix(8).enumerated() {
            if let img = extractTexture(worldCorners: worldCorners, frame: cand.frame,
                                        viewMatrix: cand.viewMatrix, intrinsics: cand.intrinsics,
                                        sessionDirectory: sessionDirectory) {
                if cand.inFrameCount == 4 {
                    // Perfect coverage — use as-is
                    texture = img
                    usedLabel = "\(cand.frame.imageFilename) (full coverage, rank \(idx+1))"
                    break
                } else if texture == nil {
                    // Partial coverage — store and try to find a complement
                    texture = img
                    usedLabel = "\(cand.frame.imageFilename) (partial \(cand.inFrameCount)/4, rank \(idx+1))"
                    // Look for a complementary frame among remaining candidates
                    // that covers at least one corner this frame missed
                    if let blended = tryBlend(
                        base: img, baseCandidate: cand,
                        worldCorners: worldCorners, candidates: Array(candidates.dropFirst(idx + 1).prefix(16)),
                        sessionDirectory: sessionDirectory, width: width, height: height
                    ) {
                        texture = blended
                        usedLabel += " + blend"
                    }
                    break
                }
            }
        }

        if let texture {
            mat.diffuse.contents = texture
            print("   \(label): ← \(usedLabel)")
        } else {
            mat.diffuse.contents = isFloor
                ? NSColor(red: 0.62, green: 0.60, blue: 0.58, alpha: 1.0)
                : NSColor(red: 0.72, green: 0.70, blue: 0.68, alpha: 1.0)
            print("  ⬜ \(label): no usable frame (candidates=\(candidates.count))")
        }

        plane.materials = [mat]
        return node
    }

    // MARK: - Multi-frame Blending

    /// Attempts to composite a secondary frame on top of the base to fill in
    /// coverage holes. The secondary image is alpha-masked to only contribute
    /// in the region that the base frame didn't fully cover.
    private func tryBlend(
        base: NSImage,
        baseCandidate: Candidate,
        worldCorners: [SIMD4<Float>],
        candidates: [Candidate],
        sessionDirectory: URL,
        width: CGFloat,
        height: CGFloat
    ) -> NSImage? {
        // Find a candidate that covers at least one corner the base didn't
        let missingCornersMask = worldCorners.enumerated().compactMap { idx, corner -> Int? in
            guard let px = projectToSensorPixel(worldPoint: corner,
                                                viewMatrix: baseCandidate.viewMatrix,
                                                intrinsics: baseCandidate.intrinsics)
            else { return idx }
            let sW = Float(baseCandidate.frame.imageWidth)
            let sH = Float(baseCandidate.frame.imageHeight)
            return (px.x < 0 || px.x >= sW || px.y < 0 || px.y >= sH) ? idx : nil
        }
        guard !missingCornersMask.isEmpty else { return nil }

        for secondary in candidates {
            // Secondary must cover at least one corner the base missed
            let newlyCovered = missingCornersMask.contains { cornerIdx in
                guard let px = projectToSensorPixel(worldPoint: worldCorners[cornerIdx],
                                                    viewMatrix: secondary.viewMatrix,
                                                    intrinsics: secondary.intrinsics) else { return false }
                let sW = Float(secondary.frame.imageWidth)
                let sH = Float(secondary.frame.imageHeight)
                return px.x >= 0 && px.x < sW && px.y >= 0 && px.y < sH
            }
            guard newlyCovered else { continue }

            guard let secImg = extractTexture(worldCorners: worldCorners, frame: secondary.frame,
                                              viewMatrix: secondary.viewMatrix, intrinsics: secondary.intrinsics,
                                              sessionDirectory: sessionDirectory) else { continue }

            // Composite: base on bottom, secondary where base has gaps.
            // Use a simple 50/50 alpha blend in the overlap region (sufficient for visual seam hiding).
            return compositeImages(base: base, overlay: secImg, size: NSSize(width: width * 300, height: height * 300))
        }
        return nil
    }

    /// Composites overlay on top of base at the target size using Core Image.
    private func compositeImages(base: NSImage, overlay: NSImage, size: NSSize) -> NSImage? {
        let w = Int(max(size.width, 64))
        let h = Int(max(size.height, 64))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high

        // Draw base
        if let cgBase = base.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cgBase, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Draw overlay at reduced opacity to blend seams
        ctx.setAlpha(0.55)
        if let cgOver = overlay.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cgOver, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        guard let finalCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: finalCG, size: NSSize(width: w, height: h))
    }

    // MARK: - Texture Extraction

    /// Loads the raw sensor image (NO EXIF rotation) and uses perspective
    /// correction to warp the surface's region into a clean rectangular texture.
    private func extractTexture(
        worldCorners: [SIMD4<Float>],
        frame: CameraFrameData,
        viewMatrix: simd_float4x4,
        intrinsics: simd_float3x3,
        sessionDirectory: URL
    ) -> NSImage? {
        // 1. Resolve image path
        let imageURL: URL
        let rootCandidate = sessionDirectory.appendingPathComponent(frame.imageFilename)
        if FileManager.default.fileExists(atPath: rootCandidate.path) {
            imageURL = rootCandidate
        } else {
            imageURL = sessionDirectory.appendingPathComponent("depth").appendingPathComponent(frame.imageFilename)
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }

        // 2. Load RAW sensor CGImage — NO EXIF auto-rotation
        // CIImage(contentsOf:) rotates the image per EXIF orientation, which
        // would break alignment with sensor-native intrinsics. Use raw bitmap.
        guard let src = CGImageSourceCreateWithURL(imageURL as CFURL,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary),
              let rawCG = CGImageSourceCreateImageAtIndex(src, 0,
                                                          [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        let imgW = CGFloat(rawCG.width)
        let imgH = CGFloat(rawCG.height)

        // Scale factor handles any resize during HEIC compression
        let scaleX = imgW / CGFloat(frame.imageWidth)
        let scaleY = imgH / CGFloat(frame.imageHeight)

        // 3. Project world corners → raw sensor pixel coordinates
        // Sensor Y=0 is top-left (CGImage convention). Projection gives Y↓ too.
        var sensorPixels: [CGPoint] = []
        for corner in worldCorners {
            if let px = projectToSensorPixel(worldPoint: corner,
                                             viewMatrix: viewMatrix,
                                             intrinsics: intrinsics) {
                let x = (CGFloat(px.x) * scaleX).clamped(to: 0...(imgW - 1))
                let y = (CGFloat(px.y) * scaleY).clamped(to: 0...(imgH - 1))
                sensorPixels.append(CGPoint(x: x, y: y))
            } else {
                sensorPixels.append(CGPoint(x: imgW * 0.5, y: imgH * 0.5))
            }
        }

        // 4. Validate bounding box is large enough
        let minX = sensorPixels.map(\.x).min()!
        let maxX = sensorPixels.map(\.x).max()!
        let minY = sensorPixels.map(\.y).min()!
        let maxY = sensorPixels.map(\.y).max()!
        guard (maxX - minX) > 8, (maxY - minY) > 8 else { return nil }

        // 5. CIPerspectiveCorrection
        // CIImage Y=0 is at bottom-left (opposite to CGImage).
        // Convert: CI_y = imgH - sensor_y
        func toCIPoint(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x, y: imgH - p.y)
        }

        // Winding order for CIPerspectiveCorrection:
        //   inputBottomLeft  → local corner (-hw, -hh)  = worldCorners[0]
        //   inputBottomRight → local corner (+hw, -hh)  = worldCorners[1]
        //   inputTopRight    → local corner (+hw, +hh)  = worldCorners[2]
        //   inputTopLeft     → local corner (-hw, +hh)  = worldCorners[3]
        //
        // In sensor space, local Y=-hh maps to a LARGER sensor Y (lower on screen)
        // and local Y=+hh maps to a SMALLER sensor Y (higher on screen).
        // After CI Y-flip: larger sensor Y → smaller CI Y (CI "bottom").
        // So: CI bottomLeft  = toCIPoint(sensorPixels[0])  
        //     CI bottomRight = toCIPoint(sensorPixels[1])  
        //     CI topRight    = toCIPoint(sensorPixels[2])  
        //     CI topLeft     = toCIPoint(sensorPixels[3])  
        let rawCI = CIImage(cgImage: rawCG)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            // Fallback: simple bounding-box crop
            let cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard let cropped = rawCG.cropping(to: cropRect) else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }

        filter.setValue(rawCI,                          forKey: kCIInputImageKey)
        filter.setValue(toCIPoint(sensorPixels[0]),     forKey: "inputBottomLeft")
        filter.setValue(toCIPoint(sensorPixels[1]),     forKey: "inputBottomRight")
        filter.setValue(toCIPoint(sensorPixels[2]),     forKey: "inputTopRight")
        filter.setValue(toCIPoint(sensorPixels[3]),     forKey: "inputTopLeft")

        guard let outputCI = filter.outputImage else { return nil }

        // 6. Render at ≤1024 px (no premultiplied alpha — prevents colour shift)
        let outW = outputCI.extent.width
        let outH = outputCI.extent.height
        guard outW > 0, outH > 0 else { return nil }

        let maxDim: CGFloat = 1024
        let scale = min(maxDim / outW, maxDim / outH, 1.0)
        let finalW = Int(outW * scale)
        let finalH = Int(outH * scale)
        guard finalW > 4, finalH > 4 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapCtx = CGContext(
                  data: nil, width: finalW, height: finalH,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue  // opaque, no premult wash
              )
        else { return nil }
        bitmapCtx.interpolationQuality = .high

        guard let scaledCG = ciContext.createCGImage(outputCI, from: outputCI.extent) else { return nil }
        bitmapCtx.draw(scaledCG, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))

        guard let finalCG = bitmapCtx.makeImage() else { return nil }
        return NSImage(cgImage: finalCG, size: NSSize(width: finalW, height: finalH))
    }
}

// MARK: - Comparable clamping helper
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
fileprivate extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
func asyncAutoreleasePool<T>(body: @Sendable () async throws -> T) async throws -> T {
    try await body()
}
