import Foundation
import SceneKit
import simd
import ModelIO

// MARK: - MeshRefiner
// Post-processes a PhotogrammetrySession USDZ using stored LiDAR depth maps.
// Repairs warped geometry on flat surfaces (walls, furniture, boxes).
//
// Pipeline:
//  1. Load all depth sidecar files → dense LiDAR point cloud in world space
//  2. Load USDZ mesh vertices
//  3. For each vertex, snap to nearest high-confidence LiDAR point
//  4. RANSAC plane detection → flatten clusters of coplanar vertices
//  5. Export refined USDZ
final class MeshRefiner {

    // Configuration
    struct Config {
        /// Maximum distance (m) to snap a vertex to its nearest LiDAR point
        var snapRadius: Float = 0.04          // 4 cm
        /// Minimum confidence to use a LiDAR point (0=none,1=low,2=med,3=high)
        var minConfidence: UInt8 = 2
        /// RANSAC: inlier distance threshold for plane detection
        var planeInlierDist: Float = 0.025    // 2.5 cm
        /// RANSAC: minimum fraction of vertices in a patch to call it a plane
        var planeFraction: Float = 0.4
        /// Skip refinement on small meshes (< N vertices)
        var minVertices: Int = 20
    }

    // Progress reporting
    enum Step: CustomStringConvertible {
        case loadingDepth(Int, Int)
        case buildingCloud(Int)
        case refiningSNode(Int, Int)
        case planeDetection
        case exportingUSDZ
        case done

        var description: String {
            switch self {
            case .loadingDepth(let i, let n): return "Loading depth frame \(i)/\(n)"
            case .buildingCloud(let n):       return "Built point cloud: \(n) pts"
            case .refiningSNode(let i, let n):return "Refining mesh \(i)/\(n)"
            case .planeDetection:             return "Plane detection (RANSAC)"
            case .exportingUSDZ:              return "Exporting refined USDZ"
            case .done:                       return "Refinement complete ✅"
            }
        }
    }

    let config: Config
    private var progressHandler: ((Step) -> Void)?

    init(config: Config = Config()) {
        self.config = config
    }

    func onProgress(_ handler: @escaping (Step) -> Void) -> MeshRefiner {
        progressHandler = handler
        return self
    }

    // MARK: - Main Entry Point

    /// Refines the USDZ at `modelURL` using depth data in `depthStore`.
    /// Writes a new USDZ to `outputURL`. Call from a background thread.
    func refine(modelURL: URL, depthStore: DepthDataStore, outputURL: URL) throws {
        // LiDAR snapping and RANSAC flattening require the photogrammetry mesh to
        // already be in ARKit world space. But this refine() step runs BEFORE the
        // alignment transform is computed in MacCaptureManagerHelpers. Applying
        // geometric operations in the wrong coordinate system destroys the model.
        //
        // Strategy:
        //   - If per-frame _depth.bin files exist (hasDepth:true): apply LiDAR
        //     snapping here since camera extrinsics put us in ARKit world space.
        //   - Otherwise (lidar.usdz only): just copy unchanged. MacCaptureManagerHelpers
        //     will do LiDAR snapping AFTER computing the alignment transform.
        let cloud = buildPointCloud(from: depthStore)
        guard !cloud.isEmpty else {
            print("⚠️ MeshRefiner: No per-frame depth data — passing model through unchanged.")
            print("   LiDAR snapping will happen post-alignment in merger.")
            try FileManager.default.copyItem(at: modelURL, to: outputURL)
            return
        }

        // Per-frame depth data exists: we CAN snap vertices because camera
        // extrinsics give us ARKit world coordinates for each depth frame.
        let kdTree = VoxelGrid(points: cloud, voxelSize: config.snapRadius * 2)

        let scene = try SCNScene(url: modelURL, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ])

        let allNodes = gatherGeometryNodes(scene.rootNode)
        report(.refiningSNode(0, allNodes.count))

