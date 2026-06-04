import SwiftUI
import RealityKit
import ARKit
import RoomPlan
import simd

@MainActor
final class RoomGuidanceOverlay {
    
    private let rootAnchor = AnchorEntity(world: .zero)
    private var surfaceEntities: [UUID: ModelEntity] = [:]
    private var instantiatedCells: [UUID: Set<SIMD2<Int>>] = [:]
    
    private let cellSize: Float = 0.15
    
    private var pendingMaterials: UnlitMaterial = {
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.systemBlue.withAlphaComponent(0.12))
        mat.blending = .transparent(opacity: 0.12)
        return mat
    }()
    
    private var paintedMaterials: UnlitMaterial = {
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.systemGreen.withAlphaComponent(0.75)) // Strong solid Green
        mat.blending = .transparent(opacity: 0.75)
        return mat
    }()
    
    private var activeMaterials: UnlitMaterial = {
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.cyan.withAlphaComponent(0.90))
        mat.blending = .transparent(opacity: 0.90)
        return mat
    }()

    func attach(to arView: ARView) {
        arView.scene.addAnchor(rootAnchor)
        rootAnchor.name = "RoomGuidanceOverlay"
        print(" RoomGuidanceOverlay: attached")
    }
    
    func detach() {
        rootAnchor.removeFromParent()
        surfaceEntities.removeAll()
        instantiatedCells.removeAll()
    }
    
    func update(with room: CapturedRoom) {
        var currentUUIDs: Set<UUID> = []
        
        for wall in room.walls {
            currentUUIDs.insert(wall.identifier)
            updateSurface(id: wall.identifier, dimensions: wall.dimensions, transform: wall.transform)
        }
        
        for floor in room.floors {
            currentUUIDs.insert(floor.identifier)
            updateSurface(id: floor.identifier, dimensions: floor.dimensions, transform: floor.transform)
        }
        
        for obj in room.objects {
            currentUUIDs.insert(obj.identifier)
            updateObjectVolume(id: obj.identifier, dimensions: obj.dimensions, transform: obj.transform)
        }
        
        let stale = Set(surfaceEntities.keys).subtracting(currentUUIDs)
        for id in stale {
            surfaceEntities[id]?.removeFromParent()
            surfaceEntities.removeValue(forKey: id)
            instantiatedCells.removeValue(forKey: id)
        }
    }
    
    func paintFromCamera(cameraTransform: simd_float4x4) {
        let camPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let camForward = normalize(SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z))
        
        for (id, entity) in surfaceEntities {
            let worldTransform = entity.transformMatrix(relativeTo: nil)
            let invTransform = simd_inverse(worldTransform)
            
            let vOrigin = invTransform * SIMD4<Float>(camPos, 1)
            let localOrigin = SIMD3<Float>(vOrigin.x, vOrigin.y, vOrigin.z)
            let vDir = invTransform * SIMD4<Float>(camForward, 0)
            let localDir = normalize(SIMD3<Float>(vDir.x, vDir.y, vDir.z))
            
            if abs(localDir.z) < 0.05 { continue }
            
            let t = -localOrigin.z / localDir.z
            guard t > 0 && t < 3.5 else { continue }
            
            let hitPoint = localOrigin + localDir * t
            let bounds = entity.model?.mesh.bounds ?? BoundingBox(min: .zero, max: .zero)
            
            if hitPoint.x >= bounds.min.x && hitPoint.x <= bounds.max.x &&
               hitPoint.y >= bounds.min.y && hitPoint.y <= bounds.max.y {
                
                let gridX = Int(floor(hitPoint.x / cellSize))
                let gridY = Int(floor(hitPoint.y / cellSize))
                let cell = SIMD2<Int>(gridX, gridY)
                
                // Find or create the active focus marker (reused to prevent allocation overhead and flickering)
                let activeMarker: ModelEntity
                if let existing = entity.children.first(where: { $0.name == "active_focus" }) as? ModelEntity {
                    activeMarker = existing
                } else {
                    let activeMesh = MeshResource.generatePlane(width: cellSize * 1.05, height: cellSize * 1.05)
                    activeMarker = ModelEntity(mesh: activeMesh, materials: [activeMaterials])
                    activeMarker.name = "active_focus"
                    entity.addChild(activeMarker)
                }
                activeMarker.position = SIMD3<Float>(Float(cell.x)*cellSize + cellSize/2, Float(cell.y)*cellSize + cellSize/2, 0.015)
                
                var cells = instantiatedCells[id] ?? []
                if !cells.contains(cell) {
                    cells.insert(cell)
                    instantiatedCells[id] = cells
                    
                    let staticMesh = MeshResource.generatePlane(width: cellSize * 0.98, height: cellSize * 0.98)
                    let staticMarker = ModelEntity(mesh: staticMesh, materials: [paintedMaterials])
                    staticMarker.position = SIMD3<Float>(Float(cell.x)*cellSize + cellSize/2, Float(cell.y)*cellSize + cellSize/2, 0.01)
                    entity.addChild(staticMarker)
                }
            }
        }
    }
    
    private func updateSurface(id: UUID, dimensions: SIMD3<Float>, transform: simd_float4x4) {
        if let entity = surfaceEntities[id] {
            entity.transform = Transform(matrix: transform)
        } else {
            let mesh = MeshResource.generatePlane(width: dimensions.x, height: dimensions.y)
            let entity = ModelEntity(mesh: mesh, materials: [pendingMaterials])
            entity.transform = Transform(matrix: transform)
            surfaceEntities[id] = entity
            rootAnchor.addChild(entity)
        }
    }
    
    private func updateObjectVolume(id: UUID, dimensions: SIMD3<Float>, transform: simd_float4x4) {
        if let entity = surfaceEntities[id] {
            entity.transform = Transform(matrix: transform)
        } else {
            let mesh = MeshResource.generatePlane(width: dimensions.x, height: dimensions.z)
            let entity = ModelEntity(mesh: mesh, materials: [pendingMaterials])
            
            var localTransform = transform
            let upVector = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
            let offset = normalize(upVector) * (dimensions.y * 0.5)
            localTransform.columns.3.x += offset.x
            localTransform.columns.3.y += offset.y
            localTransform.columns.3.z += offset.z
            
            entity.transform = Transform(matrix: localTransform)
            surfaceEntities[id] = entity
            rootAnchor.addChild(entity)
        }
    }
}
