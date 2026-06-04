import SceneKit
import simd

// MARK: - Editable mesh state for one geometry node

/// Holds the live editable index data for a geometry, allowing
/// triangle-by-triangle removal with undo support.
class MeshEditState: @unchecked Sendable {
    /// Per-element: flat list of vertex indices (3 per triangle, in order).
    var indicesPerElement: [[Int]]
    /// Per-element: per-triangle face normal (SIMD3<Float>).
    var normalsPerElement: [[SIMD3<Float>]]
    /// Per-element: adjacency[triangleIdx] = [neighboring triangle indices].
    var adjacencyPerElement: [[[Int]]]
    /// Per-element: exact 3D center of each triangle (p0+p1+p2)/3
    var centersPerElement: [[SIMD3<Float>]]
    /// Per-element: average RGB color of each triangle from texture sampling
    var colorsPerElement: [[SIMD3<Float>]]
    /// Per-element: Spatial Hash Grid mapping 3D cell coordinates to triangle indices (O(1) lookups)
    var spatialHashGrids: [[SIMD3<Int>: [Int]]]
    /// The size of each 3D cell in the spatial grid (e.g., 0.05m = 5cm)
    let gridCellSize: Float = 0.05
    
    /// Maps a flat SceneKit SCNGeometryElement index (from hit tests) to the original element index and its starting triangle offset.
    struct SCNElementMapping: @unchecked Sendable {
        let originalElementIndex: Int
        let baseTriangleIndex: Int
    }
    var scnElementMapping: [SCNElementMapping]
    
    /// Per-element: Cached rendering chunks of ~10,000 triangles each for instant GPU reuse
    var cachedChunksPerElement: [[SCNGeometryElement]]
    let chunkSize = 10000
    
    /// Original geometry (for material reference).
    let geometry: SCNGeometry
    /// Extracted spatial positions for geometry rebuilds
    let positions: [SIMD3<Float>]

    init(
        indicesPerElement: [[Int]],
        normalsPerElement: [[SIMD3<Float>]],
        adjacencyPerElement: [[[Int]]],
        centersPerElement: [[SIMD3<Float>]],
        colorsPerElement: [[SIMD3<Float>]],
        spatialHashGrids: [[SIMD3<Int>: [Int]]],
        cachedChunksPerElement: [[SCNGeometryElement]],
        scnElementMapping: [SCNElementMapping],
        geometry: SCNGeometry,
        positions: [SIMD3<Float>]
    ) {
        self.indicesPerElement      = indicesPerElement
        self.normalsPerElement      = normalsPerElement
        self.adjacencyPerElement    = adjacencyPerElement
        self.centersPerElement      = centersPerElement
        self.colorsPerElement       = colorsPerElement
        self.spatialHashGrids       = spatialHashGrids
        self.cachedChunksPerElement = cachedChunksPerElement
        self.scnElementMapping      = scnElementMapping
        self.geometry               = geometry
        self.positions              = positions
    }

    func copy() -> MeshEditState {
        MeshEditState(
            indicesPerElement:      indicesPerElement,
            normalsPerElement:      normalsPerElement,
            adjacencyPerElement:    adjacencyPerElement,
            centersPerElement:      centersPerElement,
            colorsPerElement:       colorsPerElement,
            spatialHashGrids:       spatialHashGrids,
            cachedChunksPerElement: cachedChunksPerElement,
            scnElementMapping:      scnElementMapping,
            geometry:               geometry,
            positions:              positions
        )
    }
}

// MARK: - Main eraser engine

struct MeshEraser {

    // MARK: Mode preparation
    