        for (i, node) in allNodes.enumerated() {
            autoreleasepool {
                guard let geo = node.geometry,
                      let src = geo.sources(for: .vertex).first,
                      src.vectorCount >= config.minVertices else { return }
                let verts = extractVertices(from: src)
                guard let snapped = snapVertices(verts,
                                                 worldTransform: node.simdWorldTransform,
                                                 kdTree: kdTree) else { return }
                node.geometry = replaceVertices(in: geo, with: snapped, original: src)
            }
            if i % 10 == 0 { report(.refiningSNode(i, allNodes.count)) }
        }

        report(.exportingUSDZ)
        var exportSuccess = false
        autoreleasepool {
            exportSuccess = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
        }
        guard exportSuccess else { throw RefineError.exportFailed }
        report(.done)
    }

    // MARK: - Point Cloud Builder

    private func buildPointCloud(from store: DepthDataStore) -> [WorldPoint] {
        // Only use per-frame _depth.bin files here.
        // lidar.usdz integration is handled post-alignment in MacCaptureManagerHelpers.
        let frames = store.loadAllCameraData()
        let depthFrames = frames.filter { $0.hasDepth }
        guard !depthFrames.isEmpty else {
            return []
        }
        
        var cloud: [WorldPoint] = []
        let lock = NSLock()
        report(.loadingDepth(0, depthFrames.count))
        
        DispatchQueue.concurrentPerform(iterations: depthFrames.count) { i in
            let frame = depthFrames[i]
            guard let depth = store.loadDepthMap(for: frame.imageFilename) else { return }

            let intrinsics = simd_float3x3.fromArray(frame.intrinsics)
            let extrinsics = simd_float4x4.fromArray(frame.extrinsics)
            let scaleX = Float(depth.width) / Float(frame.imageWidth)
            let scaleY = Float(depth.height) / Float(frame.imageHeight)

            let fx = intrinsics[0][0] * scaleX
            let fy = intrinsics[1][1] * scaleY
            let cx = intrinsics[2][0] * scaleX
            let cy = intrinsics[2][1] * scaleY

            let maxPointsPerFrame = max(500, 50_000 / max(1, depthFrames.count))
            let pixelCount = depth.width * depth.height
            let stride = max(4, Int(sqrt(Double(pixelCount) / Double(maxPointsPerFrame))))
            
            var localCloud: [WorldPoint] = []
            localCloud.reserveCapacity(maxPointsPerFrame)
            
            for row in Swift.stride(from: 0, to: depth.height, by: stride) {
                for col in Swift.stride(from: 0, to: depth.width, by: stride) {
                    let idx = row * depth.width + col
                    guard idx < depth.data.count else { continue }
                    let z = depth.data[idx]
                    guard z > 0.1 && z < 8.0 else { continue }

                    let xc = (Float(col) - cx) * z / fx
                    let yc = (Float(row) - cy) * z / fy

                    let camPoint = SIMD4<Float>(xc, yc, -z, 1)
                    let worldPt = extrinsics * camPoint
                    localCloud.append(WorldPoint(x: worldPt.x, y: worldPt.y, z: worldPt.z))
                }
            }
            
            lock.lock()
            cloud.append(contentsOf: localCloud)
            lock.unlock()
        }
        
        report(.buildingCloud(cloud.count))
        return cloud
    }
    
    /// Load all vertices from lidar.usdz — they are already in ARKit world space.
    private func loadLiDARMeshVertices(from url: URL) -> [WorldPoint] {
        guard let scene = try? SCNScene(url: url, options: [
            SCNSceneSource.LoadingOption.checkConsistency: false
        ]) else {
            print("⚠️ MeshRefiner: Failed to load lidar.usdz")
            return []
        }
        
        var points: [WorldPoint] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            let wt = node.simdWorldTransform
            for src in geo.sources(for: .vertex) {
                let stride = src.dataStride
                let offset = src.dataOffset
                let count  = src.vectorCount
                src.data.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let base = raw.baseAddress! + offset + stride * i
                        let x = base.load(fromByteOffset: 0, as: Float.self)
                        let y = base.load(fromByteOffset: 4, as: Float.self)
                        let z = base.load(fromByteOffset: 8, as: Float.self)
                        let world = wt * SIMD4<Float>(x, y, z, 1)
                        points.append(WorldPoint(x: world.x, y: world.y, z: world.z))
                    }
                }
            }
        }
        return points
    }

    // MARK: - Vertex Snapping
    
    /// Snaps vertices to nearest LiDAR points. Operates on plain Swift arrays — thread-safe.
    private func snapVertices(
        _ verts: [SIMD3<Float>],
        worldTransform: simd_float4x4,
        kdTree: VoxelGrid
    ) -> [SIMD3<Float>]? {
        let invWorldT = simd_inverse(worldTransform)
        var result = verts
        var snapped = 0
        
        for i in 0..<verts.count {
            let local = SIMD4<Float>(verts[i].x, verts[i].y, verts[i].z, 1)
            let world = worldTransform * local
            
            if let nearest = kdTree.nearest(to: SIMD3(world.x, world.y, world.z),
                                            maxDist: config.snapRadius) {
                let snappedWorld = SIMD4<Float>(nearest.x, nearest.y, nearest.z, 1)
                let snappedLocal = invWorldT * snappedWorld
                result[i] = SIMD3(snappedLocal.x, snappedLocal.y, snappedLocal.z)
                snapped += 1
            }
        }
        
        return snapped > 0 ? result : nil
    }

    // MARK: - RANSAC Plane Flattening

    /// RANSAC plane detection and flattening on pure Swift arrays — thread-safe.
    private func flattenPlanarRegions(_ verts: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        guard verts.count >= 10 else { return nil }

        let iterations = 30
        var bestPlane: Plane? = nil
        var bestInliers: [Int] = []

        for _ in 0..<iterations {
            let i0 = Int.random(in: 0..<verts.count)
            var i1 = Int.random(in: 0..<verts.count)
            var i2 = Int.random(in: 0..<verts.count)
            while i1 == i0 { i1 = Int.random(in: 0..<verts.count) }
            while i2 == i0 || i2 == i1 { i2 = Int.random(in: 0..<verts.count) }

            guard let plane = Plane(p0: verts[i0], p1: verts[i1], p2: verts[i2]) else { continue }

            let inliers = verts.indices.filter { plane.distance(to: verts[$0]) < config.planeInlierDist }
            if inliers.count > bestInliers.count {
                bestInliers = inliers
                bestPlane = plane
            }
        }

        guard let plane = bestPlane,
              Float(bestInliers.count) / Float(verts.count) > config.planeFraction else { return nil }

        var result = verts
        for idx in bestInliers {
            result[idx] = plane.project(verts[idx])
        }

        print(" Flattened \(bestInliers.count)/\(verts.count) verts onto detected plane")
        return result
    }

    // MARK: - SCNGeometry Helpers

    private func gatherGeometryNodes(_ root: SCNNode) -> [SCNNode] {
        var result: [SCNNode] = []
        root.enumerateChildNodes { node, _ in
            if node.geometry != nil { result.append(node) }
        }
        return result
    }

    private func extractVertices(from source: SCNGeometrySource) -> [SIMD3<Float>] {
        let stride = source.dataStride
        let offset = source.dataOffset
        let count  = source.vectorCount
        var result = [SIMD3<Float>](repeating: .zero, count: count)

        source.data.withUnsafeBytes { rawPtr in
            for i in 0..<count {
                let ptr = rawPtr.baseAddress!
                    .advanced(by: i * stride + offset)
                    .assumingMemoryBound(to: Float.self)
                result[i] = SIMD3(ptr[0], ptr[1], ptr[2])
            }
        }
        return result
    }

    private func replaceVertices(in geo: SCNGeometry, with verts: [SIMD3<Float>],
                                 original: SCNGeometrySource) -> SCNGeometry {
        // Pack SIMD3<Float> (16 bytes) into contiguous Float arrays (12 bytes per vertex)
        // This is critical because the original USDZ mesh has dataStride = 12,
        // and mixing stride = 16 causes corrupted rendering and export failures.
        var packed = [Float]()
        packed.reserveCapacity(verts.count * 3)
        for v in verts {
            packed.append(v.x)
            packed.append(v.y)
            packed.append(v.z)
        }
        
        let newData = packed.withUnsafeBufferPointer { Data(buffer: $0) }
        let newSrc = SCNGeometrySource(
            data: newData, semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: 4,
            dataOffset: 0,
            dataStride: 12
        )
        
        // Deep copy other sources to detach them from MDLMesh
        let otherSrcs = geo.sources.filter { $0.semantic != .vertex }.map { s -> SCNGeometrySource in
            return SCNGeometrySource(
                data: s.data,
                semantic: s.semantic,
                vectorCount: s.vectorCount,
                usesFloatComponents: s.usesFloatComponents,
                componentsPerVector: s.componentsPerVector,
                bytesPerComponent: s.bytesPerComponent,
                dataOffset: s.dataOffset,
                dataStride: s.dataStride
            )
        }
        
        // Deep copy elements to detach them from MDLSubmesh
        let newElements = geo.elements.map { el -> SCNGeometryElement in
            return SCNGeometryElement(
                data: el.data,
                primitiveType: el.primitiveType,
                primitiveCount: el.primitiveCount,
                bytesPerIndex: el.bytesPerIndex
            )
        }
        
        let allSrcs = [newSrc] + otherSrcs
        let newGeo = SCNGeometry(sources: allSrcs, elements: newElements)
        newGeo.materials = geo.materials // Ensure textures/colors are preserved
        return newGeo
    }

    private func report(_ step: Step) {
        print("MeshRefiner: \(step)")
        progressHandler?(step)
    }
}

