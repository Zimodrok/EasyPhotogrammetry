@preconcurrency import SceneKit
import ARKit

// MARK: - LiveMeshOverlay
// Renders real-time LiDAR mesh as a color-coded wireframe overlay during
// scanning. Attach to an ARSCNView via setDelegate().
// Green = high confidence, Yellow = medium, Red = low.
final class LiveMeshOverlay: NSObject, @unchecked Sendable {

    // Mesh node cache — only touched on @MainActor
    @MainActor private var meshNodes: [UUID: SCNNode] = [:]
    private weak var scnView: ARSCNView?

    // Published stats — only on @MainActor
    @MainActor private(set) var highConfidenceRatio: Float = 0
    @MainActor private(set) var totalFaces: Int = 0

    // nonisolated(unsafe): created once, never mutated — safe to read from render thread
    nonisolated(unsafe) private static let highMat  = LiveMeshOverlay.wireMaterial(color: .systemGreen,  opacity: 0.55)
    nonisolated(unsafe) private static let midMat   = LiveMeshOverlay.wireMaterial(color: .systemYellow, opacity: 0.45)
    nonisolated(unsafe) private static let lowMat   = LiveMeshOverlay.wireMaterial(color: .systemRed,    opacity: 0.4)
    nonisolated(unsafe) private static let noDepMat = LiveMeshOverlay.wireMaterial(color: .systemCyan,   opacity: 0.3)

    @MainActor func attach(to view: ARSCNView) {
        self.scnView = view
        view.delegate = self
        print(" LiveMeshOverlay: attached to ARSCNView")
    }

    @MainActor func detach() {
        scnView?.delegate = nil
        meshNodes.values.forEach { $0.removeFromParentNode() }
        meshNodes.removeAll()
        scnView = nil
    }

    // MARK: - Geometry Building (nonisolated — called on SceneKit render thread)

    nonisolated func buildGeometryNode(for anchor: ARMeshAnchor) -> SCNNode {
        let geo = anchor.geometry
        let node = SCNNode()

        // Split faces per-confidence if available
        let faceCount = geo.faces.count
        let vertBytes = geo.vertices.buffer.contents()
        let faceBytes = geo.faces.buffer.contents()
        let confBytes = geo.classification?.buffer.contents() // nil on non-LiDAR

        // Collect vertices
        var verts: [SCNVector3] = []
        verts.reserveCapacity(geo.vertices.count)
        for i in 0..<geo.vertices.count {
            let ptr = vertBytes
                .advanced(by: i * geo.vertices.stride + geo.vertices.offset)
                .assumingMemoryBound(to: Float.self)
            verts.append(SCNVector3(ptr[0], ptr[1], ptr[2]))
        }

        // Group face indices by confidence band (or single group if no LiDAR)
        var highIdx: [Int32] = []; var midIdx: [Int32] = []; var lowIdx: [Int32] = []
        var noDepIdx: [Int32] = []

        let bpi = geo.faces.bytesPerIndex
        for f in 0..<faceCount {
            let base = f * 3 * bpi
            let i0: Int32
            let i1: Int32
            let i2: Int32
            if bpi == 4 {
                let p = faceBytes.advanced(by: base).assumingMemoryBound(to: UInt32.self)
                i0 = Int32(p[0]); i1 = Int32(p[1]); i2 = Int32(p[2])
            } else {
                let p = faceBytes.advanced(by: base).assumingMemoryBound(to: UInt16.self)
                i0 = Int32(p[0]); i1 = Int32(p[1]); i2 = Int32(p[2])
            }

            // Confidence: 0=notConf, 1=low, 2=medium, 3=high
            let conf: UInt8
            if let cb = confBytes {
                conf = cb.advanced(by: f).assumingMemoryBound(to: UInt8.self).pointee
            } else {
                conf = 255  // no LiDAR data
            }

            switch conf {
            case 3:       highIdx += [i0, i1, i2]
            case 2:       midIdx  += [i0, i1, i2]
            case 1:       lowIdx  += [i0, i1, i2]
            case 255:     noDepIdx += [i0, i1, i2]
            default:      lowIdx  += [i0, i1, i2]
            }
        }

        // Build vertex source once
        let vertData = Data(bytes: verts, count: verts.count * MemoryLayout<SCNVector3>.stride)
        let vertSrc = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.stride
        )

        func addElement(_ indices: [Int32], mat: SCNMaterial) {
            guard !indices.isEmpty else { return }
            let elData = Data(bytes: indices, count: indices.count * 4)
            let el = SCNGeometryElement(
                data: elData, primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: 4
            )
            let geo = SCNGeometry(sources: [vertSrc], elements: [el])
            geo.materials = [mat]
            let child = SCNNode(geometry: geo)
            node.addChildNode(child)
        }

        addElement(highIdx,  mat: LiveMeshOverlay.highMat)
        addElement(midIdx,   mat: LiveMeshOverlay.midMat)
        addElement(lowIdx,   mat: LiveMeshOverlay.lowMat)
        addElement(noDepIdx, mat: LiveMeshOverlay.noDepMat)

        // Apply anchor world transform
        node.simdTransform = anchor.transform
        return node
    }

    // MARK: - Stats Update (@MainActor)

    @MainActor private func updateStats() {
        var high = 0; var total = 0
        for node in meshNodes.values {
            node.childNodes.enumerated().forEach { i, child in
                let fc = child.geometry?.elements.first?.primitiveCount ?? 0
                total += fc
                if i == 0 { high += fc }   // first child = high confidence
            }
        }
        totalFaces = total
        highConfidenceRatio = total > 0 ? Float(high) / Float(total) : 0
    }

    // MARK: - Material Factory (nonisolated — called on render thread)

    nonisolated private static func wireMaterial(color: UIColor, opacity: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color.withAlphaComponent(opacity)
        m.fillMode = .lines
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }
}

// MARK: - ARSCNViewDelegate
extension LiveMeshOverlay: ARSCNViewDelegate {

    // Build geometry on SceneKit's render thread (thread-safe for SCNNode mutations
    // called from delegate callbacks per Apple docs), then only touch the
    // @MainActor-isolated dictionary on the main actor.

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        // Build and add child entirely on the render thread — no MainActor needed
        let meshNode = buildGeometryNode(for: meshAnchor)
        node.addChildNode(meshNode)
        // Only the dictionary write requires @MainActor isolation
        let anchorID = meshAnchor.identifier
        Task { @MainActor [meshNode] in
            self.meshNodes[anchorID] = meshNode
            self.updateStats()
        }
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        // Remove all previous children added by this overlay for this anchor
        node.childNodes.forEach { $0.removeFromParentNode() }
        let meshNode = buildGeometryNode(for: meshAnchor)
        node.addChildNode(meshNode)
        let anchorID = meshAnchor.identifier
        Task { @MainActor [meshNode] in
            self.meshNodes[anchorID] = meshNode
            self.updateStats()
        }
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.childNodes.forEach { $0.removeFromParentNode() }
        let anchorID = meshAnchor.identifier
        Task { @MainActor in
            self.meshNodes.removeValue(forKey: anchorID)
            self.updateStats()
        }
    }
}
