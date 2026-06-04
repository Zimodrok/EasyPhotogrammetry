import Foundation
import SceneKit
import SceneKit.ModelIO
import ModelIO
import simd

// MARK: - MacSpatialSnapper
//
// Purely spatial vertex snapping. Does not use topology (indices), which means
// UV seam vertices that occupy the exact same spatial location will receive
// the exact same mathematical translation. This guarantees seams will not rip.
class MacSpatialSnapper {
    
    struct Plane {
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var halfWidth: Float
        var halfHeight: Float
        var isFloor: Bool
    }
    
    static func snap(
        rootNode: SCNNode,
        alignTransform: simd_float4x4,
        room: ArchivedRoom
    ) {
        var planes: [Plane] = []
        
        for w in room.walls {
            let t = w.transform
            planes.append(Plane(
                center: SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                normal: SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z),
                right: SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                up: SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                halfWidth: w.dimensions.x * 0.5,
                halfHeight: w.dimensions.y * 0.5,
                isFloor: false
            ))
        }
        for f in room.floors {
            let t = f.transform
            planes.append(Plane(
                center: SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                normal: SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z),
                right: SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                up: SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                halfWidth: f.dimensions.x * 0.5,
                halfHeight: f.dimensions.y * 0.5,
                isFloor: true
            ))
        }
        
        var snappedCount = 0
        var totalCount = 0
        
        rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let originalMaterials = geometry.materials
            
            // Convert to MDLMesh for safe buffer manipulation (Proven to not crash scene.write)
            let mdlMesh = MDLMesh(scnGeometry: geometry)
            guard let vertexAttr = mdlMesh.vertexDescriptor.attributeNamed(MDLVertexAttributePosition) as? MDLVertexAttribute else { return }
            
            let bufferIndex = vertexAttr.bufferIndex
            guard bufferIndex < mdlMesh.vertexBuffers.count else { return }
            
            let buffer = mdlMesh.vertexBuffers[bufferIndex]
            let map = buffer.map()
            let bytes = map.bytes
            
            guard let layout = mdlMesh.vertexDescriptor.layouts[bufferIndex] as? MDLVertexBufferLayout else { return }
            let stride = layout.stride
            let offset = vertexAttr.offset
            
            let vcount = mdlMesh.vertexCount
            
            var wt = alignTransform
            var curr: SCNNode? = node
            var localTransforms: [simd_float4x4] = []
            while let c = curr, c != rootNode {
                localTransforms.append(c.simdTransform)
                curr = c.parent
            }
            for t in localTransforms.reversed() {
                wt = wt * t
            }
            let invWt = simd_inverse(wt)
            
            for i in 0..<vcount {
                totalCount += 1
                let ptr = bytes.advanced(by: i * stride + offset).assumingMemoryBound(to: Float.self)
                
                let localPt = SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1.0)
                let worldPt4 = wt * localPt
                let worldPt = SIMD3<Float>(worldPt4.x, worldPt4.y, worldPt4.z)
                
                var bestPlane: Plane? = nil
                var bestDist: Float = 0.12
                var bestProj = worldPt
                
                for p in planes {
                    let toPt = worldPt - p.center
                    let distToPlane = simd_dot(toPt, p.normal)
                    let absDist = abs(distToPlane)
                    
                    if absDist < bestDist {
                        let projPt = worldPt - p.normal * distToPlane
                        let toProj = projPt - p.center
                        
                        let dx = simd_dot(toProj, p.right)
                        let dy = simd_dot(toProj, p.up)
                        
                        if abs(dx) <= p.halfWidth + 0.05 && abs(dy) <= p.halfHeight + 0.05 {
                            bestDist = absDist
                            bestPlane = p
                            bestProj = projPt
                        }
                    }
                }
                
                if let _ = bestPlane {
                    let snapZone: Float = 0.02
                    let fadeZone: Float = 0.12
                    
                    let weight: Float
                    if bestDist <= snapZone {
                        weight = 1.0
                    } else {
                        let t = (bestDist - snapZone) / (fadeZone - snapZone)
                        let s = t * t * (3.0 - 2.0 * t)
                        weight = 1.0 - s
                    }
                    
                    let finalWorldPt = simd_mix(worldPt, bestProj, SIMD3<Float>(repeating: weight))
                    
                    // Anti-Warping Displacement Cap: Limit maximum vertex shift to 1.5 cm
                    var delta = finalWorldPt - worldPt
                    let displacement = simd_length(delta)
                    let maxDisplacement: Float = 0.015
                    if displacement > maxDisplacement {
                        delta = (delta / displacement) * maxDisplacement
                    }
                    let cappedWorldPt = worldPt + delta
                    
                    let finalLocalPt4 = invWt * SIMD4<Float>(cappedWorldPt.x, cappedWorldPt.y, cappedWorldPt.z, 1.0)
                    
                    ptr[0] = finalLocalPt4.x
                    ptr[1] = finalLocalPt4.y
                    ptr[2] = finalLocalPt4.z
                    
                    if weight > 0 { snappedCount += 1 }
                }
            }
            
            // Generate Tangents! Without these, PBR Normal maps break and look "smoky/noisy".
            mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            mdlMesh.addTangentBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                                    tangentAttributeNamed: MDLVertexAttributeTangent,
                                    bitangentAttributeNamed: MDLVertexAttributeBitangent)
            
            // Convert safely back to SceneKit
            let newGeo = SCNGeometry(mdlMesh: mdlMesh)
            
            // MDLMesh reorders submeshes. We cannot blindly do `newGeo.materials = originalMaterials`.
            // We must map the original high-fidelity PBR materials back to the new submeshes by NAME.
            for i in 0..<newGeo.materials.count {
                let generatedMatName = newGeo.materials[i].name ?? ""
                if let originalMat = originalMaterials.first(where: { $0.name == generatedMatName }) {
                    newGeo.materials[i] = originalMat
                } else {
                    // Fallback if names don't match, just use index (risky but better than grey)
                    if i < originalMaterials.count {
                        newGeo.materials[i] = originalMaterials[i]
                    }
                }
            }
            
            node.geometry = newGeo
        }
        
        print(" MacSpatialSnapper (MDLMesh): Snapped \(snappedCount)/\(totalCount) vertices to RoomPlan planes.")
    }
}
