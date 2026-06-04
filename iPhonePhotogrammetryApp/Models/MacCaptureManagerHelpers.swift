import Foundation
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - MacCaptureManagerHelpers
// Aligns photogrammetry mesh to RoomPlan using exhaustive Y-rotation search
// scored by wall-plane proximity. Takes ArchivedRoom directly so walls are
// read from the authoritative roomplan.json — not the round-tripped USDZ
// which loses node-name/geometry information.
enum MacCaptureManagerHelpers {
    
#if os(macOS)
    typealias PlatformColor = NSColor
    typealias PlatformFont = NSFont
#else
    typealias PlatformColor = UIColor
    typealias PlatformFont = UIFont
#endif
    
    // Internal types
    
    struct WallPlane {
        var center: SIMD3<Float>
        var normal: SIMD3<Float>   // unit normal, outward-facing
        var right:  SIMD3<Float>   // wall local-X (width direction)
        var halfWidth:  Float
        var halfHeight: Float
    }
    
    // Public API
    
    /// Merges a textured RoomPlan scene with a photogrammetry mesh.
    ///
    /// - Parameters:
    ///   - room:            ArchivedRoom decoded from roomplan.json (authoritative geometry).
    ///   - roomSceneURL:    The room_textured.usdz to use as the base scene.
    ///   - photogrammetryURL: model.usdz from PhotogrammetrySession.
    ///   - outputURL:       Where to write room_merged.usdz.
    /// Merges a textured RoomPlan scene with a photogrammetry mesh, using BOTH RoomPlan planes
    /// and a solidified LiDAR mesh as a high-fidelity geometric snapping scaffold.
    static func mergeRoomWithPhotogrammetry(
        room: ArchivedRoom,
        roomSceneURL: URL,
        photogrammetryURL: URL,
        lidarURL: URL,                 // Added to pull raw architectural depth
        sessionDirectory: URL,         // Added to decode coordinate transformations
        outputURL: URL
    ) throws {
        // 0. Load scenes
        let roomScene = try SCNScene(url: roomSceneURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])
        let pgScene = try SCNScene(url: photogrammetryURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])
        let lidarScene = try SCNScene(url: lidarURL, options: [ // Added
            SCNSceneSource.LoadingOption.checkConsistency: false
                                                              ])
        
        // 1. Build wall planes from ArchivedRoom
        let walls = buildWallPlanes(from: room)
        guard !walls.isEmpty else {
            print("⚠️ ArchivedRoom has no walls, compositing directly.")
            directComposite(pgScene: pgScene, into: roomScene)
            writeScene(roomScene, to: outputURL)
            return
        }
        
        // 2. Sample photogrammetry vertices
        let pgVertices = extractAllVertices(from: pgScene.rootNode, maxCount: 2500)
        
        guard pgVertices.count > 50 else {
            print("⚠️ PG mesh too sparse (\(pgVertices.count) verts), compositing directly.")
            directComposite(pgScene: pgScene, into: roomScene)
            writeScene(roomScene, to: outputURL)
            return
        }
        
        // 3. Centroids & Y-offset
        let pgCentroid = centroid(pgVertices)
        let pgYMin     = pgVertices.map(\.y).min()!
        
        let roomCentroid: SIMD3<Float>
        let floorY: Float
        if let floor = room.floors.first {
            let ft = floor.transform
            roomCentroid = SIMD3<Float>(ft.columns.3.x, ft.columns.3.y, ft.columns.3.z)
            floorY = ft.columns.3.y
        } else {
            roomCentroid = centroid(walls.map(\.center))
            floorY = walls.map { $0.center.y - $0.halfHeight }.min() ?? -1.4
        }
        let yOffset = floorY - pgYMin
        
        // 4. Exact 4x4 matrix alignment via camera poses
        let workDir = photogrammetryURL.deletingLastPathComponent()
        let posesURL = workDir.appendingPathComponent("pg_poses.json")
        let depthDir = workDir.appendingPathComponent("depth")
        var exactTransform: simd_float4x4? = nil
        
        if let posesData = try? Data(contentsOf: posesURL),
           let pgPosesRaw = try? JSONSerialization.jsonObject(with: posesData) as? [String: [Double]] {
            
            let heicFiles = (try? FileManager.default.contentsOfDirectory(
                at: workDir, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.lowercased().hasSuffix(".heic") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            
            var rawPairs: [(simd_float4x4, simd_float4x4)] = []
            let sortedKeys = pgPosesRaw.keys.compactMap { Int($0) }.sorted()
            
            for numericKey in sortedKeys {
                let key = String(numericKey)
                guard let pgMat = pgPosesRaw[key] else { continue }
                guard numericKey < heicFiles.count else { continue }
                let heicName = heicFiles[numericKey].lastPathComponent
                let baseName = (heicName as NSString).deletingPathExtension
                let cameraJsonName = baseName + "_camera.json"
                let cameraJsonURL = depthDir.appendingPathComponent(cameraJsonName)
                
                guard FileManager.default.fileExists(atPath: cameraJsonURL.path) else {
                    print("⚠️ Пропущено пару: Файл конфігурації камери \(cameraJsonName) не знайдено для ID \(key).")
                    continue
                }
                guard let camData = try? Data(contentsOf: cameraJsonURL),
                      let camJSON = try? JSONSerialization.jsonObject(with: camData) as? [String: Any],
                      let arkitArr = camJSON["extrinsics"] as? [Double],
                      arkitArr.count == 16, pgMat.count == 16 else { continue }
                
                func mat(_ a: [Double]) -> simd_float4x4 {
                    simd_float4x4(
                        SIMD4<Float>(Float(a[0]),Float(a[1]),Float(a[2]),Float(a[3])),
                        SIMD4<Float>(Float(a[4]),Float(a[5]),Float(a[6]),Float(a[7])),
                        SIMD4<Float>(Float(a[8]),Float(a[9]),Float(a[10]),Float(a[11])),
                        SIMD4<Float>(Float(a[12]),Float(a[13]),Float(a[14]),Float(a[15]))
                    )
                }
                rawPairs.append((mat(arkitArr), mat(pgMat)))
            }
            
            print(" Успішно синхронізовано та зафіксовано пар трекінгу: \(rawPairs.count) з \(sortedKeys.count)")
            if rawPairs.count > 2 {
                var arkitPoints: [SIMD3<Float>] = []
                var pgPoints: [SIMD3<Float>] = []
                for (C_arkit, C_pg) in rawPairs {
                    arkitPoints.append(SIMD3<Float>(C_arkit.columns.3.x, C_arkit.columns.3.y, C_arkit.columns.3.z))
                    pgPoints.append(SIMD3<Float>(C_pg.columns.3.x, C_pg.columns.3.y, C_pg.columns.3.z))
                }
                
                let c_arkit = arkitPoints.reduce(SIMD3<Float>.zero, +) / Float(arkitPoints.count)
                let c_pg = pgPoints.reduce(SIMD3<Float>.zero, +) / Float(pgPoints.count)
                
                var r_arkit: Float = 0
                var r_pg: Float = 0
                for i in 0..<arkitPoints.count {
                    r_arkit += simd_length(arkitPoints[i] - c_arkit)
                    r_pg += simd_length(pgPoints[i] - c_pg)
                }
                
                let scaleFactor = (r_pg > 0.001) ? (r_arkit / r_pg) : 1.0
                
                var transformCandidates: [simd_float4x4] = []
                for i in 0..<arkitPoints.count {
                    let C_arkit = rawPairs[i].0
                    let C_pg = rawPairs[i].1
                    
                    let R_arkit = simd_float3x3(
                        SIMD3(C_arkit.columns.0.x, C_arkit.columns.0.y, C_arkit.columns.0.z),
                        SIMD3(C_arkit.columns.1.x, C_arkit.columns.1.y, C_arkit.columns.1.z),
                        SIMD3(C_arkit.columns.2.x, C_arkit.columns.2.y, C_arkit.columns.2.z)
                    )
                    let R_pg = simd_float3x3(
                        SIMD3(C_pg.columns.0.x, C_pg.columns.0.y, C_pg.columns.0.z),
                        SIMD3(C_pg.columns.1.x, C_pg.columns.1.y, C_pg.columns.1.z),
                        SIMD3(C_pg.columns.2.x, C_pg.columns.2.y, C_pg.columns.2.z)
                    )
                    let R = R_arkit * simd_inverse(R_pg)
                    let t = arkitPoints[i] - (R * (pgPoints[i] * scaleFactor))
                    
                    let M = simd_float4x4(
                        SIMD4(R.columns.0 * scaleFactor, 0),
                        SIMD4(R.columns.1 * scaleFactor, 0),
                        SIMD4(R.columns.2 * scaleFactor, 0),
                        SIMD4(t, 1)
                    )
                    transformCandidates.append(M)
                }
                
                let txs = transformCandidates.map { $0.columns.3.x }.sorted()
                let tys = transformCandidates.map { $0.columns.3.y }.sorted()
                let tzs = transformCandidates.map { $0.columns.3.z }.sorted()
                let mid = txs.count / 2
                let medianT = SIMD3<Float>(txs[mid], tys[mid], tzs[mid])
                
                var bestM = transformCandidates.first ?? simd_float4x4(1)
                var bestDist: Float = .infinity
                for m in transformCandidates {
                    let t = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                    let dist = simd_distance_squared(t, medianT)
                    if dist < bestDist {
                        bestDist = dist
                        bestM = m
                    }
                }
                exactTransform = bestM
            }
        }
        
        
        // 5. INJECT AND SOLIDIFY LIDAR AS SCAFFOLD (OPTIONAL & SAFE)
        let lidarWrapper = SCNNode()
        lidarWrapper.name = "lidar_geometry"
        
        let lidarURL = sessionDirectory.appendingPathComponent("lidar.usdz")
        var hasValidLidar = false
        
        if FileManager.default.fileExists(atPath: lidarURL.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: lidarURL.path),
               let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                
                if let lidarScene = try? SCNScene(url: lidarURL, options: [
                    SCNSceneSource.LoadingOption.checkConsistency: false
                ]) {
                    print(" Valid LiDAR mesh detected. Injecting geometric scaffold...")
                    let exportCenter = lidarExportCenter(lidarScene: lidarScene, sessionDirectory: sessionDirectory)
                    lidarWrapper.simdPosition = exportCenter
                    
                    for child in lidarScene.rootNode.childNodes {
                        let clone = child.clone()
                        clone.enumerateChildNodes { node, _ in
                            node.geometry?.materials.forEach { $0.isDoubleSided = true }
                        }
                        clone.geometry?.materials.forEach { $0.isDoubleSided = true }
                        lidarWrapper.addChildNode(clone)
                    }
                    roomScene.rootNode.addChildNode(lidarWrapper)
                    solidifyLiDAR(rootNode: lidarWrapper, room: room)
                    hasValidLidar = true
                }
            }
        }
        
        if !hasValidLidar {
            print("ℹ️ LiDAR scaffold skipped (File missing, empty or failed to parse). Snapping purely to RoomScan planes.")
        }
        
        //        // ── 5. INJECT AND SOLIDIFY LIDAR AS SCAFFOLD FIRST ──────────────────
        //        let lidarWrapper = SCNNode()
        //        lidarWrapper.name = "lidar_geometry"
        //        let exportCenter = lidarExportCenter(lidarScene: lidarScene, sessionDirectory: sessionDirectory)
        //        lidarWrapper.simdPosition = exportCenter
        //
        //        for child in lidarScene.rootNode.childNodes {
        //            let clone = child.clone()
        //            clone.enumerateChildNodes { node, _ in
        //                node.geometry?.materials.forEach { $0.isDoubleSided = true }
        //            }
        //            clone.geometry?.materials.forEach { $0.isDoubleSided = true }
        //            lidarWrapper.addChildNode(clone)
        //        }
        //        roomScene.rootNode.addChildNode(lidarWrapper)
        //        solidifyLiDAR(rootNode: lidarWrapper, room: room)
        //
        // 6. Build Photogrammetry Node Wrapper
        
        let pgWrapper = SCNNode()
        pgWrapper.name = "photogrammetry_fill"
        
        for child in pgScene.rootNode.childNodes {
            let clone = child.clone()
            clone.enumerateChildNodes { n, _ in
                n.geometry?.materials.forEach { $0.isDoubleSided = true }
            }
            clone.geometry?.materials.forEach { $0.isDoubleSided = true }
            pgWrapper.addChildNode(clone)
        }
        
        if let exactTransform = exactTransform {
            pgWrapper.simdTransform = exactTransform
        } else {
            pgWrapper.position = SCNVector3(roomCentroid.x - pgCentroid.x, pgCentroid.y + yOffset, roomCentroid.z - pgCentroid.z)
        }
        roomScene.rootNode.addChildNode(pgWrapper)
        
        // 7. SPATIAL VERTEX SNAPPING (DYNAMIC FALLBACK)
        if let M = exactTransform {
            
            print(" Running baseline spatial vertex flattening...")
            MacSpatialSnapper.snap(rootNode: pgWrapper, alignTransform: M, room: room)
            
            if hasValidLidar {
                print(" Snapping photogrammetry to combined RoomScan + Aligned LiDAR Scaffold tree...")
                MacCaptureManagerHelpers.snapPhotogrammetryToReference(
                    rootNode: pgWrapper,
                    referenceRoot: roomScene.rootNode,
                    excluding: pgWrapper,
                    room: room,
                    maxDistance: 0.12,
                    blend: 0.80         // 80% pull strength
                )
            } else {
                print(" FALLBACK: Snapping edges directly to parametric RoomPlan planes (No LiDAR)...")
                MacCaptureManagerHelpers.snapPhotogrammetryToReference(
                    rootNode: pgWrapper,
                    referenceRoot: roomScene.rootNode,
                    excluding: pgWrapper,
                    room: room,
                    maxDistance: 0.05,
                    blend: 0.70
                )
            }
            
            print(" Running purely spatial vertex snapping to flatten walls...")
            MacSpatialSnapper.snap(rootNode: pgWrapper, alignTransform: M, room: room)
            
            print(" Snapping photogrammetry to RoomScan + Aligned LiDAR Scaffold tree...")
            MacCaptureManagerHelpers.snapPhotogrammetryToReference(
                rootNode: pgWrapper,
                referenceRoot: roomScene.rootNode,
                excluding: pgWrapper,
                room: room,
                maxDistance: 0.12,      // 12cm search bounds to snap photogrammetry edges
                blend: 0.80             // 80% pull strength onto continuous triangle fields
            )
        }
        // 8. Height Indicator Line & Text
        let maxWallHeight = room.walls.map { $0.dimensions.y }.max() ?? 2.5
        let cylGeo = SCNBox(width: 0.02, height: CGFloat(maxWallHeight), length: 0.02, chamferRadius: 0)
        let cylMat = SCNMaterial(); cylMat.diffuse.contents = PlatformColor.red; cylMat.emission.contents = PlatformColor.red
        cylGeo.materials = [cylMat]
        let lineNode = SCNNode(geometry: cylGeo)
        lineNode.name = "height_indicator"
        lineNode.position = SCNVector3(roomCentroid.x, floorY + maxWallHeight * 0.5, roomCentroid.z)
        roomScene.rootNode.addChildNode(lineNode)
        
        let heightString = String(format: "%.2f m", maxWallHeight)
        let textGeo = SCNText(string: heightString, extrusionDepth: 0.01)
        textGeo.font = PlatformFont.systemFont(ofSize: 0.12, weight: .bold)
        textGeo.flatness = 0.005
        let textMat = SCNMaterial(); textMat.diffuse.contents = PlatformColor.red; textMat.emission.contents = PlatformColor.red
        textGeo.materials = [textMat]
        
        let (minVec, maxVec) = textGeo.boundingBox
        let textNode = SCNNode(geometry: textGeo)
        textNode.name = "height_text"
        textNode.pivot = SCNMatrix4MakeTranslation(SCNFloat(minVec.x + (maxVec.x - minVec.x) * 0.5), SCNFloat(minVec.y + (maxVec.y - minVec.y) * 0.5), SCNFloat(minVec.z + (maxVec.z - minVec.z) * 0.5))
        textNode.position = SCNVector3(roomCentroid.x, floorY + maxWallHeight * 0.5 + 0.15, roomCentroid.z)
        let billboard = SCNBillboardConstraint(); billboard.freeAxes = .Y
        textNode.constraints = [billboard]
        roomScene.rootNode.addChildNode(textNode)
        
        // 9. Hide Reference Geometries
        roomScene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name {
                if name.hasPrefix("wall_") || name.hasPrefix("floor_") || name.hasPrefix("lidar_") {
                    node.isHidden = true
                }
            }
        }
        
        writeScene(roomScene, to: outputURL)
    }
    
    /// Merges a textured RoomPlan scene with the raw LiDAR mesh.
    ///
    /// Strategy: RoomPlan walls/floor/ceiling are the authoritative structural surfaces.
    /// LiDAR triangles that are CLOSE to those planes (≤ objectFilterThreshold) are dropped
    /// (they duplicate the RoomPlan surface). Only LiDAR triangles representing objects/furniture
    /// (far from structural planes) are kept and added on top of the RoomPlan scene.
    static func mergeRoomWithLiDAR(
        room: ArchivedRoom,
        roomSceneURL: URL,
        lidarURL: URL,
        sessionDirectory: URL,
        outputURL: URL
    ) throws {
        let roomScene = try SCNScene(url: roomSceneURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])
        let lidarScene = try SCNScene(url: lidarURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])
        
        // Planes from RoomPlan used to identify structural surfaces
        let structuralPlanes = buildAllPlanes(from: room)
        
        let lidarWrapper = SCNNode()
        lidarWrapper.name = "lidar_objects"
        let exportCenter = lidarExportCenter(lidarScene: lidarScene, sessionDirectory: sessionDirectory)
        lidarWrapper.simdPosition = exportCenter
        print(" LiDAR alignment offset restored: (\(fmt(exportCenter.x)), \(fmt(exportCenter.y)), \(fmt(exportCenter.z)))")
        
        // How far from a structural plane a LiDAR triangle centroid must be to be kept as an "object"
        // Triangles within this threshold are considered wall/floor/ceiling duplicates and dropped.
        let objectFilterThreshold: Float = 0.20  // 18cm from walls/floor/ceiling = structural zone
        
        for child in lidarScene.rootNode.childNodes {
            autoreleasepool {
                let clone = child.clone()
                clone.enumerateChildNodes { node, _ in
                    node.geometry?.materials.forEach { $0.isDoubleSided = true }
                    // Filter geometry to only keep object triangles
                    if let geo = node.geometry,
                       let vertSrc = geo.sources(for: .vertex).first,
                       let element = geo.elements.first,
                       element.primitiveType == .triangles {
                        let vcount = vertSrc.vectorCount
                        let wt = node.simdWorldTransform
                        var worldVerts = [SIMD3<Float>](repeating: .zero, count: vcount)
                        let vstride = vertSrc.dataStride
                        let voffset = vertSrc.dataOffset
                        vertSrc.data.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress else { return }
                            for i in 0..<vcount {
                                let ptr = base.advanced(by: i * vstride + voffset).assumingMemoryBound(to: Float.self)
                                let local = SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1)
                                let world = wt * local
                                worldVerts[i] = SIMD3<Float>(world.x, world.y, world.z)
                            }
                        }
                        let originalIndices = triangleIndices(from: element)
                        var keptIndices: [Int] = []
                        keptIndices.reserveCapacity(originalIndices.count)
                        for i in stride(from: 0, to: originalIndices.count - 2, by: 3) {
                            let i0 = originalIndices[i], i1 = originalIndices[i+1], i2 = originalIndices[i+2]
                            guard i0 < vcount, i1 < vcount, i2 < vcount else { continue }
                            let triCentroid = (worldVerts[i0] + worldVerts[i1] + worldVerts[i2]) / 3
                            // Check if centroid is close to any structural plane
                            let isStructural = structuralPlanes.contains { plane in
                                let toPlane = triCentroid - plane.center
                                let dist = abs(simd_dot(toPlane, plane.normal))
                                guard dist < objectFilterThreshold else { return false }
                                // Also check it's within the plane bounds (not in open space next to plane)
                                let projected = triCentroid - plane.normal * simd_dot(toPlane, plane.normal)
                                let toProjected = projected - plane.center
                                if abs(plane.normal.y) > 0.8 {
                                    // Horizontal plane (floor/ceiling) — check XZ bounds
                                    return abs(toProjected.x) <= plane.halfWidth + 0.3 &&
                                    abs(toProjected.z) <= plane.halfHeight + 0.3
                                } else {
                                    // Vertical plane (wall) — check width/height bounds
                                    let alongWall = abs(simd_dot(toProjected, plane.right))
                                    let vertical = abs(toProjected.y)
                                    return alongWall <= plane.halfWidth + 0.2 && vertical <= plane.halfHeight + 0.2
                                }
                            }
                            if !isStructural {
                                keptIndices.append(i0); keptIndices.append(i1); keptIndices.append(i2)
                            }
                        }
                        if keptIndices.count < 3 { return }
                        // Rebuild geometry with only object triangles
                        let indexData = keptIndices.map(UInt32.init).withUnsafeBufferPointer { Data(buffer: $0) }
                        let newElement = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                                            primitiveCount: keptIndices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size)
                        let otherSources = geo.sources.map { source in
                            SCNGeometrySource(data: source.data, semantic: source.semantic,
                                              vectorCount: source.vectorCount, usesFloatComponents: source.usesFloatComponents,
                                              componentsPerVector: source.componentsPerVector, bytesPerComponent: source.bytesPerComponent,
                                              dataOffset: source.dataOffset, dataStride: source.dataStride)
                        }
                        let newGeo = SCNGeometry(sources: otherSources, elements: [newElement])
                        newGeo.materials = geo.materials
                        node.geometry = newGeo
                        let keptPct = Int(Float(keptIndices.count) / Float(max(1, originalIndices.count)) * 100)
                        print("   LiDAR object filter: kept \(keptIndices.count/3)/\(originalIndices.count/3) tris (\(keptPct)% = objects)")
                    }
                }
                clone.geometry?.materials.forEach { $0.isDoubleSided = true }
                lidarWrapper.addChildNode(clone)
            }
        }
        
        roomScene.rootNode.addChildNode(lidarWrapper)
        // Smooth-snap kept object geometry to nearby planes (just edges, not centroids)
        solidifyLiDAR(rootNode: lidarWrapper, room: room)
        writeScene(roomScene, to: outputURL)
    }
    
    
    struct LiDARSolidifyConfig {
        var maxEdgeLength: Float = 0.45
        var minTriangleArea: Float = 0.00002
        var hardPlaneSnapDistance: Float = 0.025
        var planeFadeDistance: Float = 0.15
        var smoothIterations: Int = 3
        var smoothWeight: Float = 0.15
        var maxSmoothNeighborDistance: Float = 0.06
        var maxHoleBridge: Float = 0.12
        var maxFilledTrianglesPerNode: Int = 3_000
        var fillBoundaryHoles: Bool = true
    }
    private static func solidifyLiDAR(
        rootNode: SCNNode,
        room: ArchivedRoom,
        config: LiDARSolidifyConfig = LiDARSolidifyConfig()
    ) {
        let planes = buildAllPlanes(from: room)
        guard !planes.isEmpty else {
            print("LiDAR solidify skipped: no RoomPlan planes.")
            return
        }
        
        var processedNodes = 0
        var filteredTriangles = 0
        var filledTriangles = 0
        var flattenedVertices = 0
        
        rootNode.enumerateChildNodes { node, _ in
            autoreleasepool {
                guard let geo = node.geometry,
                      let vertSrc = geo.sources(for: .vertex).first,
                      let element = geo.elements.first,
                      element.primitiveType == .triangles else { return }
                
                let vcount = vertSrc.vectorCount
                guard vcount > 0 else { return }
                
                let wt = node.simdWorldTransform
                let invWt = simd_inverse(wt)
                
                var worldVerts = [SIMD3<Float>](repeating: .zero, count: vcount)
                let vstride = vertSrc.dataStride
                let voffset = vertSrc.dataOffset
                vertSrc.data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    for i in 0..<vcount {
                        let ptr = base.advanced(by: i * vstride + voffset).assumingMemoryBound(to: Float.self)
                        let local = SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1)
                        let world = wt * local
                        worldVerts[i] = SIMD3<Float>(world.x, world.y, world.z)
                    }
                }
                
                let originalIndices = triangleIndices(from: element)
                guard originalIndices.count >= 3 else { return }
                
                var planeWeights = [Float](repeating: 0, count: vcount)
                var planeProjected = worldVerts
                
                for i in 0..<vcount {
                    if let snap = bestPlaneProjection(for: worldVerts[i], planes: planes, fadeDistance: config.planeFadeDistance) {
                        let weight: Float
                        if snap.distance <= config.hardPlaneSnapDistance {
                            weight = 1.0
                        } else {
                            let t = (snap.distance - config.hardPlaneSnapDistance) / max(0.001, config.planeFadeDistance - config.hardPlaneSnapDistance)
                            let smooth = t * t * (3 - 2 * t)
                            weight = 1.0 - smooth
                        }
                        planeWeights[i] = weight
                        planeProjected[i] = snap.projected
                    }
                }
                
                var indices: [Int] = []
                indices.reserveCapacity(originalIndices.count)
                
                for i in stride(from: 0, to: originalIndices.count, by: 3) {
                    let i0 = originalIndices[i]
                    let i1 = originalIndices[i + 1]
                    let i2 = originalIndices[i + 2]
                    guard i0 < vcount, i1 < vcount, i2 < vcount else { continue }
                    
                    // Skip LiDAR triangles that lie on structural planes (walls, floor, ceiling)
                    let avgWeight = (planeWeights[i0] + planeWeights[i1] + planeWeights[i2]) / 3.0
                    if avgWeight >= 0.75 {
                        continue
                    }
                    
                    let v0 = worldVerts[i0]
                    let v1 = worldVerts[i1]
                    let v2 = worldVerts[i2]
                    let e0 = simd_distance(v0, v1)
                    let e1 = simd_distance(v1, v2)
                    let e2 = simd_distance(v2, v0)
                    let area = simd_length(simd_cross(v1 - v0, v2 - v0)) * 0.5
                    
                    guard max(e0, max(e1, e2)) <= config.maxEdgeLength,
                          area >= config.minTriangleArea else {
                        filteredTriangles += 1
                        continue
                    }
                    
                    indices.append(i0)
                    indices.append(i1)
                    indices.append(i2)
                }
                
                guard indices.count >= 3 else { return }
                
                var adjacency = [[Int]](repeating: [], count: vcount)
                for i in stride(from: 0, to: indices.count, by: 3) {
                    let a = indices[i], b = indices[i + 1], c = indices[i + 2]
                    adjacency[a].append(b); adjacency[a].append(c)
                    adjacency[b].append(a); adjacency[b].append(c)
                    adjacency[c].append(a); adjacency[c].append(b)
                }
                for i in 0..<adjacency.count {
                    adjacency[i] = Array(Set(adjacency[i]))
                }
                
                var verts = worldVerts
                var temp = verts
                
                for _ in 0..<config.smoothIterations {
                    for i in 0..<vcount {
                        let neighbors = adjacency[i].filter {
                            simd_distance(verts[i], verts[$0]) <= config.maxSmoothNeighborDistance
                        }
                        
                        let isStructuralPlaneVertex = planeWeights[i] >= 0.85
                        var target = verts[i]
                        
                        if isStructuralPlaneVertex {
                            target = planeProjected[i]
                        } else if !neighbors.isEmpty {
                            var sum = SIMD3<Float>.zero
                            for n in neighbors { sum += verts[n] }
                            target = simd_mix(target, sum / Float(neighbors.count), SIMD3<Float>(repeating: config.smoothWeight))
                            
                            if planeWeights[i] > 0 {
                                target = simd_mix(target, planeProjected[i], SIMD3<Float>(repeating: planeWeights[i]))
                            }
                        } else if planeWeights[i] > 0 {
                            target = planeProjected[i]
                        }
                        
                        if planeWeights[i] > 0 {
                            flattenedVertices += 1
                        }
                        
                        temp[i] = target
                    }
                    verts = temp
                }
                
                if config.fillBoundaryHoles {
                    let fillResult = fillSmallBoundaryHoles(indices: indices, vertices: verts, config: config)
                    indices = fillResult.indices
                    filledTriangles += fillResult.addedTriangles
                }
                
                var packed = [Float]()
                packed.reserveCapacity(vcount * 3)
                for world in verts {
                    let local = invWt * SIMD4<Float>(world.x, world.y, world.z, 1)
                    packed.append(local.x)
                    packed.append(local.y)
                    packed.append(local.z)
                }
                
                let newVertexData = packed.withUnsafeBufferPointer { Data(buffer: $0) }
                let newVertexSource = SCNGeometrySource(
                    data: newVertexData,
                    semantic: .vertex,
                    vectorCount: vcount,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<Float>.size * 3
                )
                
                let indexData = indices.map(UInt32.init).withUnsafeBufferPointer { Data(buffer: $0) }
                let newElement = SCNGeometryElement(
                    data: indexData,
                    primitiveType: .triangles,
                    primitiveCount: indices.count / 3,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
                
                let otherSources = geo.sources.filter { $0.semantic != .vertex }.map { source in
                    SCNGeometrySource(
                        data: source.data,
                        semantic: source.semantic,
                        vectorCount: source.vectorCount,
                        usesFloatComponents: source.usesFloatComponents,
                        componentsPerVector: source.componentsPerVector,
                        bytesPerComponent: source.bytesPerComponent,
                        dataOffset: source.dataOffset,
                        dataStride: source.dataStride
                    )
                }
                
                let newGeo = SCNGeometry(sources: [newVertexSource] + otherSources, elements: [newElement])
                newGeo.materials = geo.materials
                node.geometry = newGeo
                processedNodes += 1
            }
        }
        
        print("LiDAR solidify: \(processedNodes) nodes, \(flattenedVertices) plane pulls, \(filteredTriangles) triangles filtered, \(filledTriangles) small-hole triangles added.")
    }
    
    struct LiDARFaceTriangle {
        let v0: SIMD3<Float>
        let v1: SIMD3<Float>
        let v2: SIMD3<Float>
        let centroid: SIMD3<Float>
    }
    
    private static func closestPointOnTriangle(p: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a; let ac = c - a; let ap = p - a
        let d1 = simd_dot(ab, ap); let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b; let d3 = simd_dot(ab, bp); let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + (d1 / (d1 - d3)) * ab }
        let cp = p - c; let d5 = simd_dot(ab, cp); let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + (d2 / (d2 - d6)) * ac }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + ((d4 - d3) / ((d4 - d3) + (d5 - d6))) * (c - b) }
        
        let denom = 1.0 / (va + vb + vc)
        return a + (vb * denom) * ab + (vc * denom) * ac
    }
    static func snapPhotogrammetryToReference(
        rootNode: SCNNode,
        referenceRoot: SCNNode,
        excluding excludedNode: SCNNode,
        room: ArchivedRoom,
        maxDistance: Float = 0.10,
        blend: Float = 0.50,
        maxReferenceTriangles: Int = 60_000
    ) {
        struct VoxelKey: Hashable { let x: Int; let y: Int; let z: Int }
        
        struct FastVolumeGrid {
            let cellSize: Float
            var cells: [VoxelKey: [SIMD3<Float>]] = [:]
            
            init(cellSize: Float) { self.cellSize = cellSize }
            
            mutating func add(_ pt: SIMD3<Float>) {
                let key = VoxelKey(x: Int(floor(pt.x / cellSize)), y: Int(floor(pt.y / cellSize)), z: Int(floor(pt.z / cellSize)))
                cells[key, default: []].append(pt)
            }
            
            func smoothSurfacePoint(to query: SIMD3<Float>, maxDist: Float) -> SIMD3<Float>? {
                let centerKey = VoxelKey(x: Int(floor(query.x / cellSize)), y: Int(floor(query.y / cellSize)), z: Int(floor(query.z / cellSize)))
                var accumulatedPoints: [SIMD3<Float>] = []
                let r = Int(ceil(maxDist / cellSize))
                
                for x in (centerKey.x - r)...(centerKey.x + r) {
                    for y in (centerKey.y - r)...(centerKey.y + r) {
                        for z in (centerKey.z - r)...(centerKey.z + r) {
                            if let pts = cells[VoxelKey(x: x, y: y, z: z)] {
                                accumulatedPoints.append(contentsOf: pts)
                            }
                        }
                    }
                }
                
                guard !accumulatedPoints.isEmpty else { return nil }
                
                var bestPoint = accumulatedPoints[0]
                var bestDistSq = simd_distance_squared(query, bestPoint)
                
                for p in accumulatedPoints {
                    let dSq = simd_distance_squared(query, p)
                    if dSq < bestDistSq {
                        bestDistSq = dSq
                        bestPoint = p
                    }
                }
                return bestDistSq <= (maxDist * maxDist) ? bestPoint : nil
            }
        }
        
        var excluded = Set<ObjectIdentifier>()
        excluded.insert(ObjectIdentifier(excludedNode))
        excludedNode.enumerateChildNodes { node, _ in excluded.insert(ObjectIdentifier(node)) }
        
        var referencePoints: [SIMD3<Float>] = []
        referenceRoot.enumerateChildNodes { node, _ in
            guard !excluded.contains(ObjectIdentifier(node)),
                  let geometry = node.geometry,
                  let element = geometry.elements.first,
                  element.primitiveType == .triangles else { return }
            
            let worldTransform = node.simdWorldTransform
            guard let vertexSource = geometry.sources(for: .vertex).first,
                  vertexSource.usesFloatComponents else { return }
            
            let stride = vertexSource.dataStride
            let offset = vertexSource.dataOffset
            let count = vertexSource.vectorCount
            
            vertexSource.data.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else { return }
                for i in Swift.stride(from: 0, to: count, by: count > 40000 ? 3 : 1) {
                    let base = baseAddress.advanced(by: offset + stride * i)
                    let localPt = SIMD3<Float>(base.load(fromByteOffset: 0, as: Float.self), base.load(fromByteOffset: 4, as: Float.self), base.load(fromByteOffset: 8, as: Float.self))
                    let world = worldTransform * SIMD4<Float>(localPt.x, localPt.y, localPt.z, 1)
                    referencePoints.append(SIMD3<Float>(world.x, world.y, world.z))
                }
            }
        }
        
        guard !referencePoints.isEmpty else { return }
        
        var grid = FastVolumeGrid(cellSize: maxDistance * 1.0)
        for pt in referencePoints { grid.add(pt) }
        
        let structuralPlanes = buildAllPlanes(from: room)
        
        rootNode.enumerateChildNodes { node, _ in
            autoreleasepool {
                guard let geometry = node.geometry,
                      let vertexSource = geometry.sources(for: .vertex).first else { return }
                
                let worldTransform = node.simdWorldTransform
                let inverseWorldTransform = simd_inverse(worldTransform)
                let stride = vertexSource.dataStride
                let offset = vertexSource.dataOffset
                let count = vertexSource.vectorCount
                
                var vertices = [SIMD3<Float>](repeating: .zero, count: count)
                vertexSource.data.withUnsafeBytes { raw in
                    guard let baseAddress = raw.baseAddress else { return }
                    for i in 0..<count {
                        let base = baseAddress.advanced(by: offset + stride * i)
                        vertices[i] = SIMD3<Float>(base.load(fromByteOffset: 0, as: Float.self), base.load(fromByteOffset: 4, as: Float.self), base.load(fromByteOffset: 8, as: Float.self))
                    }
                }
                
                var changed = false
                let maxDistSq = maxDistance * maxDistance
                
                for i in 0..<vertices.count {
                    let localPt = vertices[i]
                    let world = worldTransform * SIMD4<Float>(localPt.x, localPt.y, localPt.z, 1)
                    let worldPoint = SIMD3<Float>(world.x, world.y, world.z)
                    
                    var targetPoint = worldPoint
                    var isSnapped = false
                    
                    if let wallSnap = bestPlaneProjection(for: worldPoint, planes: structuralPlanes, fadeDistance: 0.02) {
                        if wallSnap.distance <= 0.04 {
                            targetPoint = wallSnap.projected
                            isSnapped = true
                        }
                    }
                    
                    if !isSnapped, let nearestLiDAR = grid.smoothSurfacePoint(to: worldPoint, maxDist: maxDistance) {
                        
                        let dist = simd_distance(worldPoint, nearestLiDAR)
                        
                        if dist < 0.05 {
                        } else if dist < maxDistance {
                            let pull = blend * (1.0 - (dist / maxDistance))
                            targetPoint = simd_mix(worldPoint, nearestLiDAR, SIMD3<Float>(repeating: pull))
                            isSnapped = true
                        }
                    }
                    if isSnapped {
                        let snappedLocal = inverseWorldTransform * SIMD4<Float>(targetPoint.x, targetPoint.y, targetPoint.z, 1)
                        var targetLocalPoint = SIMD3<Float>(snappedLocal.x, snappedLocal.y, snappedLocal.z)
                        
                        var deltaVector = targetLocalPoint - localPt
                        let displacement = simd_length(deltaVector)
                        
                        let maxDisplacement: Float = 0.02
                        if displacement > maxDisplacement {
                            deltaVector = (deltaVector / displacement) * maxDisplacement
                            targetLocalPoint = localPt + deltaVector
                        }
                        
                        if displacement > 0.002 {
                            vertices[i] = targetLocalPoint
                            changed = true
                        }
                    }
                }
                
                guard changed else { return }
                
                var packed = [Float](); packed.reserveCapacity(vertices.count * 3)
                for vertex in vertices { packed.append(vertex.x); packed.append(vertex.y); packed.append(vertex.z) }
                
                let newVertexSource = SCNGeometrySource(
                    data: packed.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: vertices.count,
                    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3
                )
                
                let otherSources = geometry.sources.filter { $0.semantic != .vertex }.map { source in
                    SCNGeometrySource(data: source.data, semantic: source.semantic, vectorCount: source.vectorCount,
                                      usesFloatComponents: source.usesFloatComponents, componentsPerVector: source.componentsPerVector,
                                      bytesPerComponent: source.bytesPerComponent, dataOffset: source.dataOffset, dataStride: source.dataStride)
                }
                let newElements = geometry.elements.map { element in
                    SCNGeometryElement(data: element.data, primitiveType: element.primitiveType,
                                       primitiveCount: element.primitiveCount, bytesPerIndex: element.bytesPerIndex)
                }
                node.geometry = SCNGeometry(sources: [newVertexSource] + otherSources, elements: newElements)
                node.geometry?.materials = geometry.materials
            }
        }
    }
    //    private static func addRoomPlanSolidGuides(to rootNode: SCNNode, room: ArchivedRoom) {
    //        let material = makeLiDARSolidMaterial(alpha: 0.62)
    //        var structuralCount = 0
    //        var cuboidCount = 0
    //
    //        for (i, wall) in room.walls.enumerated() {
    //            let node = SCNNode(geometry: SCNPlane(
    //                width: CGFloat(wall.dimensions.x),
    //                height: CGFloat(wall.dimensions.y)
    //            ))
    //            node.name = "lidar_wall_solid_\(i)"
    //            node.simdTransform = offsetTransform(wall.transform, by: 0.012)
    //            node.geometry?.materials = [material]
    //            rootNode.addChildNode(node)
    //            structuralCount += 1
    //        }
    //
    //        for (i, floor) in room.floors.enumerated() {
    //            let node = SCNNode(geometry: SCNPlane(
    //                width: CGFloat(floor.dimensions.x),
    //                height: CGFloat(floor.dimensions.y)
    //            ))
    //            node.name = "lidar_floor_solid_\(i)"
    //            node.simdTransform = offsetTransform(floor.transform, by: 0.008)
    //            node.geometry?.materials = [material]
    //            rootNode.addChildNode(node)
    //            structuralCount += 1
    //        }
    //
    //        let ceilingHeight = room.walls.map { $0.dimensions.y }.max() ?? 2.5
    //        for (i, floor) in room.floors.enumerated() {
    //            let node = SCNNode(geometry: SCNPlane(
    //                width: CGFloat(floor.dimensions.x),
    //                height: CGFloat(floor.dimensions.y)
    //            ))
    //            var transform = floor.transform
    //            transform.columns.3.y += ceilingHeight
    //            node.name = "lidar_ceiling_solid_\(i)"
    //            node.simdTransform = offsetTransform(transform, by: -0.008)
    //            node.geometry?.materials = [material]
    //            rootNode.addChildNode(node)
    //            structuralCount += 1
    //        }
    //
    //        let objectMaterial = makeLiDARSolidMaterial(alpha: 0.38)
    //        for (i, object) in room.objects.enumerated() {
    //            let dims = object.dimensions
    //            guard dims.x > 0.12, dims.y > 0.12, dims.z > 0.12 else { continue }
    //
    //            let box = SCNBox(
    //                width: CGFloat(dims.x),
    //                height: CGFloat(dims.y),
    //                length: CGFloat(dims.z),
    //                chamferRadius: 0
    //            )
    //            box.materials = [objectMaterial]
    //
    //            let node = SCNNode(geometry: box)
    //            node.name = "lidar_cuboid_solid_\(i)"
    //            node.simdTransform = object.transform
    //            rootNode.addChildNode(node)
    //            cuboidCount += 1
    //        }
    //
    //        print("LiDAR solid guides: \(structuralCount) planar fills, \(cuboidCount) RoomPlan cuboids.")
    //    }
    
    private static func offsetTransform(_ transform: simd_float4x4, by amount: Float) -> simd_float4x4 {
        var result = transform
        let rawNormal = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let normal = simd_length(rawNormal) > 1e-6 ? normalize(rawNormal) : SIMD3<Float>(0, 0, 1)
        result.columns.3.x += normal.x * amount
        result.columns.3.y += normal.y * amount
        result.columns.3.z += normal.z * amount
        return result
    }
    
    private static func makeLiDARSolidMaterial(alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = PlatformColor(red: 0.48, green: 0.95, blue: 1.0, alpha: alpha)
        material.emission.contents = PlatformColor(red: 0.08, green: 0.23, blue: 0.26, alpha: alpha * 0.2)
        material.transparency = alpha
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        material.writesToDepthBuffer = true
        return material
    }
    
    private static func triangleIndices(from element: SCNGeometryElement) -> [Int] {
        let count = element.primitiveCount * 3
        var indices: [Int] = []
        indices.reserveCapacity(count)
        
        element.data.withUnsafeBytes { raw in
            switch element.bytesPerIndex {
            case 1:
                let ptr = raw.bindMemory(to: UInt8.self)
                for i in 0..<count { indices.append(Int(ptr[i])) }
            case 2:
                let ptr = raw.bindMemory(to: UInt16.self)
                for i in 0..<count { indices.append(Int(ptr[i])) }
            default:
                let ptr = raw.bindMemory(to: UInt32.self)
                for i in 0..<count { indices.append(Int(ptr[i])) }
            }
        }
        
        return indices
    }
    
    private static func bestPlaneProjection(
        for point: SIMD3<Float>,
        planes: [WallPlane],
        fadeDistance: Float
    ) -> (projected: SIMD3<Float>, distance: Float)? {
        var bestProjected = point
        var bestDistance = fadeDistance
        var found = false
        
        for plane in planes {
            let toPlane = point - plane.center
            let signedDistance = simd_dot(toPlane, plane.normal)
            let distance = abs(signedDistance)
            guard distance < bestDistance else { continue }
            
            let projected = point - plane.normal * signedDistance
            let toProjected = projected - plane.center
            
            let inBounds: Bool
            if abs(plane.normal.y) > 0.8 {
                let dx = abs(toProjected.x)
                let dz = abs(toProjected.z)
                inBounds = dx <= plane.halfWidth + 0.35 && dz <= plane.halfHeight + 0.35
            } else {
                let alongWall = abs(simd_dot(toProjected, plane.right))
                let vertical = abs(toProjected.y)
                inBounds = alongWall <= plane.halfWidth + 0.25 && vertical <= plane.halfHeight + 0.25
            }
            
            guard inBounds else { continue }
            bestDistance = distance
            bestProjected = projected
            found = true
        }
        
        return found ? (bestProjected, bestDistance) : nil
    }
    
    private static func fillSmallBoundaryHoles(
        indices: [Int],
        vertices: [SIMD3<Float>],
        config: LiDARSolidifyConfig
    ) -> (indices: [Int], addedTriangles: Int) {
        struct Edge: Hashable {
            let a: Int
            let b: Int
            
            init(_ i: Int, _ j: Int) {
                self.a = min(i, j)
                self.b = max(i, j)
            }
        }
        
        var edgeCounts: [Edge: Int] = [:]
        var triangleSet = Set<[Int]>()
        
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            edgeCounts[Edge(a, b), default: 0] += 1
            edgeCounts[Edge(b, c), default: 0] += 1
            edgeCounts[Edge(c, a), default: 0] += 1
            triangleSet.insert([a, b, c].sorted())
        }
        
        var boundaryNeighbors: [Int: Set<Int>] = [:]
        for (edge, count) in edgeCounts where count == 1 {
            boundaryNeighbors[edge.a, default: []].insert(edge.b)
            boundaryNeighbors[edge.b, default: []].insert(edge.a)
        }
        
        var out = indices
        var added = 0
        
        for (center, neighborsSet) in boundaryNeighbors {
            guard added < config.maxFilledTrianglesPerNode else { break }
            let neighbors = Array(neighborsSet)
            guard neighbors.count >= 2 else { continue }
            
            for i in 0..<(neighbors.count - 1) {
                guard added < config.maxFilledTrianglesPerNode else { break }
                for j in (i + 1)..<neighbors.count {
                    let a = neighbors[i]
                    let c = neighbors[j]
                    let key = [a, center, c].sorted()
                    guard !triangleSet.contains(key) else { continue }
                    
                    let va = vertices[a]
                    let vb = vertices[center]
                    let vc = vertices[c]
                    let edgeAC = simd_distance(va, vc)
                    let area = simd_length(simd_cross(vb - va, vc - va)) * 0.5
                    guard edgeAC <= config.maxHoleBridge,
                          area >= config.minTriangleArea,
                          area <= config.maxHoleBridge * config.maxHoleBridge else { continue }
                    
                    out.append(a)
                    out.append(center)
                    out.append(c)
                    triangleSet.insert(key)
                    added += 1
                    break
                }
            }
        }
        
        return (out, added)
    }
    
    private static func lidarExportCenter(lidarScene: SCNScene, sessionDirectory: URL) -> SIMD3<Float> {
        let rootChildren = lidarScene.rootNode.childNodes
        if rootChildren.count == 1 {
            let rootOffset = rootChildren[0].simdPosition
            if simd_length(rootOffset) > 1e-5 {
                print(" LiDAR alignment: recovered exact export offset from lidar.usdz root transform.")
                return -rootOffset
            }
        }
        
        let metadataURL = sessionDirectory.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metadataURL),
           let metadata = try? JSONDecoder().decode(SessionMetadata.self, from: data),
           let center = metadata.lidarExportCenter,
           center.count >= 3 {
            print(" LiDAR alignment: recovered exact export offset from metadata.json.")
            return SIMD3<Float>(center[0], center[1], center[2])
        }
        
        let depthDir = sessionDirectory.appendingPathComponent("depth")
        guard let files = try? FileManager.default.contentsOfDirectory(at: depthDir, includingPropertiesForKeys: nil) else {
            print("⚠️ LiDAR alignment: no metadata offset or camera frames; using identity.")
            return .zero
        }
        
        let decoder = JSONDecoder()
        let frames = files
            .filter { $0.lastPathComponent.hasSuffix("_camera.json") }
            .compactMap { url -> CameraFrameData? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CameraFrameData.self, from: data)
            }
            .sorted { $0.timestamp < $1.timestamp }
        
        guard let lastFrame = frames.last, lastFrame.extrinsics.count >= 16 else {
            print("⚠️ LiDAR alignment: no usable camera frame fallback; using identity.")
            return .zero
        }
        
        let m = simd_float4x4(
            SIMD4<Float>(lastFrame.extrinsics[0], lastFrame.extrinsics[1], lastFrame.extrinsics[2], lastFrame.extrinsics[3]),
            SIMD4<Float>(lastFrame.extrinsics[4], lastFrame.extrinsics[5], lastFrame.extrinsics[6], lastFrame.extrinsics[7]),
            SIMD4<Float>(lastFrame.extrinsics[8], lastFrame.extrinsics[9], lastFrame.extrinsics[10], lastFrame.extrinsics[11]),
            SIMD4<Float>(lastFrame.extrinsics[12], lastFrame.extrinsics[13], lastFrame.extrinsics[14], lastFrame.extrinsics[15])
        )
        let cameraPosition = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let rawForward = SIMD3<Float>(-m.columns.2.x, -m.columns.2.y, -m.columns.2.z)
        let cameraForward = simd_length(rawForward) > 1e-5 ? normalize(rawForward) : SIMD3<Float>(0, 0, -1)
        print("⚠️ LiDAR alignment: metadata offset missing; estimated from last camera pose.")
        return cameraPosition + cameraForward * 0.5
    }
    
    // Plane building from ArchivedRoom
    
    /// Walls only (vertical surfaces) — used for alignment scoring.
    private static func buildWallPlanes(from room: ArchivedRoom) -> [WallPlane] {
        room.walls.compactMap { surface in
            let t = surface.transform
            let rawNormal = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let rawRight  = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)
            let nLen = simd_length(rawNormal), rLen = simd_length(rawRight)
            guard nLen > 1e-6, rLen > 1e-6 else { return nil }
            guard abs(rawNormal.y / nLen) < 0.5 else { return nil }   // skip horizontal
            let dims = surface.dimensions
            return WallPlane(
                center:    SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                normal:    rawNormal / nLen,
                right:     rawRight  / rLen,
                halfWidth: dims.x * 0.5,
                halfHeight: dims.y * 0.5
            )
        }
    }
    
    /// Walls + floor + ceiling — used for smooth mesh snapping.
    private static func buildAllPlanes(from room: ArchivedRoom) -> [WallPlane] {
        var planes = buildWallPlanes(from: room)
        
        // Floor(s): horizontal plane facing up (0,1,0)
        for floor in room.floors {
            let t = floor.transform
            let center = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let dims   = floor.dimensions
            planes.append(WallPlane(
                center:    center,
                normal:    SIMD3(0, 1, 0),
                right:     SIMD3(1, 0, 0),
                halfWidth: max(dims.x, dims.y) * 0.5,
                halfHeight: max(dims.x, dims.y) * 0.5
            ))
        }
        
        // Synthesise ceiling: same XZ as each floor but offset by wall height.
        let ceilH = room.walls.map { $0.dimensions.y }.max() ?? 2.5
        for floor in room.floors {
            let t = floor.transform
            let ceilY  = t.columns.3.y + ceilH
            let dims   = floor.dimensions
            planes.append(WallPlane(
                center:    SIMD3(t.columns.3.x, ceilY, t.columns.3.z),
                normal:    SIMD3(0, -1, 0),   // facing down, into room
                right:     SIMD3(1, 0, 0),
                halfWidth: max(dims.x, dims.y) * 0.5,
                halfHeight: max(dims.x, dims.y) * 0.5
            ))
        }
        
        return planes
    }
    
    // Rotation / translation scoring
    
    private static func scoreRotation(
        angle: Float,
        pgVerts: [SIMD3<Float>],
        pgCentroid: SIMD3<Float>,
        roomCentroid: SIMD3<Float>,
        yOffset: Float,
        walls: [WallPlane],
        thickness: Float
    ) -> Float {
        let cosA = cos(angle), sinA = sin(angle)
        var score: Float = 0
        for v in pgVerts {
            let dx = v.x - pgCentroid.x
            let dz = v.z - pgCentroid.z
            let p = SIMD3<Float>(
                dx * cosA - dz * sinA + roomCentroid.x,
                v.y + yOffset,
                dx * sinA + dz * cosA + roomCentroid.z
            )
            score += wallScore(point: p, walls: walls, thickness: thickness)
        }
        return score
    }
    
    private static func scoreTranslation(
        tx: Float, tz: Float,
        cosA: Float, sinA: Float,
        pgVerts: [SIMD3<Float>],
        pgCentroid: SIMD3<Float>,
        roomCentroid: SIMD3<Float>,
        yOffset: Float,
        walls: [WallPlane],
        thickness: Float
    ) -> Float {
        var score: Float = 0
        for v in pgVerts {
            let dx = v.x - pgCentroid.x
            let dz = v.z - pgCentroid.z
            let p = SIMD3<Float>(
                dx * cosA - dz * sinA + roomCentroid.x + tx,
                v.y + yOffset,
                dx * sinA + dz * cosA + roomCentroid.z + tz
            )
            score += wallScore(point: p, walls: walls, thickness: thickness)
        }
        return score
    }
    
    @inline(__always)
    private static func wallScore(point p: SIMD3<Float>, walls: [WallPlane], thickness: Float) -> Float {
        var best: Float = 0
        for wall in walls {
            let toWall    = p - wall.center
            let planeDist = abs(simd_dot(toWall, wall.normal))
            guard planeDist < thickness else { continue }
            let projRight = abs(simd_dot(toWall, wall.right))
            let projUp    = abs(toWall.y)
            guard projRight < wall.halfWidth + 0.4,
                  projUp    < wall.halfHeight + 0.4 else { continue }
            let s = 1.0 - (planeDist / thickness)
            if s > best { best = s }
        }
        return best
    }
    
    // LiDAR snapping (post-alignment)
    
    /// Loads lidar.usdz, builds a VoxelGrid, then snaps aligned PG vertices to
    /// the nearest LiDAR point. Must be called AFTER the alignment transform is known
    /// so PG vertices can be converted to ARKit world space for comparison.
    private static func applyLiDARSnapping(
        to rootNode: SCNNode,
        lidarURL: URL,
        cosA: Float, sinA: Float,
        pgCentroid: SIMD3<Float>,
        roomCentroid: SIMD3<Float>,
        bestTx: Float, bestTz: Float,
        yOffset: Float,
        snapRadius: Float
    ) {
        // Load lidar.usdz and collect world-space vertices into a VoxelGrid
        guard let lidarScene = try? SCNScene(url: lidarURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ]) else {
            print("⚠️ Could not load lidar.usdz for snapping")
            return
        }
        
        var lidarPts: [SIMD3<Float>] = []
        lidarScene.rootNode.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            let wt = node.simdWorldTransform
            for src in geo.sources(for: .vertex) {
                let stride = src.dataStride, offset = src.dataOffset, count = src.vectorCount
                src.data.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let base = raw.baseAddress! + offset + stride * i
                        let x = base.load(fromByteOffset: 0, as: Float.self)
                        let y = base.load(fromByteOffset: 4, as: Float.self)
                        let z = base.load(fromByteOffset: 8, as: Float.self)
                        let w = wt * SIMD4<Float>(x, y, z, 1)
                        lidarPts.append(SIMD3(w.x, w.y, w.z))
                    }
                }
            }
        }
        guard !lidarPts.isEmpty else { return }
        
        // Subsample to 30K to keep memory bounded
        let step = max(1, lidarPts.count / 30_000)
        let sampled = stride(from: 0, to: lidarPts.count, by: step).map { lidarPts[$0] }
        
        // Build VoxelGrid keyed by WorldPoint
        struct WorldPoint { let x, y, z: Float }
        struct SimpleVoxel {
            let cellSize: Float
            var cells: [Int64: SIMD3<Float>] = [:]
            
            init(points: [SIMD3<Float>], cellSize: Float) {
                self.cellSize = cellSize
                for p in points {
                    let key = encode(p, cs: cellSize)
                    if cells[key] == nil { cells[key] = p }
                }
            }
            
            func nearest(to q: SIMD3<Float>, maxDist d: Float) -> SIMD3<Float>? {
                var best: SIMD3<Float>? = nil
                var bestDist = d * d
                let r = Int64((d / cellSize).rounded(.up))
                let cx = Int64((q.x / cellSize).rounded())
                let cy = Int64((q.y / cellSize).rounded())
                let cz = Int64((q.z / cellSize).rounded())
                for ix in (cx-r)...(cx+r) {
                    for iy in (cy-r)...(cy+r) {
                        for iz in (cz-r)...(cz+r) {
                            let k = ix &* 1_000_003 &+ iy &* 1_000_033 &+ iz &* 1_000_003
                            guard let p = cells[k] else { continue }
                            let dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z
                            let dd = dx*dx + dy*dy + dz*dz
                            if dd < bestDist { bestDist = dd; best = p }
                        }
                    }
                }
                return best
            }
        }
        
        func encode(_ p: SIMD3<Float>, cs: Float) -> Int64 {
            let ix = Int64((p.x / cs).rounded())
            let iy = Int64((p.y / cs).rounded())
            let iz = Int64((p.z / cs).rounded())
            return ix &* 1_000_003 &+ iy &* 1_000_033 &+ iz &* 1_000_003
        }
        
        let voxel = SimpleVoxel(points: sampled, cellSize: snapRadius * 2)
        print(" LiDAR snapping: \(sampled.count) LiDAR pts, radius=\(snapRadius)m")
        
        var snappedCount = 0
        
        rootNode.enumerateChildNodes { node, _ in
            autoreleasepool {
                guard let geo = node.geometry,
                      let vertSrc = geo.sources(for: .vertex).first else { return }
                
                let wt  = node.simdWorldTransform
                let invWt = simd_inverse(wt)
                let stride = vertSrc.dataStride, offset = vertSrc.dataOffset
                let count  = vertSrc.vectorCount
                
                var verts = [SIMD3<Float>](repeating: .zero, count: count)
                vertSrc.data.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let ptr = raw.baseAddress!.advanced(by: i * stride + offset)
                            .assumingMemoryBound(to: Float.self)
                        verts[i] = SIMD3(ptr[0], ptr[1], ptr[2])
                    }
                }
                
                var anyChanged = false
                for i in 0..<verts.count {
                    // PG local → PG world
                    let local = SIMD4<Float>(verts[i].x, verts[i].y, verts[i].z, 1)
                    let pgWorld = wt * local
                    
                    // PG world → ARKit world (apply alignment transform)
                    let dx = pgWorld.x - pgCentroid.x
                    let dz = pgWorld.z - pgCentroid.z
                    let arPt = SIMD3<Float>(
                        dx * cosA - dz * sinA + roomCentroid.x + bestTx,
                        pgWorld.y + yOffset,
                        dx * sinA + dz * cosA + roomCentroid.z + bestTz
                    )
                    
                    guard let nearest = voxel.nearest(to: arPt, maxDist: snapRadius) else { continue }
                    
                    // Nearest LiDAR point → ARKit world → back to PG world → PG local
                    let rdx = nearest.x - roomCentroid.x - bestTx
                    let rdz = nearest.z - roomCentroid.z - bestTz
                    let pgWorldSnapped = SIMD4<Float>(
                        rdx * cosA + rdz * sinA + pgCentroid.x,
                        (nearest.y - yOffset),
                        -rdx * sinA + rdz * cosA + pgCentroid.z,
                        1
                    )
                    let localSnapped = invWt * pgWorldSnapped
                    verts[i] = SIMD3(localSnapped.x, localSnapped.y, localSnapped.z)
                    anyChanged = true
                }
                
                guard anyChanged else { return }
                snappedCount += 1
                
                var packed = [Float](); packed.reserveCapacity(verts.count * 3)
                for v in verts { packed.append(v.x); packed.append(v.y); packed.append(v.z) }
                let newData = packed.withUnsafeBufferPointer { Data(buffer: $0) }
                let newSrc = SCNGeometrySource(data: newData, semantic: .vertex,
                                               vectorCount: verts.count, usesFloatComponents: true,
                                               componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
                
                let otherSrcs = geo.sources.filter { $0.semantic != .vertex }.map { s -> SCNGeometrySource in
                    SCNGeometrySource(data: s.data, semantic: s.semantic, vectorCount: s.vectorCount,
                                      usesFloatComponents: s.usesFloatComponents, componentsPerVector: s.componentsPerVector,
                                      bytesPerComponent: s.bytesPerComponent, dataOffset: s.dataOffset, dataStride: s.dataStride)
                }
                let newElements = geo.elements.map { el -> SCNGeometryElement in
                    SCNGeometryElement(data: el.data, primitiveType: el.primitiveType,
                                       primitiveCount: el.primitiveCount, bytesPerIndex: el.bytesPerIndex)
                }
                let newGeo = SCNGeometry(sources: [newSrc] + otherSrcs, elements: newElements)
                newGeo.materials = geo.materials
                node.geometry = newGeo
            }
        }
        print(" LiDAR snapping: \(snappedCount) nodes refined")
    }
    
    // Smooth plane snapping (post-alignment)
    
    /// Irons noisy photogrammetry vertices flat onto the nearest RoomPlan plane
    /// using a cubic smoothstep falloff so edges blend naturally into furniture.
    ///
    /// - snapZone: vertices closer than this are snapped 100 % flat.
    /// - fadeZone: snapping fades to 0 % at this distance; beyond = untouched.
    private static func applySmoothedFlattening(
        to rootNode: SCNNode,
        alignTransform: simd_float4x4,
        planes: [WallPlane],
        snapZone: Float,
        fadeZone: Float
    ) {
        var snappedNodes = 0
        
        rootNode.enumerateChildNodes { node, _ in
            autoreleasepool {
                guard let geo = node.geometry,
                      let vertSrc = geo.sources(for: .vertex).first else { return }
                
                // Node local → PG model world → ARKit world
                let wt     = node.simdWorldTransform
                let invWt  = simd_inverse(wt)
                
                let vstride = vertSrc.dataStride
                let voffset = vertSrc.dataOffset
                let vcount  = vertSrc.vectorCount
                
                var verts = [SIMD3<Float>](repeating: .zero, count: vcount)
                vertSrc.data.withUnsafeBytes { raw in
                    for i in 0..<vcount {
                        let ptr = raw.baseAddress!.advanced(by: i * vstride + voffset)
                            .assumingMemoryBound(to: Float.self)
                        verts[i] = SIMD3(ptr[0], ptr[1], ptr[2])
                    }
                }
                
                // The pgWrapper has simdTransform = alignTransform.
                // So vertex ARKit world space = alignTransform * (wt * localVertex).
                // wt already includes the wrapper's transform because we're iterating
                // child nodes of the wrapper — use simdWorldTransform which walks up.
                
                var anyChanged = false
                for i in 0..<verts.count {
                    let localPt4 = SIMD4<Float>(verts[i].x, verts[i].y, verts[i].z, 1)
                    // simdWorldTransform already incorporates alignTransform because
                    // the node is a child of pgWrapper whose transform = alignTransform.
                    let arPt4 = wt * localPt4
                    let arPt  = SIMD3<Float>(arPt4.x, arPt4.y, arPt4.z)
                    
                    // Find closest plane within fadeZone
                    var closestPlane: WallPlane? = nil
                    var closestDist:  Float = fadeZone
                    
                    for plane in planes {
                        let toPlane   = arPt - plane.center
                        let planeDist = abs(simd_dot(toPlane, plane.normal))
                        guard planeDist < closestDist else { continue }
                        
                        // Bounds check with generous margin for curved PG geometry
                        let projRight = abs(simd_dot(toPlane, plane.right))
                        let up = SIMD3<Float>(0, 1, 0)
                        let projUp = abs(simd_dot(toPlane, up))
                        guard projRight < plane.halfWidth  + 0.30,
                              projUp    < plane.halfHeight + 0.30 else { continue }
                        
                        closestDist  = planeDist
                        closestPlane = plane
                    }
                    
                    guard let plane = closestPlane else { continue }
                    
                    // Cubic smoothstep blend factor:
                    //   d <= snapZone → blend = 1.0 (full snap)
                    //   snapZone < d < fadeZone → blend fades via smoothstep
                    //   d >= fadeZone → blend = 0.0 (untouched)
                    let blend: Float
                    if closestDist <= snapZone {
                        blend = 1.0
                    } else {
                        // t goes 0→1 over the fade band
                        let t = (closestDist - snapZone) / (fadeZone - snapZone)
                        // Reverse smoothstep so it's 1 at t=0 and 0 at t=1
                        let s = t * t * (3 - 2 * t)  // smoothstep
                        blend = 1.0 - s
                    }
                    guard blend > 0.001 else { continue }
                    
                    // Project arPt onto the plane
                    let toPlane = arPt - plane.center
                    let signedDist = simd_dot(toPlane, plane.normal)
                    let flatArPt = arPt - plane.normal * (signedDist * blend)
                    
                    // Convert back to node local space.
                    // wt = node.simdWorldTransform already incorporates alignTransform
                    // (because pgWrapper.simdTransform = alignTransform and node is its child).
                    // So: ARKit world → local = invWt * flatAR4 — no extra invAlign needed.
                    let flatAR4  = SIMD4<Float>(flatArPt.x, flatArPt.y, flatArPt.z, 1)
                    let local4   = invWt * flatAR4
                    verts[i]  = SIMD3(local4.x, local4.y, local4.z)
                    anyChanged = true
                }
                
                guard anyChanged else { return }
                snappedNodes += 1
                
                // Pack updated vertices (12-byte stride to match original PG mesh)
                var packed = [Float](); packed.reserveCapacity(verts.count * 3)
                for v in verts { packed.append(v.x); packed.append(v.y); packed.append(v.z) }
                let newData = packed.withUnsafeBufferPointer { Data(buffer: $0) }
                let newSrc  = SCNGeometrySource(
                    data: newData, semantic: .vertex,
                    vectorCount: verts.count, usesFloatComponents: true,
                    componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
                
                let otherSrcs = geo.sources.filter { $0.semantic != .vertex }.map { s -> SCNGeometrySource in
                    SCNGeometrySource(data: s.data, semantic: s.semantic,
                                      vectorCount: s.vectorCount, usesFloatComponents: s.usesFloatComponents,
                                      componentsPerVector: s.componentsPerVector, bytesPerComponent: s.bytesPerComponent,
                                      dataOffset: s.dataOffset, dataStride: s.dataStride)
                }
                let newElements = geo.elements.map { el -> SCNGeometryElement in
                    SCNGeometryElement(data: el.data, primitiveType: el.primitiveType,
                                       primitiveCount: el.primitiveCount, bytesPerIndex: el.bytesPerIndex)
                }
                let newGeo = SCNGeometry(sources: [newSrc] + otherSrcs, elements: newElements)
                newGeo.materials = geo.materials
                node.geometry = newGeo
            }
        }
        print(" Smooth snap: \(snappedNodes) nodes updated")
    }
    
    // Vertex extraction
    
    private static func extractAllVertices(from rootNode: SCNNode, maxCount: Int) -> [SIMD3<Float>] {
        var all: [SIMD3<Float>] = []
        rootNode.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            let wt = node.simdWorldTransform
            for src in geo.sources(for: .vertex) {
                let stride = src.dataStride, offset = src.dataOffset, count = src.vectorCount
                src.data.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let base = raw.baseAddress! + offset + stride * i
                        let x = base.load(fromByteOffset: 0, as: Float.self)
                        let y = base.load(fromByteOffset: 4, as: Float.self)
                        let z = base.load(fromByteOffset: 8, as: Float.self)
                        let w = wt * SIMD4<Float>(x, y, z, 1)
                        all.append(SIMD3(w.x, w.y, w.z))
                    }
                }
            }
        }
        if all.count > maxCount {
            let step = all.count / maxCount
            return Swift.stride(from: 0, to: all.count, by: step).map { all[$0] }
        }
        return all
    }
    
    private static func centroid(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !pts.isEmpty else { return .zero }
        return pts.reduce(.zero, +) / Float(pts.count)
    }
    
    private static func fmt(_ f: Float) -> String { String(format: "%.2f", f) }
    
    // Scene helpers
    
    private static func directComposite(pgScene: SCNScene, into roomScene: SCNScene) {
        for child in pgScene.rootNode.childNodes {
            let clone = child.clone()
            clone.enumerateChildNodes { n, _ in n.geometry?.materials.forEach { $0.isDoubleSided = true } }
            clone.geometry?.materials.forEach { $0.isDoubleSided = true }
            roomScene.rootNode.addChildNode(clone)
        }
    }
    
    private static func writeScene(_ scene: SCNScene, to url: URL) {
        try? FileManager.default.removeItem(at: url)
        
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                if let contentStr = material.diffuse.contents as? String,
                   contentStr.contains("engine:") || contentStr.contains(".rematerial") {
                    material.diffuse.contents = PlatformColor.lightGray
                }
                material.lightingModel = .physicallyBased
            }
        }
        
        autoreleasepool {
            let exportOptions: [String: Any] = [
                SCNSceneSource.LoadingOption.convertToYUp.rawValue: true
            ]
            if !scene.write(to: url, options: exportOptions, delegate: nil, progressHandler: nil) {
                print("⚠️ Failed to write merged scene safely")
            }
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        print(" Final unified model written: \(size / 1_000_000) MB")
    }
}
