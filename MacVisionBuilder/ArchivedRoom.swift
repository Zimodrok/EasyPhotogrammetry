import Foundation
import simd

// MARK: - ArchivedRoom
// A mock structure mirroring RoomPlan.CapturedRoom so we can decode the
// roomplan.json on macOS, where the RoomPlan framework is unavailable.
//
// The JSON is produced by Swift's JSONEncoder on CapturedRoom.
// Transforms are flat [Float] arrays of 16 values (column-major).
// Dimensions are [Float] arrays of 3 values.
// Categories are dictionaries like {"wall": {}} or {"door": {}}.
struct ArchivedRoom: Decodable {
    let walls: [ArchivedSurface]
    let floors: [ArchivedSurface]
    let doors: [ArchivedSurface]
    let windows: [ArchivedSurface]
    let objects: [ArchivedObject]
    
    enum CodingKeys: String, CodingKey {
        case walls, floors, doors, windows, objects
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walls = (try? container.decode([ArchivedSurface].self, forKey: .walls)) ?? []
        floors = (try? container.decode([ArchivedSurface].self, forKey: .floors)) ?? []
        doors = (try? container.decode([ArchivedSurface].self, forKey: .doors)) ?? []
        windows = (try? container.decode([ArchivedSurface].self, forKey: .windows)) ?? []
        objects = (try? container.decode([ArchivedObject].self, forKey: .objects)) ?? []
    }
}

struct ArchivedSurface: Decodable {
    let dimensions: simd_float3
    let transform: simd_float4x4
    
    enum CodingKeys: String, CodingKey {
        case dimensions, transform
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let dims = try container.decode([Float].self, forKey: .dimensions)
        self.dimensions = simd_float3(
            dims.count > 0 ? dims[0] : 0,
            dims.count > 1 ? dims[1] : 0,
            dims.count > 2 ? dims[2] : 0
        )
        
        // Transform can be either a flat [Float] of 16 values (from CapturedRoom JSON)
        // or a [[Float]] 4x4 array. Handle both.
        if let flat = try? container.decode([Float].self, forKey: .transform), flat.count >= 16 {
            // Flat array — column-major order (same as simd_float4x4 memory layout)
            self.transform = simd_float4x4(
                simd_float4(flat[0], flat[1], flat[2], flat[3]),
                simd_float4(flat[4], flat[5], flat[6], flat[7]),
                simd_float4(flat[8], flat[9], flat[10], flat[11]),
                simd_float4(flat[12], flat[13], flat[14], flat[15])
            )
        } else if let nested = try? container.decode([[Float]].self, forKey: .transform), nested.count >= 4 {
            // 4x4 nested array
            self.transform = simd_float4x4(
                simd_float4(nested[0][0], nested[0][1], nested[0][2], nested[0][3]),
                simd_float4(nested[1][0], nested[1][1], nested[1][2], nested[1][3]),
                simd_float4(nested[2][0], nested[2][1], nested[2][2], nested[2][3]),
                simd_float4(nested[3][0], nested[3][1], nested[3][2], nested[3][3])
            )
        } else {
            self.transform = matrix_identity_float4x4
        }
    }
}

struct ArchivedObject: Decodable {
    let dimensions: simd_float3
    let transform: simd_float4x4
    let category: String?
    
    enum CodingKeys: String, CodingKey {
        case dimensions, transform, category
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let dims = try container.decode([Float].self, forKey: .dimensions)
        self.dimensions = simd_float3(
            dims.count > 0 ? dims[0] : 0,
            dims.count > 1 ? dims[1] : 0,
            dims.count > 2 ? dims[2] : 0
        )
        
        // Handle both flat and nested transform formats
        if let flat = try? container.decode([Float].self, forKey: .transform), flat.count >= 16 {
            self.transform = simd_float4x4(
                simd_float4(flat[0], flat[1], flat[2], flat[3]),
                simd_float4(flat[4], flat[5], flat[6], flat[7]),
                simd_float4(flat[8], flat[9], flat[10], flat[11]),
                simd_float4(flat[12], flat[13], flat[14], flat[15])
            )
        } else if let nested = try? container.decode([[Float]].self, forKey: .transform), nested.count >= 4 {
            self.transform = simd_float4x4(
                simd_float4(nested[0][0], nested[0][1], nested[0][2], nested[0][3]),
                simd_float4(nested[1][0], nested[1][1], nested[1][2], nested[1][3]),
                simd_float4(nested[2][0], nested[2][1], nested[2][2], nested[2][3]),
                simd_float4(nested[3][0], nested[3][1], nested[3][2], nested[3][3])
            )
        } else {
            self.transform = matrix_identity_float4x4
        }
        
        // Category is {"wall": {}} or {"sofa": {}} style — extract the key name
        if let catDict = try? container.decode([String: [String: String]].self, forKey: .category),
           let cat = catDict.keys.first {
            self.category = cat
        } else if let catDict = try? container.decode([String: AnyCodable].self, forKey: .category),
                  let cat = catDict.keys.first {
            self.category = cat
        } else if let cat = try? container.decode(String.self, forKey: .category) {
            self.category = cat
        } else {
            self.category = "unknown"
        }
    }
}

// Helper for decoding arbitrary JSON values
private struct AnyCodable: Decodable {
    init(from decoder: Decoder) throws {
        // Just consume the value — we only need the key name
        _ = try? decoder.singleValueContainer()
    }
}
