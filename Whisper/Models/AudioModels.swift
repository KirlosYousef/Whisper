//
//  AudioModels.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import SwiftData

@Model
public final class Recording: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var duration: TimeInterval
    public var filePath: String
    public var summary: String?
    public var todoList: [String]?
    public var keywords: [String]?
    public var title: String?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptionSegment.recording) public var segments: [TranscriptionSegment] = []
    
    public init(id: UUID = UUID(), createdAt: Date = Date(), duration: TimeInterval, filePath: String, title: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.filePath = filePath
        self.title = title
    }
    
    var sortedSegments: [TranscriptionSegment] {
        segments.sorted { $0.timestamp < $1.timestamp }
    }
    
    var fullTranscript: String {
        sortedSegments
            .filter { $0.status == "completed" }
            .map { $0.text }
            .joined(separator: " ")
    }
}

@Model
public final class TranscriptionSegment: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var text: String
    public var status: String // e.g., "pending", "processing", "completed", "failed"
    public var timestamp: TimeInterval // Start time of segment in seconds
    public var filePath: String = "" // Per-segment audio file path
    @Relationship public var recording: Recording?
    
    public init(id: UUID = UUID(), text: String = "", status: String = "pending", timestamp: TimeInterval, filePath: String, recording: Recording? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.timestamp = timestamp
        self.filePath = filePath
        self.recording = recording
    }

    // Backwards-compatible initializer used in tests and call sites that don't provide filePath
    public init(id: UUID = UUID(), text: String = "", status: String = "pending", timestamp: TimeInterval, recording: Recording? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.timestamp = timestamp
        self.filePath = ""
        self.recording = recording
    }
}
