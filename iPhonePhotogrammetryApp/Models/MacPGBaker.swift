import Foundation
import SceneKit
import simd

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - MacPGBaker
//
// Bakes textures from an already-aligned photogrammetry SCNNode onto flat
// RoomPlan planes using an offscreen orthographic SCNRenderer.
//
// Algorithm (per surface):
//  1. Position a virtual orthographic camera directly in front of the plane
//     (along the plane's outward normal), far enough back to frame the whole surface.
//  2. Set the camera's projection width/height to exactly the wall dimensions.
//  3. Render the PG scene (which is already in the same ARKit coordinate space)
//     into a CGImage via SCNRenderer.
//  4. Apply that image as the diffuse texture on the RoomPlan SCNBox node.
//
// Result: perfectly flat walls with photorealistic textures sampled directly
//         from the photogrammetry model — no vertex manipulation, no seam tears.
final class MacPGBaker {

    #if os(macOS)
    typealias PlatformColor = NSColor
    typealias PlatformImage = NSImage
    #else
    typealias PlatformColor = UIColor
    typealias PlatformImage = UIImage
    #endif

    // Resolution in px per metre — 256 gives ~0.4cm/px at 1m wall width
    static let texelsPerMetre: Float = 512

    static let bgColor = PlatformColor(white: 0.93, alpha: 1.0) // fallback if PG doesn't cover

    // Public entry point

