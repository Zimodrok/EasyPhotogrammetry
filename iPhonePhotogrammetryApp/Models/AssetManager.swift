import Foundation
import RealityKit
import Combine
import os.log

// MARK: - Physical Measurement
struct PhysicalMeasurement: Sendable {
    enum Dimension {
        case width, height, depth
    }
    
    let dimension: Dimension
    let valueInMeters: Float
}

