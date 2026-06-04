import Foundation
import SceneKit
import RoomPlan
import simd
import UIKit
import CoreImage

// MARK: - RoomTextureProjector
// Takes RoomPlan geometry (walls, floor, ceiling) + captured photos with
// known camera poses → projects photo textures onto each surface.
//
// Pipeline:
//  1. Load CapturedRoom surfaces (walls, floor, ceiling)
//  2. For each surface, compute its 4 world-space corners
//  3. For each camera frame, score how well it sees that surface
//  4. Pick the best-scoring frame, crop the visible region, apply as texture
//  5. Export textured room as USDZ
//
// Key coordinate system notes:
//  - ARKit camera: looks along -Z, Y up, X right (right-handed)
//  - ARKit intrinsics are for the AR video feed resolution (frame.imageWidth/Height)
//  - Saved HEIC photos may be at FULL camera resolution (e.g. 4032x3024)
//  - CIImage origin is bottom-left (Y points UP)
//  - UIImage/CGImage origin is top-left (Y points DOWN)
//  - CIPerspectiveCorrection expects CIImage coordinates (bottom-left origin)
final class RoomTextureProjector {

    struct Result {
        let sceneURL: URL
        let texturedSurfaceCount: Int
        let totalSurfaceCount: Int
    }

    // MARK: - Public API

