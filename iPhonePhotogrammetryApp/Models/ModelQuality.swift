import Foundation
import RealityKit

enum ModelQuality: String, CaseIterable, Identifiable, Codable {
    case preview = "Preview"
    case reduced = "Reduced"
    case medium = "Medium"
    case full = "Full"
    case raw = "Raw"
    
    var id: String { self.rawValue }
    
    var detail: RealityKit.PhotogrammetrySession.Request.Detail {
        #if os(macOS)
        switch self {
        case .preview: return .preview
        case .reduced: return .reduced
        case .medium: return .medium
        case .full: return .full
        case .raw: return .raw
        }
        #else
        return .reduced
        #endif
    }
}
