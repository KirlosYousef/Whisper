import Foundation
import SwiftData

@Model
final class Recording: Identifiable {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var filePath: String
    @Relationship(deleteRule: .cascade, inverse: \TranscriptionSegment.recording) var segments: [TranscriptionSegment] = []
    
    init(id: UUID = UUID(), createdAt: Date = Date(), duration: TimeInterval, filePath: String) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.filePath = filePath
    }
}

@Model
final class TranscriptionSegment: Identifiable {
    @Attribute(.unique) var id: UUID
    var text: String
    var status: String // e.g., "pending", "processing", "completed", "failed"
    var timestamp: TimeInterval // Start time of segment in seconds
    @Relationship var recording: Recording?
    
    init(id: UUID = UUID(), text: String = "", status: String = "pending", timestamp: TimeInterval, recording: Recording? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.timestamp = timestamp
        self.recording = recording
    }
}
