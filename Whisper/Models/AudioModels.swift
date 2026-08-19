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
    public var transcriptionModeRawValue: String?
    public var speakerIdentificationStatus: String = "skipped"
    public var speakerCount: Int = 0
    public var speakerDisplayNamesJSON: String = "{}"
    @Relationship(deleteRule: .cascade, inverse: \TranscriptionSegment.recording) public var segments: [TranscriptionSegment] = []
    
    public init(id: UUID = UUID(), createdAt: Date = Date(), duration: TimeInterval, filePath: String, title: String? = nil, transcriptionModeRawValue: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.filePath = filePath
        self.title = title
        self.transcriptionModeRawValue = transcriptionModeRawValue
        self.speakerIdentificationStatus = SpeakerIdentificationStatus.skipped.rawValue
        self.speakerCount = 0
        self.speakerDisplayNamesJSON = "{}"
    }
    
    var sortedSegments: [TranscriptionSegment] {
        segments.sorted { $0.timestamp < $1.timestamp }
    }

    var speakerStatus: SpeakerIdentificationStatus {
        get { SpeakerIdentificationStatus(rawValue: speakerIdentificationStatus) ?? .skipped }
        set { speakerIdentificationStatus = newValue.rawValue }
    }

    var hasSpeakerLabels: Bool {
        sortedSegments.contains { segment in
            segment.status == "completed" && !(segment.speakerKey?.isEmpty ?? true)
        }
    }

    func speakerKeysInAppearanceOrder() -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for segment in sortedSegments {
            guard let key = segment.speakerKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty,
                  !seen.contains(key) else { continue }
            seen.insert(key)
            order.append(key)
        }
        return order
    }

    func displayName(for speakerKey: String) -> String {
        let names = decodedDisplayNames()
        if let custom = names[speakerKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let index = speakerKeysInAppearanceOrder().firstIndex(of: speakerKey) {
            return "Speaker \(index + 1)"
        }
        return "Speaker \(speakerKey)"
    }

    func setDisplayName(_ name: String, for speakerKey: String) {
        var names = decodedDisplayNames()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: speakerKey)
        } else {
            names[speakerKey] = trimmed
        }
        if let data = try? JSONSerialization.data(withJSONObject: names, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            speakerDisplayNamesJSON = json
        }
    }

    var attributedTranscript: String {
        sortedSegments
            .filter { $0.status == "completed" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { segment in
                let key = segment.speakerKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = key.isEmpty ? "Speaker" : displayName(for: key)
                return "\(name): \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            .joined(separator: "\n\n")
    }
    
    var fullTranscript: String {
        if hasSpeakerLabels {
            return attributedTranscript
        }
        return sortedSegments
            .filter { $0.status == "completed" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.text }
            .joined(separator: " ")
    }

    var speakerListSubtitle: String? {
        guard speakerStatus == .completed, speakerCount > 0 else { return nil }
        let keys = speakerKeysInAppearanceOrder()
        let names = keys.map { displayName(for: $0) }
        if names.contains(where: { !$0.hasPrefix("Speaker ") }) {
            return names.joined(separator: ", ")
        }
        return speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers"
    }

    func snippet(for speakerKey: String, maxCharacters: Int = 80) -> String {
        let text = sortedSegments
            .first { $0.speakerKey == speakerKey && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func decodedDisplayNames() -> [String: String] {
        guard let data = speakerDisplayNamesJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }
}

@Model
public final class TranscriptionSegment: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var text: String
    public var status: String // e.g., "pending", "processing", "completed", "failed"
    public var timestamp: TimeInterval // Start time of segment in seconds
    public var filePath: String = "" // Per-segment audio file path
    public var speakerKey: String?
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = 0
    public var sessionFilePath: String = ""
    @Relationship public var recording: Recording?
    
    public init(id: UUID = UUID(), text: String = "", status: String = "pending", timestamp: TimeInterval, filePath: String, recording: Recording? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.timestamp = timestamp
        self.filePath = filePath
        self.speakerKey = nil
        self.startTime = timestamp
        self.endTime = 0
        self.sessionFilePath = ""
        self.recording = recording
    }

    // Backwards-compatible initializer used in tests and call sites that don't provide filePath
    public init(id: UUID = UUID(), text: String = "", status: String = "pending", timestamp: TimeInterval, recording: Recording? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.timestamp = timestamp
        self.filePath = ""
        self.speakerKey = nil
        self.startTime = timestamp
        self.endTime = 0
        self.sessionFilePath = ""
        self.recording = recording
    }

    public init(
        id: UUID = UUID(),
        text: String,
        status: String,
        timestamp: TimeInterval,
        filePath: String,
        speakerKey: String?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        sessionFilePath: String,
        recording: Recording? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.timestamp = timestamp
        self.filePath = filePath
        self.speakerKey = speakerKey
        self.startTime = startTime
        self.endTime = endTime
        self.sessionFilePath = sessionFilePath
        self.recording = recording
    }

    var playbackStart: TimeInterval {
        startTime > 0 ? startTime : timestamp
    }

    var playbackEnd: TimeInterval {
        endTime > playbackStart ? endTime : playbackStart
    }

    var canPlayRangedSession: Bool {
        !(speakerKey?.isEmpty ?? true) && endTime > playbackStart
    }
}
