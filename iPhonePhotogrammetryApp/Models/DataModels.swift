import Foundation
import CoreData

@objc(CaptureSession)
class CaptureSession: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var date: Date
    @NSManaged var imageCount: Int16
    @NSManaged var processingState: String
    @NSManaged var modelURL: URL?
}

@objc(Asset)
class Asset: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var url: URL
    @NSManaged var thumbnailData: Data?
    @NSManaged var dateImported: Date
}