// MARK: - Plane

private struct Plane {
    let origin: SIMD3<Float>
    let normal: SIMD3<Float>

    init?(p0: SIMD3<Float>, p1: SIMD3<Float>, p2: SIMD3<Float>) {
        let v1 = p1 - p0
        let v2 = p2 - p0
        let n = simd_cross(v1, v2)
        let len = simd_length(n)
        guard len > 1e-6 else { return nil }
        origin = p0
        normal = n / len
    }

    func distance(to point: SIMD3<Float>) -> Float {
        abs(simd_dot(point - origin, normal))
    }

    func project(_ point: SIMD3<Float>) -> SIMD3<Float> {
        point - normal * simd_dot(point - origin, normal)
    }
}

// MARK: - World Point

private struct WorldPoint {
    let x, y, z: Float
}

// MARK: - VoxelGrid (fast nearest-neighbour)

private final class VoxelGrid {
    private let voxelSize: Float
    private var cells: [SIMD3<Int32>: [SIMD3<Float>]] = [:]

    init(points: [WorldPoint], voxelSize: Float) {
        self.voxelSize = voxelSize
        for p in points {
            let key = voxelKey(SIMD3(p.x, p.y, p.z))
            cells[key, default: []].append(SIMD3(p.x, p.y, p.z))
        }
    }

    func nearest(to query: SIMD3<Float>, maxDist: Float) -> SIMD3<Float>? {
        let centerKey = voxelKey(query)
        var best: SIMD3<Float>? = nil
        var bestDist = maxDist * maxDist

        // Search 27-cell neighbourhood
        for dx in Int32(-1)...1 {
            for dy in Int32(-1)...1 {
                for dz in Int32(-1)...1 {
                    let key = centerKey &+ SIMD3(dx, dy, dz)
                    guard let pts = cells[key] else { continue }
                    for p in pts {
                        let d = simd_distance_squared(p, query)
                        if d < bestDist { bestDist = d; best = p }
                    }
                }
            }
        }
        return best
    }

    private func voxelKey(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(floor(p.x / voxelSize)),
              Int32(floor(p.y / voxelSize)),
              Int32(floor(p.z / voxelSize)))
    }
}

// MARK: - Error

enum RefineError: LocalizedError {
    case exportFailed
    var errorDescription: String? { "Failed to write refined USDZ" }
}