    /// Renders the PG mesh onto every surface node and returns them.
    ///
    /// - Parameters:
    ///   - surfaces:    Array of `(node, planeTransform, widthMetres, heightMetres, isFloor)`.
    ///   - pgRootNode:  The photogrammetry root node already positioned in ARKit space
    ///                  (i.e. `pgWrapper` after `simdTransform = exactTransform` was applied).
    ///   - alignTransform: The exact 4×4 that was baked into pgRootNode — used to convert
    ///                     positions from PG-model space to ARKit world space.
    static func bakeAll(
        surfaces: [(node: SCNNode,
                    transform: simd_float4x4,
                    width: Float,
                    height: Float,
                    isFloor: Bool)],
        pgRootNode: SCNNode,
        alignTransform: simd_float4x4
    ) {
        // Build a temporary scene that holds just the PG mesh for rendering.
        // We do NOT add the RoomPlan shell here — only the PG geometry.
        let pgScene = SCNScene()
        // Clone the wrapper so we don't disturb the original.
        let pgClone = pgRootNode.clone()
        pgScene.rootNode.addChildNode(pgClone)

        // Ambient light so every surface is visible during bake
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 2000
        ambient.light!.color = PlatformColor.white
        pgScene.rootNode.addChildNode(ambient)

        // The SCNRenderer renders into a Metal-backed pixel buffer
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ MacPGBaker: no Metal device, skipping bake")
            return
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = pgScene

        var bakedCount = 0

        for surface in surfaces {
            autoreleasepool {
                // 1. Derive camera placement
                let T = surface.transform                        // RoomPlan world space
                let w = surface.width, h = surface.height

                // Normal: Z column of the surface transform
                let rawNormal = SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)
                let nLen = simd_length(rawNormal)
                guard nLen > 1e-6 else { return }
                let normal = rawNormal / nLen

                // Surface centre
                let centre = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)

                // Pull camera back from the wall far enough to see everything
                let pullback: Float = max(w, h) * 2.0 + 0.5
                let camPos   = centre + normal * pullback

                // 2. Build camera transform matrix for SCNCamera
                // Camera looks along -Z in SceneKit space.
                // We want the camera's -Z to equal the surface's -normal (look from outside in).
                let lookDir = -normal           // camera looks toward the wall
                let worldUp = surface.isFloor ? SIMD3<Float>(0, 0, -1) : SIMD3<Float>(0, 1, 0)
                let rightDir = simd_normalize(simd_cross(lookDir, worldUp))
                let upDir    = simd_normalize(simd_cross(rightDir, lookDir))

                // Columns: right, up, -lookDir, translation  (SceneKit: col-major)
                var camMatrix = simd_float4x4(
                    SIMD4<Float>( rightDir.x,  rightDir.y,  rightDir.z, 0),
                    SIMD4<Float>( upDir.x,      upDir.y,      upDir.z,    0),
                    SIMD4<Float>(-lookDir.x,   -lookDir.y,   -lookDir.z,  0),
                    SIMD4<Float>( camPos.x,     camPos.y,     camPos.z,    1)
                )

                let camNode = SCNNode()
                camNode.simdTransform = camMatrix

                let cam = SCNCamera()
                cam.usesOrthographicProjection = true
                cam.orthographicScale = Double(max(w, h) / 2.0) * 1.02  // tiny 2% margin
                // KEY: Restrict depth range to only capture geometry near the wall surface.
                // Camera is at `pullback` from the wall. So the wall surface is at depth = pullback.
                //   zNear = pullback - 0.05  → 5cm in front of the wall (toward camera)
                //   zFar  = pullback + 0.25  → 25cm behind wall surface (into the room)
                // This clips away ALL furniture and opposite walls (>30cm from the wall).
                cam.zNear = Double(max(0.01, pullback - 0.05))
                cam.zFar  = Double(pullback + 0.25)
                camNode.camera = cam

                // Remove any previous test camera
                pgScene.rootNode.childNodes
                    .filter { $0.name == "__bake_cam__" }
                    .forEach { $0.removeFromParentNode() }
                camNode.name = "__bake_cam__"
                pgScene.rootNode.addChildNode(camNode)
                renderer.pointOfView = camNode

                // 3. Compute output image size (clamped to 2k max)
                let maxPx = 2048
                let rawW = Int(w * texelsPerMetre)
                let rawH = Int(h * texelsPerMetre)
                let texW = min(rawW, maxPx)
                let texH = min(rawH, maxPx)

                // 4. Render
                let renderRect = CGRect(x: 0, y: 0, width: texW, height: texH)
                #if os(macOS)
                let cgImg: CGImage
                do {
                    guard let snapshot = try? renderer.snapshot(atTime: 0,
                                                               with: renderRect.size,
                                                               antialiasingMode: .multisampling4X)
                    else {
                        applyFallback(to: surface.node, isFloor: surface.isFloor)
                        return
                    }
                    guard let cgRep = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        applyFallback(to: surface.node, isFloor: surface.isFloor)
                        return
                    }
                    cgImg = cgRep
                }
                let textureImage = PlatformImage(cgImage: cgImg, size: renderRect.size)
                #else
                guard let snapshot = try? renderer.snapshot(atTime: 0,
                                                           with: renderRect.size,
                                                           antialiasingMode: .multisampling4X)
                else {
                    applyFallback(to: surface.node, isFloor: surface.isFloor)
                    return
                }
                let textureImage = snapshot
                #endif

                // 5. Apply to surface
                let mat = SCNMaterial()
                mat.diffuse.contents = textureImage
                mat.lightingModel   = .constant   // unlit — the bake already has light baked in
                mat.isDoubleSided   = true
                surface.node.geometry?.materials = [mat]

                bakedCount += 1
                print(" Baked \(surface.isFloor ? "floor" : "wall") \(Int(w * 100))×\(Int(h * 100))cm → \(texW)×\(texH)px")
            }
        }

        print("✅ MacPGBaker: \(bakedCount)/\(surfaces.count) surfaces baked")
    }

    private static func applyFallback(to node: SCNNode, isFloor: Bool) {
        let mat = SCNMaterial()
        mat.diffuse.contents  = isFloor ? PlatformColor(white: 0.85, alpha: 1) : PlatformColor(white: 0.93, alpha: 1)
        mat.lightingModel     = .constant
        mat.isDoubleSided     = true
        node.geometry?.materials = [mat]
    }
}