    func projectTextures(
        room: CapturedRoom,
        sessionDirectory: URL,
        outputURL: URL
    ) throws -> Result {
        let depthStore = DepthDataStore(sessionDirectory: sessionDirectory)
        let cameraFrames = depthStore.loadAllCameraData()

        guard !cameraFrames.isEmpty else {
            throw ProjectionError.noCameraData
        }

        print(" RoomTextureProjector: \(cameraFrames.count) camera frames, \(room.walls.count) walls")

        let scene = SCNScene()
        let rootNode = scene.rootNode
        var texturedCount = 0
        var totalCount = 0

        // Walls
        for (i, wall) in room.walls.enumerated() {
            let node = createTexturedSurface(
                label: "wall_\(i)",
                width: CGFloat(wall.dimensions.x),
                height: CGFloat(wall.dimensions.y),
                transform: wall.transform,
                cameraFrames: cameraFrames,
                sessionDirectory: sessionDirectory
            )
            if node.geometry?.firstMaterial?.diffuse.contents is UIImage {
                texturedCount += 1
            }
            rootNode.addChildNode(node)
            totalCount += 1
        }

        // Floor
        for (i, floor) in room.floors.enumerated() {
            let node = createTexturedSurface(
                label: "floor_\(i)",
                width: CGFloat(floor.dimensions.x),
                height: CGFloat(floor.dimensions.y),
                transform: floor.transform,
                cameraFrames: cameraFrames,
                sessionDirectory: sessionDirectory,
                isFloor: true
            )
            rootNode.addChildNode(node)
            totalCount += 1
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

        // Objects (furniture bounding boxes)
        // Removed! The user requested to use the photogrammetry mesh for objects
        // rather than the simple RoomPlan bounding boxes. This prevents the
        // ugly boxes from intersecting the detailed photogrammetry geometry.

        // Export
        let success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
        guard success else {
            throw ProjectionError.exportFailed
        }

        print("✅ RoomTextureProjector: \(texturedCount)/\(totalCount) surfaces textured → \(outputURL.lastPathComponent)")
        return Result(sceneURL: outputURL, texturedSurfaceCount: texturedCount, totalSurfaceCount: totalCount)
    }

    // MARK: - Projection Helpers

    /// Projects a 3D world point into pixel coordinates in the ACTUAL saved image.
    /// Returns nil if the point is behind the camera.
    /// The returned coordinates are in UIImage space (origin top-left, Y down).
    private func projectToPixel(
        worldPoint: SIMD4<Float>,
        viewMatrix: simd_float4x4,
        intrinsics: simd_float3x3,
        arWidth: Int, arHeight: Int,
        imgWidth: CGFloat, imgHeight: CGFloat
    ) -> CGPoint? {
        let camSpace = viewMatrix * worldPoint
        // Point must be in front of the camera (ARKit looks along -Z)
        guard camSpace.z < -0.01 else { return nil }

        // Project using AR intrinsics (for AR video resolution)
        let arPx = intrinsics[0][0] * (-camSpace.x / camSpace.z) + intrinsics[2][0]
        let arPy = intrinsics[1][1] * (-camSpace.y / camSpace.z) + intrinsics[2][1]

        // Scale from AR video resolution to actual saved image resolution
        let scaleX = imgWidth / CGFloat(arWidth)
        let scaleY = imgHeight / CGFloat(arHeight)

        let px = CGFloat(arPx) * scaleX
        let py = CGFloat(arPy) * scaleY

        return CGPoint(x: px, y: py)
    }

    /// Converts UIImage pixel coordinates (top-left origin, Y down)
    /// to CIImage coordinates (bottom-left origin, Y up).
    private func uiToCIPoint(_ pt: CGPoint, imageHeight: CGFloat) -> CGPoint {
        return CGPoint(x: pt.x, y: imageHeight - pt.y)
    }

    // MARK: - Surface Texturing

    private func createTexturedSurface(
        label: String,
        width: CGFloat,
        height: CGFloat,
        transform: simd_float4x4,
        cameraFrames: [CameraFrameData],
        sessionDirectory: URL,
        isFloor: Bool = false
    ) -> SCNNode {
        let plane = SCNPlane(width: width, height: height)
        let node = SCNNode(geometry: plane)
        node.name = label
        node.simdTransform = transform

        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // SCNPlane in SceneKit faces along +Z in local space, so the normal in world space
        // is the Z column of the transform
        let normalPosZ = normalize(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let normalNegZ = -normalPosZ

        // Surface corners in world space (SCNPlane lies in XY plane, facing +Z)
        let hw = Float(width) * 0.5
        let hh = Float(height) * 0.5
        let localCorners: [SIMD4<Float>] = [
            SIMD4(-hw, -hh, 0, 1),  // bottom-left
            SIMD4( hw, -hh, 0, 1),  // bottom-right
            SIMD4( hw,  hh, 0, 1),  // top-right
            SIMD4(-hw,  hh, 0, 1),  // top-left
        ]
        let worldCorners = localCorners.map { transform * $0 }

        // Score each camera frame — try BOTH normals (we don't know which way the plane faces)
        var bestScore: Float = -1
        var bestFrame: CameraFrameData?
        var bestFrameIsBackFace: Bool = false

        for frame in cameraFrames {
            let camTransform = simd_float4x4.fromArray(frame.extrinsics)
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            let camForward = normalize(SIMD3<Float>(-camTransform.columns.2.x, -camTransform.columns.2.y, -camTransform.columns.2.z))

            let toSurface = normalize(center - camPos)
            let facingDot = simd_dot(toSurface, camForward)
            guard facingDot > 0.2 else { continue }

            // Accept if surface faces camera from either side (double-sided)
            let surfaceFacingA = -simd_dot(normalPosZ, toSurface)
            let surfaceFacingB = -simd_dot(normalNegZ, toSurface)
            let surfaceFacing = max(surfaceFacingA, surfaceFacingB)
            guard surfaceFacing > 0.05 else { continue }

            let distance = simd_distance(camPos, center)
            let distScore = 1.0 / (1.0 + distance)

            // Check how many corners project into the image
            let intrinsics = simd_float3x3.fromArray(frame.intrinsics)
            let viewMatrix = simd_inverse(camTransform)
            var inFrameCount = 0

            for corner in worldCorners {
                if let pt = projectToPixel(
                    worldPoint: corner,
                    viewMatrix: viewMatrix,
                    intrinsics: intrinsics,
                    arWidth: frame.imageWidth, arHeight: frame.imageHeight,
                    imgWidth: CGFloat(frame.imageWidth), imgHeight: CGFloat(frame.imageHeight)
                ) {
                    if pt.x >= 0 && pt.x < CGFloat(frame.imageWidth) &&
                       pt.y >= 0 && pt.y < CGFloat(frame.imageHeight) {
                        inFrameCount += 1
                    }
                }
            }

            let coverageFrac = Float(max(1, inFrameCount)) / 4.0
            let score = facingDot * surfaceFacing * distScore * coverageFrac

            if score > bestScore {
                bestScore = score
                bestFrame = frame
                bestFrameIsBackFace = (surfaceFacingB > surfaceFacingA)
            }
        }

        // Apply texture from best frame
        let mat = SCNMaterial()
        mat.isDoubleSided = true

        if let frame = bestFrame,
           let texture = extractTexture(for: worldCorners, from: frame, sessionDirectory: sessionDirectory, isBackFace: bestFrameIsBackFace) {
            mat.diffuse.contents = texture
            mat.lightingModel = .physicallyBased
            print("   \(label): textured from \(frame.imageFilename) (score: \(String(format: "%.3f", bestScore)), backFace: \(bestFrameIsBackFace))")
        } else {
            mat.diffuse.contents = isFloor
                ? UIColor(white: 0.85, alpha: 1.0)
                : UIColor(white: 0.92, alpha: 1.0)
            print("  ⬜ \(label): no good camera frame found")
        }

        plane.materials = [mat]
        return node
    }

    // MARK: - Texture Extraction

    private func extractTexture(
        for worldCorners: [SIMD4<Float>],
        from frame: CameraFrameData,
        sessionDirectory: URL,
        isBackFace: Bool
    ) -> UIImage? {
        let imageURL = sessionDirectory.appendingPathComponent(frame.imageFilename)
        guard let fullImage = UIImage(contentsOfFile: imageURL.path),
              let cgImage = fullImage.cgImage else { return nil }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let intrinsics = simd_float3x3.fromArray(frame.intrinsics)
        let camTransform = simd_float4x4.fromArray(frame.extrinsics)
        let viewMatrix = simd_inverse(camTransform)

        // Project corners into UIImage pixel coordinates (top-left origin)
        var uiPixelPoints: [CGPoint] = []
        for corner in worldCorners {
            if let pt = projectToPixel(
                worldPoint: corner,
                viewMatrix: viewMatrix,
                intrinsics: intrinsics,
                arWidth: frame.imageWidth, arHeight: frame.imageHeight,
                imgWidth: imgW, imgHeight: imgH
            ) {
                let clampedPt = CGPoint(
                    x: min(max(pt.x, 0), imgW - 1),
                    y: min(max(pt.y, 0), imgH - 1)
                )
                uiPixelPoints.append(clampedPt)
            } else {
                // Corner behind camera — use image center as fallback
                uiPixelPoints.append(CGPoint(x: imgW * 0.5, y: imgH * 0.5))
            }
        }

        // Check if the projected quad has reasonable size
        let minX = uiPixelPoints.map(\.x).min()!
        let maxX = uiPixelPoints.map(\.x).max()!
        let minY = uiPixelPoints.map(\.y).min()!
        let maxY = uiPixelPoints.map(\.y).max()!
        guard (maxX - minX) > 10, (maxY - minY) > 10 else { return nil }

        // Convert to CIImage coordinates (bottom-left origin, Y up)
        var ciPoints = uiPixelPoints.map { uiToCIPoint($0, imageHeight: imgH) }
        
        // If the camera is looking at the back face, the spatial order of the corners 
        // in the image is horizontally flipped. We must swap Left and Right to prevent 
        // the resulting texture from being mirrored.
        // Original order: [0]=BL, [1]=BR, [2]=TR, [3]=TL
        if isBackFace {
            ciPoints = [
                ciPoints[1], // BL becomes BR
                ciPoints[0], // BR becomes BL
                ciPoints[3], // TR becomes TL
                ciPoints[2]  // TL becomes TR
            ]
        }

        // CIImage from CGImage (CIImage auto-handles orientation)
        let ciImage = CIImage(cgImage: cgImage)

        // CIPerspectiveCorrection expects: BL, BR, TR, TL in CI coords
        // Our corners: [0]=BL, [1]=BR, [2]=TR, [3]=TL (in 3D local space)
        // After converting to CI space, the "bottom" in 3D (low Y) → low CI Y (still bottom)
        // So the ordering is preserved.
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

        guard let outputCI = filter.outputImage else {
            let cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
            return UIImage(cgImage: cropped)
        }

        let ctx = CIContext()
        guard let outputCG = ctx.createCGImage(outputCI, from: outputCI.extent) else { return nil }

        // Downscale to max 1024px for memory
        let maxDim: CGFloat = 1024
        let scale = min(maxDim / CGFloat(outputCG.width), maxDim / CGFloat(outputCG.height), 1.0)
        let finalW = Int(CGFloat(outputCG.width) * scale)
        let finalH = Int(CGFloat(outputCG.height) * scale)

        UIGraphicsBeginImageContext(CGSize(width: finalW, height: finalH))
        UIImage(cgImage: outputCG).draw(in: CGRect(x: 0, y: 0, width: finalW, height: finalH))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Object Texturing

    private func textureObjectBox(
        node: SCNNode,
        transform: simd_float4x4,
        dimensions: simd_float3,
        cameraFrames: [CameraFrameData],
        sessionDirectory: URL
    ) -> Bool {
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        var bestFrame: CameraFrameData?
        var bestScore: Float = -1

        for frame in cameraFrames {
            let camTransform = simd_float4x4.fromArray(frame.extrinsics)
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            let camForward = normalize(SIMD3<Float>(-camTransform.columns.2.x, -camTransform.columns.2.y, -camTransform.columns.2.z))

            let toObj = normalize(center - camPos)
            let dot = simd_dot(toObj, camForward)
            guard dot > 0.3 else { continue }

            let dist = simd_distance(camPos, center)
            let score = dot / (1.0 + dist)

            if score > bestScore {
                bestScore = score
                bestFrame = frame
            }
        }

        guard let frame = bestFrame else { return false }

        let imageURL = sessionDirectory.appendingPathComponent(frame.imageFilename)
        guard let fullImage = UIImage(contentsOfFile: imageURL.path),
              let cgImage = fullImage.cgImage else { return false }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let intrinsics = simd_float3x3.fromArray(frame.intrinsics)
        let camTransform = simd_float4x4.fromArray(frame.extrinsics)
        let viewMatrix = simd_inverse(camTransform)

        // Project center into actual image pixel coordinates
        guard let centerPx = projectToPixel(
            worldPoint: SIMD4<Float>(center.x, center.y, center.z, 1),
            viewMatrix: viewMatrix,
            intrinsics: intrinsics,
            arWidth: frame.imageWidth, arHeight: frame.imageHeight,
            imgWidth: imgW, imgHeight: imgH
        ) else { return false }

        // Estimate object's pixel size based on distance and focal length
        let dist = simd_distance(
            SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z),
            center
        )
        let objSize = max(dimensions.x, dimensions.y)
        let focalScaled = CGFloat(intrinsics[0][0]) * (imgW / CGFloat(frame.imageWidth))
        let pixelSize = focalScaled * CGFloat(objSize) / CGFloat(max(dist, 0.1))
        let halfPx = max(pixelSize * 0.6, 50)

        let cropRect = CGRect(
            x: max(0, centerPx.x - halfPx),
            y: max(0, centerPx.y - halfPx),
            width: min(halfPx * 2, imgW),
            height: min(halfPx * 2, imgH)
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard cropRect.width > 20, cropRect.height > 20,
              let cropped = cgImage.cropping(to: cropRect) else { return false }

        let texture: UIImage? = UIImage(cgImage: cropped)
        guard let textureImage = texture else {
            return false 
        }
        let mat = SCNMaterial()
        mat.diffuse.contents = textureImage
        mat.isDoubleSided = true
        mat.lightingModel = .physicallyBased
        node.geometry?.materials = Array(repeating: mat, count: 6)

        return true
    }

    // MARK: - Errors

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
}