    /// Helper to subdivide a massive index buffer into multiple SCNGeometryElements (chunks).
    static func buildChunks(indices: [Int], chunkSize: Int) -> [SCNGeometryElement] {
        var chunks: [SCNGeometryElement] = []
        let triCount = indices.count / 3
        for startTri in stride(from: 0, to: triCount, by: chunkSize) {
            let endTri = min(startTri + chunkSize, triCount)
            let chunkIndices = Array(indices[(startTri * 3)..<(endTri * 3)])
            let data = chunkIndices.map { Int32($0) }.withUnsafeBytes { Data($0) }
            chunks.append(SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: endTri - startTri,
                bytesPerIndex: 4
            ))
        }
        return chunks
    }

    /// Call once when entering Erase mode.
    /// Reads the geometry sources, texture UVs, and builds the adjacency and color graph.
    static func prepareState(for geometry: SCNGeometry, texture: CGImage? = nil) -> MeshEditState? {
        guard let posSource = geometry.sources.first(where: { $0.semantic == .vertex }) else {
            return nil
        }

        let positions = extractPositions(from: posSource)
        guard !positions.isEmpty else { return nil }
        
        var uvs: [SIMD2<Float>] = []
        if let uvSource = geometry.sources.first(where: { $0.semantic == .texcoord }) {
            uvs = extractTexcoords(from: uvSource)
        }
        
        // Extract raw pixels for color sampling
        var texturePixels: [UInt8]? = nil
        var texWidth = 0
        var texHeight = 0
        if let cgImage = texture {
            texWidth = cgImage.width
            texHeight = cgImage.height
            var data = [UInt8](repeating: 0, count: texWidth * texHeight * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            if let context = CGContext(data: &data, width: texWidth, height: texHeight, bitsPerComponent: 8, bytesPerRow: texWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: texWidth, height: texHeight))
                texturePixels = data
            }
        }

        var indicesPerElement:      [[Int]]               = []
        var normalsPerElement:      [[SIMD3<Float>]]      = []
        var adjacencyPerElement:    [[[Int]]]             = []
        var centersPerElement:      [[SIMD3<Float>]]      = []
        var colorsPerElement:       [[SIMD3<Float>]]      = []
        var spatialHashGrids:       [[SIMD3<Int>: [Int]]] = []
        var cachedChunksPerElement: [[SCNGeometryElement]] = []

        for element in geometry.elements {
            guard element.primitiveType == .triangles else {
                // pass through non-triangle elements unchanged
                indicesPerElement.append([])
                normalsPerElement.append([])
                adjacencyPerElement.append([])
                centersPerElement.append([])
                colorsPerElement.append([])
                spatialHashGrids.append([:])
                cachedChunksPerElement.append([])
                continue
            }

            let indices = extractIndices(from: element)
            let triCount = indices.count / 3

            // per-triangle normals, centers, and colors
            var flatNormals = [SIMD3<Float>](repeating: .zero, count: triCount)
            var centers = [SIMD3<Float>](repeating: .zero, count: triCount)
            var colors = [SIMD3<Float>](repeating: SIMD3(0.5, 0.5, 0.5), count: triCount)
            var grid = [SIMD3<Int>: [Int]]()
            let hasTexture = texturePixels != nil && !uvs.isEmpty
            
            for t in 0..<triCount {
                let i0 = indices[t * 3], i1 = indices[t * 3 + 1], i2 = indices[t * 3 + 2]
                if i0 < positions.count && i1 < positions.count && i2 < positions.count {
                    let p0 = positions[i0], p1 = positions[i1], p2 = positions[i2]
                    flatNormals[t] = triangleNormal(p0, p1, p2)
                    let center = (p0 + p1 + p2) / 3.0
                    centers[t] = center
                    
                    // Populate spatial hash grid
                    let gridPos = SIMD3<Int>(
                        Int(floor(center.x / 0.05)),
                        Int(floor(center.y / 0.05)),
                        Int(floor(center.z / 0.05))
                    )
                    grid[gridPos, default: []].append(t)
                    
                    // Color sampling
                    if hasTexture, i0 < uvs.count, i1 < uvs.count, i2 < uvs.count {
                        let centerUV = (uvs[i0] + uvs[i1] + uvs[i2]) / 3.0
                        var px = Int(centerUV.x * Float(texWidth))
                        var py = Int((1.0 - centerUV.y) * Float(texHeight)) // USDZ UVs are Y-flipped
                        px = max(0, min(texWidth - 1, px))
                        py = max(0, min(texHeight - 1, py))
                        
                        let idx = (py * texWidth + px) * 4
                        if idx + 2 < texturePixels!.count {
                            let r = Float(texturePixels![idx]) / 255.0
                            let g = Float(texturePixels![idx + 1]) / 255.0
                            let b = Float(texturePixels![idx + 2]) / 255.0
                            colors[t] = SIMD3(r, g, b)
                        }
                    }
                }
            }

            // adjacency: merges invisible UV seams via physical position
            let adj = buildAdjacency(indices: indices, positions: positions, triCount: triCount)
            
            // normal smoothing: ignores photogrammetry noise (bumps)
            var smoothedNormals = flatNormals
            for t in 0..<triCount {
                var sum = flatNormals[t]
                for n in adj[t] {
                    sum += flatNormals[n]
                }
                let len = simd_length(sum)
                if len > 0 {
                    smoothedNormals[t] = sum / len
                }
            }

            indicesPerElement.append(indices)
            normalsPerElement.append(smoothedNormals)
            adjacencyPerElement.append(adj)
            centersPerElement.append(centers)
            colorsPerElement.append(colors)
            spatialHashGrids.append(grid)
            cachedChunksPerElement.append(buildChunks(indices: indices, chunkSize: 10000))
        }

        let state = MeshEditState(
            indicesPerElement:      indicesPerElement,
            normalsPerElement:      normalsPerElement,
            adjacencyPerElement:    adjacencyPerElement,
            centersPerElement:      centersPerElement,
            colorsPerElement:       colorsPerElement,
            spatialHashGrids:       spatialHashGrids,
            cachedChunksPerElement: cachedChunksPerElement,
            scnElementMapping:      [],
            geometry:               geometry,
            positions:              positions
        )
        // Automatically populate the translation mapping
        _ = rebuildGeometry(state: state)
        
        return state
    }

    // MARK: Flood fill (magic wand selection)

    /// BFS outward from `seedTriangle` in element `elemIdx`.
    /// Includes a neighbor based on two professional heuristics:
    /// 1. Dihedral angle (neighbor vs current): stops at sharp creases (like table edges).
    /// 2. Global drift (neighbor vs seed): prevents leaking around an entire complex object.
    static func selectTriangles(
        seedTriangle: Int,
        elementIndex: Int,
        sensitivity: Float,
        state: MeshEditState
    ) -> Set<Int> {

        let normals   = state.normalsPerElement[elementIndex]
        let adjacency = state.adjacencyPerElement[elementIndex]

        guard seedTriangle < normals.count else { return [] }

        let seedNormal = normals[seedTriangle]
        let seedCenter = state.centersPerElement[elementIndex][seedTriangle]
        let seedColor  = state.colorsPerElement[elementIndex][seedTriangle]
        
        // As sensitivity increases from 0 -> 1:
        // GEOMETRIC LIMITS (STRICT): We want to prioritise stopping at physical edges.
        // - Permit only slight adjacent bends (dihedral: 2° up to max 35°) => Prevents climbing walls
        // - Permit drifting moderately from original plane (global: 5° up to max 55°) => Allows curving but prevents folding
        // - Permit rising/sinking off the exact tapped plane (distance: 5mm up to max 4cm) => Keeps selection on the same general surface level
        // COLOR LIMITS (FLEXIBLE):
        let maxDihedralDeg = 2.0 + sensitivity * 33.0
        let maxGlobalDeg   = 5.0 + sensitivity * 50.0
        let maxPlaneDist   = 0.005 + sensitivity * 0.035
        let maxColorDiff   = 0.1 + sensitivity * 2.0 // increased baseline color flexibility

        let cosDihedralThresh = cos(maxDihedralDeg * .pi / 180.0)
        let cosGlobalThresh   = cos(maxGlobalDeg * .pi / 180.0)
        
        // Helper for perceptual color distance (weights luma heavier than chroma)
        func colorDistance(_ c1: SIMD3<Float>, _ c2: SIMD3<Float>) -> Float {
            let lumaWeights = SIMD3<Float>(0.299, 0.587, 0.114)
            let l1 = simd_dot(c1, lumaWeights)
            let l2 = simd_dot(c2, lumaWeights)
            let lumaDiff = abs(l1 - l2)
            let rawDiff = simd_distance(c1, c2)
            // Weight luma contrast 2x vs raw color shift to better catch hard shadows
            return (lumaDiff * 2.0 + rawDiff) / 3.0
        }

        var selected = Set<Int>()
        var queue = [seedTriangle]
        selected.insert(seedTriangle)

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let currentNormal = normals[current]
            
            for neighbor in adjacency[current] {
                guard !selected.contains(neighbor) else { continue }
                
                let neighborNormal = normals[neighbor]
                let neighborCenter = state.centersPerElement[elementIndex][neighbor]
                
                // 1. Must not bend too sharply from its immediate neighbor
                let dihedralDot = simd_dot(currentNormal, neighborNormal)
                if dihedralDot < cosDihedralThresh { continue }
                
                // 2. Must not drift too wildly from the original tapped surface angle
                let globalDot = simd_dot(seedNormal, neighborNormal)
                if globalDot < cosGlobalThresh { continue }
                
                // 3. Must not rise/sink away from the mathematical seed plane (stops climbing walls/objects)
                let distToPlane = abs(simd_dot(neighborCenter - seedCenter, seedNormal))
                if distToPlane > maxPlaneDist { continue }
                
                // 4. Color similarity (Perceptual Contrast)
                let neighborColor = state.colorsPerElement[elementIndex][neighbor]
                let colorDiff = colorDistance(seedColor, neighborColor)
                if colorDiff > maxColorDiff { continue }
                
                selected.insert(neighbor)
                queue.append(neighbor)
            }
        }
        
        var finalSelected = selected
        
        // Morphological Border Cleanup
        
        // Step 1. Dilate (Soft Border Expansion - The Shadow Catcher)
        let expansionLayers = Int(round(sensitivity * 3.0))
        if expansionLayers > 0 {
            var front = Array(finalSelected)
            for _ in 0..<expansionLayers {
                var nextFront = [Int]()
                for t in front {
                    for neighbor in adjacency[t] {
                        if !finalSelected.contains(neighbor) {
                            finalSelected.insert(neighbor)
                            nextFront.append(neighbor)
                        }
                    }
                }
                front = nextFront
            }
        }
        
        // Step 2. Erode (Anti-Aliasing/Smoothing the "Saw-tooth" jagged edges)
        // Remove triangles that have too many unselected neighbors (protruding spikes)
        var toRemoveFromSelection = Set<Int>()
        for t in finalSelected {
            var outsideNeighbors = 0
            for neighbor in adjacency[t] {
                if !finalSelected.contains(neighbor) {
                    outsideNeighbors += 1
                }
            }
            // If a triangle has 2 or 3 unselected neighbors, it's a sharp protruding point.
            // Trimming it rounds out the jagged "saw" boundary into a straighter line.
            if outsideNeighbors >= 2 {
                toRemoveFromSelection.insert(t)
            }
        }
        finalSelected.subtract(toRemoveFromSelection)

        return finalSelected
    }
    
    /// Spatially selects triangles around a line segment (capsule), interpolating the brush stroke between frame updates.
    /// Uses concurrent chunking directly over the triangle indices for ultra-fast performance.
    static func selectTrianglesInCapsule(
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        radius: Float,
        elementIndex: Int,
        state: MeshEditState
    ) -> Set<Int> {
        let centers = state.centersPerElement[elementIndex]
        let grid = state.spatialHashGrids[elementIndex]
        let cellSize = state.gridCellSize
        
        let radiusSq = radius * radius
        let ab = end - start
        let lenSq = simd_length_squared(ab)
        let useCapsule = lenSq >= .ulpOfOne
        
        // 1. Determine the 3D grid cells that intersect the capsule's bounding box
        let minBound = simd_min(start, end) - SIMD3<Float>(repeating: radius)
        let maxBound = simd_max(start, end) + SIMD3<Float>(repeating: radius)
        
        let minGrid = SIMD3<Int>(
            Int(floor(minBound.x / cellSize)),
            Int(floor(minBound.y / cellSize)),
            Int(floor(minBound.z / cellSize))
        )
        let maxGrid = SIMD3<Int>(
            Int(floor(maxBound.x / cellSize)),
            Int(floor(maxBound.y / cellSize)),
            Int(floor(maxBound.z / cellSize))
        )
        
        // 2. Collect candidate triangles ONLY from those overlapping grid cells (O(1) lookup vs O(N) iteration)
        var candidateTriangles = Set<Int>()
        // Ensure bounds are safe (just in case they got inverted somehow, which simd_min/max prevents)
        if minGrid.x <= maxGrid.x && minGrid.y <= maxGrid.y && minGrid.z <= maxGrid.z {
            for x in minGrid.x...maxGrid.x {
                for y in minGrid.y...maxGrid.y {
                    for z in minGrid.z...maxGrid.z {
                        if let cellTris = grid[SIMD3<Int>(x, y, z)] {
                            for t in cellTris {
                                candidateTriangles.insert(t)
                            }
                        }
                    }
                }
            }
        }
        
        // 3. Perform physics testing ONLY on those few candidates
        var finalSet = Set<Int>()
        for t in candidateTriangles {
            let center = centers[t]
            let distSq: Float
            if !useCapsule {
                distSq = simd_length_squared(center - end) 
            } else {
                let proj = simd_dot(center - start, ab) / lenSq
                if proj <= 0.0 {
                    distSq = simd_length_squared(center - start)
                } else if proj >= 1.0 {
                    distSq = simd_length_squared(center - end)
                } else {
                    let closest = start + proj * ab
                    distSq = simd_length_squared(center - closest)
                }
            }
            if distSq <= radiusSq {
                finalSet.insert(t)
            }
        }
        
        return finalSet
    }

    // MARK: - Triangle removal

    /// Removes `selectedTriangles` from element `elemIdx` in `state`,
    /// rebuilds the SCNGeometry, and returns it + updated state.
    @discardableResult
    static func applyRemoval(
        selected: Set<Int>,
        elementIndex: Int,
        state: MeshEditState
    ) -> SCNGeometry? {

        let currentIndices = state.indicesPerElement[elementIndex]
        let triCount = currentIndices.count / 3

        var keptFlat = [Int]()
        keptFlat.reserveCapacity(currentIndices.count)

        for t in 0..<triCount {
            if !selected.contains(t) {
                keptFlat.append(currentIndices[t * 3])
                keptFlat.append(currentIndices[t * 3 + 1])
                keptFlat.append(currentIndices[t * 3 + 2])
            }
        }

        state.indicesPerElement[elementIndex] = keptFlat

        // Rebuild adjacency for updated indices (needed for future erases)
        let newTriCount = keptFlat.count / 3
        let newAdj = buildAdjacency(indices: keptFlat, positions: state.positions, triCount: newTriCount)
        
        // Setup new per-triangle state arrays
        var newNormals = [SIMD3<Float>](repeating: .zero, count: newTriCount)
        var newCenters = [SIMD3<Float>](repeating: .zero, count: newTriCount)
        var newColors  = [SIMD3<Float>](repeating: .zero, count: newTriCount)
        var newGrid    = [SIMD3<Int>: [Int]]()
        
        let origNormals = state.normalsPerElement[elementIndex]
        let origCenters = state.centersPerElement[elementIndex]
        let origColors  = state.colorsPerElement[elementIndex]
        let cellSize    = state.gridCellSize

        // Find which old triangle indices survived
        var remapOld = [Int]()           // newIdx → oldIdx
        for t in 0..<triCount {
            if !selected.contains(t) { remapOld.append(t) }
        }
        
        // Remap old triangle state → new triangle state
        for (newT, oldT) in remapOld.enumerated() {
            if oldT < origNormals.count { newNormals[newT] = origNormals[oldT] }
            if oldT < origColors.count  { newColors[newT]  = origColors[oldT]  }
            
            if oldT < origCenters.count { 
                let center = origCenters[oldT]
                newCenters[newT] = center 
                
                // Re-populate the new spatial hash grid
                let gridPos = SIMD3<Int>(
                    Int(floor(center.x / cellSize)),
                    Int(floor(center.y / cellSize)),
                    Int(floor(center.z / cellSize))
                )
                newGrid[gridPos, default: []].append(newT)
            }
        }
        // Mutate the live state
        state.normalsPerElement[elementIndex] = newNormals
        state.centersPerElement[elementIndex] = newCenters
        state.colorsPerElement[elementIndex] = newColors
        state.adjacencyPerElement[elementIndex] = newAdj
        state.spatialHashGrids[elementIndex] = newGrid
        state.cachedChunksPerElement[elementIndex] = buildChunks(indices: keptFlat, chunkSize: state.chunkSize)

        // Build the new SCNGeometry
        return rebuildGeometry(state: state)
    }

    /// Rebuilds SCNGeometry from all current index lists in state.
    static func rebuildGeometry(state: MeshEditState) -> SCNGeometry? {
        let result = finalizeGeometry(sources: state.geometry.sources, chunkGroups: state.cachedChunksPerElement, origMaterials: state.geometry.materials)
        state.scnElementMapping = result.mapping
        return result.geometry
    }

    // MARK: - Instant Visual Removal (No Lag)

    /// Builds a temporary SCNGeometry containing everything *except* the currently selected triangles.
    /// Uses instantaneous O(1) rendering cache chunks to skip rebuilding 99% of the object.
    static func quickHide(hidden: Set<Int>, elementIndex: Int, state: MeshEditState) -> SCNGeometry? {
        if hidden.isEmpty { return nil }
        
        let chunkSize = state.chunkSize
        let currentIndices = state.indicesPerElement[elementIndex]
        let cachedChunks = state.cachedChunksPerElement[elementIndex]
        let totalTriCount = currentIndices.count / 3
        
        // Accumulate hidden triangles by their chunk partition
        var hiddenPerChunk = [Int: Set<Int>]()
        for h in hidden {
            hiddenPerChunk[h / chunkSize, default: []].insert(h)
        }
        
        var chunkGroups = [[SCNGeometryElement]]()
        
        // 1. Unmodified element chunks BEFORE target
        for idx in 0..<elementIndex {
            chunkGroups.append(state.cachedChunksPerElement[idx])
        }
        
        // 2. The TARGET partially-modified element
        var targetNewChunks = [SCNGeometryElement]()
        for chunkIdx in 0..<cachedChunks.count {
            guard let chunkHidden = hiddenPerChunk[chunkIdx] else {
                // Chunk untouched, instantly reuse existing GPU cache! O(1)
                targetNewChunks.append(cachedChunks[chunkIdx])
                continue
            }
            
            let startTri = chunkIdx * chunkSize
            let endTri = min(startTri + chunkSize, totalTriCount)
            let triCountInChunk = endTri - startTri
            
            if chunkHidden.count == triCountInChunk {
                // Chunk entirely erased. Ignore it.
            } else {
                // Chunk partially erased. Rebuild ONLY this small subset.
                var keptIndices = [Int]()
                keptIndices.reserveCapacity((triCountInChunk - chunkHidden.count) * 3)
                
                for t in startTri..<endTri {
                    if !chunkHidden.contains(t) {
                        let base = t * 3
                        keptIndices.append(currentIndices[base])
                        keptIndices.append(currentIndices[base + 1])
                        keptIndices.append(currentIndices[base + 2])
                    }
                }
                
                let data = keptIndices.map { Int32($0) }.withUnsafeBytes { Data($0) }
                targetNewChunks.append(SCNGeometryElement(
                    data: data,
                    primitiveType: .triangles,
                    primitiveCount: keptIndices.count / 3,
                    bytesPerIndex: 4
                ))
            }
        }
        chunkGroups.append(targetNewChunks)
        
        // 3. Unmodified element chunks AFTER target
        for idx in (elementIndex + 1)..<state.cachedChunksPerElement.count {
            chunkGroups.append(state.cachedChunksPerElement[idx])
        }
        
        let result = finalizeGeometry(sources: state.geometry.sources, chunkGroups: chunkGroups, origMaterials: state.geometry.materials)
        return result.geometry
    }
    
    /// Internal helper to compile the final SceneKit Geometry from 3D chunks and clone materials perfectly
    static func finalizeGeometry(sources: [SCNGeometrySource], chunkGroups: [[SCNGeometryElement]], origMaterials: [SCNMaterial]) -> (geometry: SCNGeometry?, mapping: [MeshEditState.SCNElementMapping]) {
        var flatElements = [SCNGeometryElement]()
        var flatMats = [SCNMaterial]()
        var mapping = [MeshEditState.SCNElementMapping]()
        
        let safeMats = origMaterials.map { m -> SCNMaterial in
            let mc = m.copy() as! SCNMaterial
            mc.normal.contents = nil
            return mc
        }
        
        for (i, chunks) in chunkGroups.enumerated() {
            let mat = safeMats[i % safeMats.count]
            var baseTri = 0
            for elem in chunks {
                if elem.primitiveCount > 0 {
                    flatElements.append(elem)
                    flatMats.append(mat)
                    mapping.append(MeshEditState.SCNElementMapping(originalElementIndex: i, baseTriangleIndex: baseTri))
                    baseTri += elem.primitiveCount
                }
            }
        }
        
        guard !flatElements.isEmpty else { return (nil, []) }
        
        let newGeo = SCNGeometry(sources: sources, elements: flatElements)
        newGeo.materials = flatMats
        return (newGeo, mapping)
    }
    
    // MARK: - Interactive Preview

    /// Builds a temporary SCNGeometry containing *only* the currently selected triangles.
    /// Uses instantaneous O(1) rendering cache chunks to skip massive memory allocations.
    static func previewGeometry(selected: Set<Int>, elementIndex: Int, state: MeshEditState) -> SCNGeometry? {
        if selected.isEmpty { return nil }
        
        let chunkSize = state.chunkSize
        let currentIndices = state.indicesPerElement[elementIndex]
        let cachedChunks = state.cachedChunksPerElement[elementIndex]
        let totalTriCount = currentIndices.count / 3
        
        // Accumulate selected triangles by their chunk partition
        var selectedPerChunk = [Int: Set<Int>]()
        for s in selected {
            selectedPerChunk[s / chunkSize, default: []].insert(s)
        }
        
        var flatElements = [SCNGeometryElement?](repeating: nil, count: cachedChunks.count)
        
        // Use Apple Silicon concurrent threading to build the red highlight instantly across all cores
        DispatchQueue.concurrentPerform(iterations: cachedChunks.count) { chunkIdx in
            guard let chunkSelected = selectedPerChunk[chunkIdx] else { return }
            
            let startTri = chunkIdx * chunkSize
            let endTri = min(startTri + chunkSize, totalTriCount)
            let triCountInChunk = endTri - startTri
            
            if chunkSelected.count == triCountInChunk {
                // Chunk entirely selected. Instantly reuse GPU cache! O(1)
                flatElements[chunkIdx] = cachedChunks[chunkIdx]
            } else {
                // Chunk partially selected. Build ONLY this tiny subset.
                var highlightIndices = [Int]()
                highlightIndices.reserveCapacity(chunkSelected.count * 3)
                
                for t in startTri..<endTri {
                    if chunkSelected.contains(t) {
                        let base = t * 3
                        highlightIndices.append(currentIndices[base])
                        highlightIndices.append(currentIndices[base + 1])
                        highlightIndices.append(currentIndices[base + 2])
                    }
                }
                
                let data = highlightIndices.map { Int32($0) }.withUnsafeBytes { Data($0) }
                flatElements[chunkIdx] = SCNGeometryElement(
                    data: data,
                    primitiveType: .triangles,
                    primitiveCount: highlightIndices.count / 3,
                    bytesPerIndex: 4
                )
            }
        }
        
        let validElements = flatElements.compactMap { $0 }
        
        guard !validElements.isEmpty else { return nil }
        let geo = SCNGeometry(sources: state.geometry.sources, elements: validElements)
        
        // Create an unlit bright red material for the highlight
        let redMat = SCNMaterial()
        redMat.diffuse.contents = UIColor.red.withAlphaComponent(0.8)
        redMat.lightingModel = .constant
        redMat.isDoubleSided = true
        redMat.writesToDepthBuffer = false // Prevent Z-fighting with original mesh
        redMat.readsFromDepthBuffer = false // Disable depth reads so it always draws perfectly over the object
        
        // Replicate red material for every element chunk
        geo.materials = Array(repeating: redMat, count: flatElements.count)
        
        return geo
    }

    // MARK: - Private helpers

    /// Build a triangle adjacency list crossing UV seams.
    /// To do this, we map every vertex to a unique ID based on its rounded physical 3D coordinate.
    /// This reconnects triangles that were split by invisible texture boundaries.
    private static func buildAdjacency(indices: [Int], positions: [SIMD3<Float>], triCount: Int) -> [[Int]] {
        
        var posToId = [SIMD3<Float>: Int]()
        var uniqueIndices = [Int](repeating: 0, count: indices.count)
        var nextId = 0
        
        for i in 0..<indices.count {
            let posIdx = indices[i]
            guard posIdx < positions.count else { continue }
            let pos = positions[posIdx]
            
            // Round to ~0.1mm to cleanly merge vertices split by float precision
            let rounded = SIMD3<Float>(
                round(pos.x * 10000) / 10000,
                round(pos.y * 10000) / 10000,
                round(pos.z * 10000) / 10000
            )
            if let id = posToId[rounded] {
                uniqueIndices[i] = id
            } else {
                posToId[rounded] = nextId
                uniqueIndices[i] = nextId
                nextId += 1
            }
        }
        
        // Edge → triangles that use it
        var edgeMap = [EdgeKey: [Int]]()
        edgeMap.reserveCapacity(triCount * 3)

        for t in 0..<triCount {
            let i0 = uniqueIndices[t * 3], i1 = uniqueIndices[t * 3 + 1], i2 = uniqueIndices[t * 3 + 2]
            for edge in [EdgeKey(i0, i1), EdgeKey(i1, i2), EdgeKey(i0, i2)] {
                if edge.a != edge.b { // ignore degenerate zero-length edges
                    edgeMap[edge, default: []].append(t)
                }
            }
        }

        var adj = [[Int]](repeating: [], count: triCount)
        for tris in edgeMap.values {
            // A well-formed mesh has 2 triangles per edge. Allow non-manifold hubs up to a limit.
            guard tris.count > 1 && tris.count < 10 else { continue }
            for i in 0..<tris.count {
                for j in (i+1)..<tris.count {
                    adj[tris[i]].append(tris[j])
                    adj[tris[j]].append(tris[i])
                }
            }
        }
        return adj
    }

    private static func triangleNormal(
        _ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>
    ) -> SIMD3<Float> {
        let n = simd_cross(p1 - p0, p2 - p0)
        let len = simd_length(n)
        return len > 0 ? n / len : SIMD3(0, 1, 0)
    }

    private static func extractPositions(from source: SCNGeometrySource) -> [SIMD3<Float>] {
        let count  = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        var out    = [SIMD3<Float>](repeating: .zero, count: count)
        source.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let p = base.advanced(by: offset + i * stride)
                out[i] = SIMD3(
                    p.load(as: Float.self),
                    p.advanced(by: 4).load(as: Float.self),
                    p.advanced(by: 8).load(as: Float.self)
                )
            }
        }
        return out
    }
    
    private static func extractTexcoords(from source: SCNGeometrySource) -> [SIMD2<Float>] {
        let count  = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        var out    = [SIMD2<Float>](repeating: .zero, count: count)
        source.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let p = base.advanced(by: offset + i * stride)
                out[i] = SIMD2(
                    p.load(as: Float.self),
                    p.advanced(by: 4).load(as: Float.self)
                )
            }
        }
        return out
    }

    private static func extractIndices(from element: SCNGeometryElement) -> [Int] {
        let total = element.primitiveCount * 3
        var out   = [Int](repeating: 0, count: total)
        element.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<total {
                switch element.bytesPerIndex {
                case 4: out[i] = Int(base.advanced(by: i * 4).load(as: UInt32.self))
                case 2: out[i] = Int(base.advanced(by: i * 2).load(as: UInt16.self))
                case 1: out[i] = Int(base.advanced(by: i    ).load(as: UInt8.self))
                default: break
                }
            }
        }
        return out
    }
}

// MARK: - Edge key for adjacency map

private struct EdgeKey: Hashable {
    let a: Int, b: Int
    init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
}
