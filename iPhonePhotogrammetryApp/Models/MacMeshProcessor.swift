import Foundation
import SceneKit
import simd

class MacMeshProcessor {
    
    struct ProcessConfig {
        var maxEdgeLength: Float = 1.5
        var minAreaToPerimeterRatio: Float = 0.0002
        var smoothIterations: Int = 2
        var snapZone: Float = 0.02
        var fadeZone: Float = 0.08
        var snapWeight: Float = 0.4
    }
    /// Processes a SceneKit node containing photogrammetry geometry.
    /// - Parameters:
    ///   - rootNode: The node containing the geometry.
    ///   - alignTransform: The ARKit world alignment transform.
    ///   - planes: The RoomPlan planes to attract to.
    ///   - config: Filtering and smoothing configuration.
    static func process(
        rootNode: SCNNode,
        alignTransform: simd_float4x4,
        planes: [MacCaptureManagerHelpers.WallPlane],
        config: ProcessConfig = ProcessConfig()
    ) {
        var processedNodes = 0
        
        rootNode.enumerateChildNodes { node, _ in
            autoreleasepool {
                guard let geo = node.geometry,
                      let vertSrc = geo.sources(for: .vertex).first,
                      let texSrc = geo.sources(for: .texcoord).first,
                      let normSrc = geo.sources(for: .normal).first,
                      let element = geo.elements.first else { return }
                
                // Explicitly compute world transform because SceneKit's simdWorldTransform
                // is evaluated lazily and returns garbage in headless offline passes!
                let wt = alignTransform * node.simdTransform
                let invWt = simd_inverse(wt)
                
                // 1. Extract Vertices (converted to ARKit World Space for math)
                let vstride = vertSrc.dataStride
                let voffset = vertSrc.dataOffset
                let vcount = vertSrc.vectorCount
                
                var worldVerts = [SIMD3<Float>](repeating: .zero, count: vcount)
                vertSrc.data.withUnsafeBytes { raw in
                    for i in 0..<vcount {
                        let ptr = raw.baseAddress!.advanced(by: i * vstride + voffset).assumingMemoryBound(to: Float.self)
                        let localPt4 = SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1.0)
                        let arPt4 = wt * localPt4
                        worldVerts[i] = SIMD3<Float>(arPt4.x, arPt4.y, arPt4.z)
                    }
                }
                
                // Extract original local vertices for safe keeping (if we drop some, we might need to recreate the buffer)
                // Actually, filtering triangles doesn't require dropping vertices, we just drop the indices!
                // This keeps UVs, normals, and colors perfectly aligned with the vertex buffer.
                
                // 2. Extract Indices
                let primCount = element.primitiveCount
                let bytesPerIndex = element.bytesPerIndex
                var indices = [Int]()
                indices.reserveCapacity(primCount * 3)
                
                element.data.withUnsafeBytes { raw in
                    if bytesPerIndex == 2 {
                        let ptr = raw.bindMemory(to: UInt16.self)
                        for i in 0..<(primCount * 3) { indices.append(Int(ptr[i])) }
                    } else {
                        let ptr = raw.bindMemory(to: UInt32.self)
                        for i in 0..<(primCount * 3) { indices.append(Int(ptr[i])) }
                    }
                }
                
                // 3. Triangle Filtering Pass
                var newIndices = [Int]()
                newIndices.reserveCapacity(indices.count)
                
                for i in stride(from: 0, to: indices.count, by: 3) {
                    let i0 = indices[i]
                    let i1 = indices[i+1]
                    let i2 = indices[i+2]
                    
                    let v0 = worldVerts[i0]
                    let v1 = worldVerts[i1]
                    let v2 = worldVerts[i2]
                    
                    let e0 = simd_distance(v0, v1)
                    let e1 = simd_distance(v1, v2)
                    let e2 = simd_distance(v2, v0)
                    
                    // Filter out massive interpolations ("Sails")
                    let maxE = max(e0, max(e1, e2))
                    if maxE > config.maxEdgeLength { continue }
                    
                    // Optional: Filter out extreme slivers
                    let s = (e0 + e1 + e2) / 2.0
                    let areaSq = s * (s - e0) * (s - e1) * (s - e2)
                    if areaSq > 0 {
                        let area = sqrt(areaSq)
                        if (area / (s * 2.0)) < config.minAreaToPerimeterRatio { continue }
                    } else {
                        continue // Degenerate
                    }
                    
                    newIndices.append(i0)
                    newIndices.append(i1)
                    newIndices.append(i2)
                }
                
                print(" Filtering: dropped \(primCount - (newIndices.count/3)) bad triangles")
                
                // 4. Build Adjacency List for Smoothing
                var adjacency = [[Int]](repeating: [], count: vcount)
                for i in stride(from: 0, to: newIndices.count, by: 3) {
                    let i0 = newIndices[i], i1 = newIndices[i+1], i2 = newIndices[i+2]
                    adjacency[i0].append(i1); adjacency[i0].append(i2)
                    adjacency[i1].append(i0); adjacency[i1].append(i2)
                    adjacency[i2].append(i0); adjacency[i2].append(i1)
                }
                
                // Remove duplicates in adjacency
                for i in 0..<adjacency.count {
                    adjacency[i] = Array(Set(adjacency[i]))
                }
                
                // 5. Plane-Constrained Laplacian Smoothing
                var smoothedVerts = worldVerts
                var tempVerts = worldVerts
                
                for _ in 0..<config.smoothIterations {
                    for i in 0..<vcount {
                        let neighbors = adjacency[i]
                        guard !neighbors.isEmpty else { continue }
                        
                        // Laplacian average
                        var sum = SIMD3<Float>.zero
                        for n in neighbors {
                            sum += smoothedVerts[n]
                        }
                        var avg = sum / Float(neighbors.count)
                        
                        // Plane Attractor
                        let arPt = smoothedVerts[i]
                        var closestPlane: MacCaptureManagerHelpers.WallPlane? = nil
                        var closestDist = config.fadeZone
                        
                        for plane in planes {
                            let toPlane = arPt - plane.center
                            let planeDist = abs(simd_dot(toPlane, plane.normal))
                            guard planeDist < closestDist else { continue }
                            
                            let projRight = abs(simd_dot(toPlane, plane.right))
                            let up = SIMD3<Float>(0, 1, 0)
                            let projUp = abs(simd_dot(toPlane, up))
                            guard projRight < plane.halfWidth + 0.30,
                                  projUp    < plane.halfHeight + 0.30 else { continue }
                            
                            closestDist = planeDist
                            closestPlane = plane
                        }
                        
                        if let plane = closestPlane {
                            let blend: Float
                            if closestDist <= config.snapZone {
                                blend = 1.0
                            } else {
                                let t = (closestDist - config.snapZone) / (config.fadeZone - config.snapZone)
                                let s = t * t * (3 - 2 * t)
                                blend = 1.0 - s
                            }
                            
                            if blend > 0.001 {
                                let toPlane = arPt - plane.center
                                let signedDist = simd_dot(toPlane, plane.normal)
                                let flatArPt = arPt - plane.normal * signedDist
                                // Pull the vertex heavily towards the plane
                                avg = mix(avg, flatArPt, t: blend * config.snapWeight)
                            }
                        }
                        
                        // Move 50% towards average for stability
                        tempVerts[i] = mix(smoothedVerts[i], avg, t: 0.5)
                    }
                    smoothedVerts = tempVerts
                }
                
                // 6. Convert back to local space and pack
                var packed = [Float]()
                packed.reserveCapacity(vcount * 3)
                for i in 0..<vcount {
                    let arPt = smoothedVerts[i]
                    let flatAR4 = SIMD4<Float>(arPt.x, arPt.y, arPt.z, 1)
                    let local4 = invWt * flatAR4
                    packed.append(local4.x)
                    packed.append(local4.y)
                    packed.append(local4.z)
                }
                
                let newData = packed.withUnsafeBufferPointer { Data(buffer: $0) }
                let newSrc = SCNGeometrySource(
                    data: newData, semantic: .vertex,
                    vectorCount: vcount, usesFloatComponents: true,
                    componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
                
                // Pack new indices
                var newIndexData: Data
                if newIndices.count * 4 < 100000 && bytesPerIndex == 2 {
                    // Try to keep as UInt16 if possible (SceneKit sometimes complains if format changes)
                    // Actually, if we just use Int32, it's safer. SceneKit supports 4 byte indices easily.
                    let indices32 = newIndices.map { UInt32($0) }
                    newIndexData = indices32.withUnsafeBufferPointer { Data(buffer: $0) }
                } else {
                    let indices32 = newIndices.map { UInt32($0) }
                    newIndexData = indices32.withUnsafeBufferPointer { Data(buffer: $0) }
                }
                
                let newElement = SCNGeometryElement(
                    data: newIndexData,
                    primitiveType: .triangles,
                    primitiveCount: newIndices.count / 3,
                    bytesPerIndex: 4
                )
                
                let otherSrcs = geo.sources.filter { $0.semantic != .vertex }
                let newGeo = SCNGeometry(sources: [newSrc] + otherSrcs, elements: [newElement])
                newGeo.materials = geo.materials
                node.geometry = newGeo
                processedNodes += 1
            }
        }
        
        print(" MeshProcessor: \(processedNodes) nodes updated (Filtered & Smoothed)")
    }
}
