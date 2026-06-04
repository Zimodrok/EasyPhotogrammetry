import SceneKit
import simd
import Foundation
import ModelIO
import SceneKit.ModelIO

/// True geometric mesh cropper using ModelIO.
struct MeshCropper {

    // MARK: - Primary API
    
    /// Loads the USDZ and returns a unified-indexed SCNScene with working materials.
    static func loadUnifiedScene(from url: URL) -> (scene: SCNScene, diffuseMap: CGImage?)? {
        print(" loadUnifiedScene from MDLAsset safely: \(url.lastPathComponent)")
        
        let cleanURL = url.scheme == "file" ? url : URL(fileURLWithPath: url.path)
        
        let asset = MDLAsset(url: cleanURL)
        let scene = SCNScene(mdlAsset: asset)
        
        var diffuseImage: CGImage? = nil
        if let src = SCNSceneSource(url: cleanURL, options: nil),
           let refScene = src.scene(options: nil) {
            copyMaterials(from: refScene, to: scene)
        }
        
        return (scene, diffuseImage)
    }

    /// Loads the USDZ as MDLAsset, filters triangles below `threshold`,
    /// and returns an SCNScene built from the result.
    static func cropSceneFromUSDZ(from url: URL, belowY threshold: Float) -> (scene: SCNScene, diffuseMap: CGImage?, removed: Int)? {
        print(" cropSceneFromUSDZ — threshold=\(threshold)")
        
        let cleanURL = url.scheme == "file" ? url : URL(fileURLWithPath: url.path)
        let asset = MDLAsset(url: cleanURL)
        
        let referenceScene: SCNScene?
        if let src = SCNSceneSource(url: cleanURL, options: nil) {
            referenceScene = src.scene(options: nil)
        } else {
            referenceScene = nil
        }
        
        var totalRemoved = 0
        var meshes: [MDLMesh] = []
        for i in 0..<asset.count {
            collectMeshes(from: asset.object(at: i), into: &meshes)
        }
        print(" Found \(meshes.count) meshes")
        
        for mesh in meshes {
            totalRemoved += filterTriangles(in: mesh, belowY: threshold)
        }
        
        print(" Total removed: \(totalRemoved) triangles")
        guard totalRemoved > 0 else { return nil }
        
        let scene = SCNScene(mdlAsset: asset)
        
        if let ref = referenceScene {
            copyMaterials(from: ref, to: scene)
        }
        
        return (scene, nil, totalRemoved)
    }
    
    // MARK: - Material copying (SCNSceneSource textures → MDL-converted scene)
    
    private static func copyMaterials(from source: SCNScene, to target: SCNScene) {
        var srcNodes: [(name: String?, geo: SCNGeometry)] = []
        var tgtNodes: [SCNNode] = []
        
        source.rootNode.enumerateChildNodes { n, _ in
            if let g = n.geometry { srcNodes.append((n.name, g)) }
        }
        target.rootNode.enumerateChildNodes { n, _ in
            if n.geometry != nil { tgtNodes.append(n) }
        }
        
        for tgtNode in tgtNodes {
            guard let tgtGeo = tgtNode.geometry else { continue }
            let match = srcNodes.first(where: { $0.name == tgtNode.name }) ?? srcNodes.first
            if let src = match {
                
                for mat in src.geo.materials {
                    if let contentStr = mat.diffuse.contents as? String,
                       contentStr.contains("engine:") || contentStr.contains(".rematerial") {
                        mat.diffuse.contents = UIColor.lightGray
                    }
                    mat.lightingModel = .physicallyBased
                }

                if src.geo.materials.count == tgtGeo.elements.count || src.geo.materials.count == 1 {
                    tgtGeo.materials = src.geo.materials
                } else {
                    tgtGeo.materials = Array(repeating: src.geo.materials[0], count: tgtGeo.elements.count)
                }
            }
        }
        print(" Copied materials from reference scene (\(srcNodes.count) src nodes → \(tgtNodes.count) target nodes)")
    }

    // MARK: - Triangle-level removal in MDLMesh submeshes

    @discardableResult
    private static func filterTriangles(in mesh: MDLMesh, belowY threshold: Float) -> Int {
        guard let posAttr = mesh.vertexDescriptor.attributes
                .compactMap({ $0 as? MDLVertexAttribute })
                .first(where: { $0.name == MDLVertexAttributePosition }) else {
            print("  ⚠️ No position attribute")
            return 0
        }

        let bufIdx    = posAttr.bufferIndex
        let posOffset = posAttr.offset
        let posStride = (mesh.vertexDescriptor.layouts[bufIdx] as! MDLVertexBufferLayout).stride
        let vBuf      = mesh.vertexBuffers[bufIdx]
        let posBase   = vBuf.map().bytes
        let vertCount = mesh.vertexCount

        var yValues = [Float](repeating: 0, count: vertCount)
        for v in 0..<vertCount {
            let fp = posBase.advanced(by: posOffset + v * posStride).assumingMemoryBound(to: Float.self)
            yValues[v] = fp[1]
        }

        guard let submeshArray = mesh.submeshes else { return 0 }
        var totalRemoved = 0
        var newSubmeshes: [MDLSubmesh] = []

        for case let submesh as MDLSubmesh in submeshArray {
            let idxMap    = submesh.indexBuffer.map()
            let triCount  = submesh.indexCount / 3
            let isU32     = (submesh.indexType == .uInt32)

            var kept = [UInt32]()
            kept.reserveCapacity(triCount * 3)
            var removed = 0

            for t in 0..<triCount {
                let i0: Int, i1: Int, i2: Int
                if isU32 {
                    let p = idxMap.bytes.assumingMemoryBound(to: UInt32.self)
                    i0 = Int(p[t*3]); i1 = Int(p[t*3+1]); i2 = Int(p[t*3+2])
                } else {
                    let p = idxMap.bytes.assumingMemoryBound(to: UInt16.self)
                    i0 = Int(p[t*3]); i1 = Int(p[t*3+1]); i2 = Int(p[t*3+2])
                }

                let maxY = max(
                    i0 < vertCount ? yValues[i0] : threshold,
                    i1 < vertCount ? yValues[i1] : threshold,
                    i2 < vertCount ? yValues[i2] : threshold
                )

                if maxY >= threshold {
                    kept.append(UInt32(i0)); kept.append(UInt32(i1)); kept.append(UInt32(i2))
                } else {
                    removed += 1
                }
            }
            totalRemoved += removed

            if kept.isEmpty { continue }

            let allocator = MDLMeshBufferDataAllocator()
            let newData   = kept.withUnsafeBytes { Data($0) }
            let newIdxBuf = allocator.newBuffer(with: newData, type: .index)
            let newSub    = MDLSubmesh(
                indexBuffer: newIdxBuf,
                indexCount:  kept.count,
                indexType:   .uInt32,
                geometryType: .triangles,
                material:    submesh.material
            )
            newSubmeshes.append(newSub)
        }

        submeshArray.removeAllObjects()
        for s in newSubmeshes { submeshArray.add(s) }
        return totalRemoved
    }

    private static func collectMeshes(from obj: MDLObject, into meshes: inout [MDLMesh]) {
        if let m = obj as? MDLMesh { meshes.append(m) }
        for child in obj.children.objects.compactMap({ $0 as? MDLObject }) {
            collectMeshes(from: child, into: &meshes)
        }
    }
}
