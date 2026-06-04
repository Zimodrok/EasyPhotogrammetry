import RealityKit
import SwiftUI

@MainActor
class GuidanceOverlay {
    
    private var anchorEntity: AnchorEntity?
    /// Markers indexed by SectorKey for fast lookup
    private var markerMap: [SectorKey: ModelEntity] = [:]
    
    /// Whether the guide dome has been placed in the scene
    var isPlaced: Bool { anchorEntity != nil }
    
    // MARK: - Ring Elevation Angles
    
    /// Elevation angles (degrees) for each ring tier
    private let ringElevations: [Float] = [15, 40, 65]  // low, mid, top
    
    // MARK: - Create Igloo Dome
    
    /// Creates igloo-shaped guide markers, scaled by RingConfig.
    func createIglooDome(
        center: SIMD3<Float>,
        radius: Float = 0.15,
        config: RingConfig
    ) -> AnchorEntity {
        removeGuidance()
        
        let anchor = AnchorEntity(world: center)
        let r = max(0.08, min(0.25, radius))
        
        for (ringIndex, sectorCount) in config.sectorsPerRing.enumerated() {
            let elevRad = ringElevations[ringIndex] * .pi / 180
            let ringRadius = r * cos(elevRad)
            let y = r * sin(elevRad)
            
            for sectorIndex in 0..<sectorCount {
                let yawAngle = 2 * Float.pi * Float(sectorIndex) / Float(sectorCount)
                let x = ringRadius * cos(yawAngle)
                let z = ringRadius * sin(yawAngle)
                
                let position = SIMD3<Float>(x, y, z)
                let marker = createTiltedMarker(
                    at: position,
                    yawAngle: yawAngle,
                    tiltInward: elevRad
                )
                anchor.addChild(marker)
                
                let key = SectorKey(ring: ringIndex, sector: sectorIndex)
                markerMap[key] = marker
            }
        }
        
        anchorEntity = anchor
        print(" Igloo dome — \(config.totalMarkers) markers (\(config.sectorsPerRing)) at radius \(String(format: "%.2f", r))m")
        return anchor
    }
    
    // MARK: - Update Sector States
    
    func updateSectors(filledSectors: Set<SectorKey>, partiallyCoveredSectors: Set<SectorKey>) {
        for (key, marker) in markerMap {
            let isFilled = filledSectors.contains(key)
            let isPartial = !isFilled && partiallyCoveredSectors.contains(key)
            
            var material = UnlitMaterial()
            let scale: Float
            
            if isFilled {
                material.color = .init(tint: .green.withAlphaComponent(0.45))
                material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
                scale = 0.6
            } else if isPartial {
                material.color = .init(tint: .yellow.withAlphaComponent(0.55))
                material.blending = .transparent(opacity: .init(floatLiteral: 0.55))
                scale = 1.0
            } else {
                material.color = .init(tint: .cyan.withAlphaComponent(0.65))
                material.blending = .transparent(opacity: .init(floatLiteral: 0.65))
                scale = 1.0
            }
            
            marker.model?.materials = [material]
            marker.scale = SIMD3<Float>(repeating: scale)
        }
    }
    
    // MARK: - Cleanup
    
    func removeGuidance() {
        anchorEntity?.removeFromParent()
        anchorEntity = nil
        markerMap.removeAll()
    }
    
    // MARK: - Private
    
    private func createTiltedMarker(
        at position: SIMD3<Float>,
        yawAngle: Float,
        tiltInward: Float
    ) -> ModelEntity {
        let mesh = MeshResource.generatePlane(width: 0.025, height: 0.035)
        
        var material = UnlitMaterial()
        material.color = .init(tint: .cyan.withAlphaComponent(0.65))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.65))
        
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        
        // Stand up, face outward, tilt inward ~80%
        let standUp = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let faceOut = simd_quatf(angle: yawAngle + .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let tiltAxis = SIMD3<Float>(cos(yawAngle + .pi / 2), 0, sin(yawAngle + .pi / 2))
        let tilt = simd_quatf(angle: -tiltInward * 0.15, axis: tiltAxis)
        
        entity.orientation = tilt * faceOut * standUp
        
        return entity
    }
}
