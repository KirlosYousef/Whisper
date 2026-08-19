//
//  SpeakerDiarization.swift
//  Whisper
//

import Foundation
import SwiftUI

enum SpeakerIdentificationStatus: String {
    case pending
    case processing
    case completed
    case failed
    case skipped
}

struct DiarizedTurn: Equatable {
    var speakerKey: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct DiarizationResult: Equatable {
    var duration: TimeInterval
    var text: String
    var turns: [DiarizedTurn]
}

enum SpeakerDiarizationParser {
    static func parse(_ data: Data) throws -> DiarizationResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.invalidResponse
        }

        let duration = (json["duration"] as? NSNumber)?.doubleValue
            ?? (json["duration"] as? Double)
            ?? 0
        let combinedText = json["text"] as? String ?? ""
        let rawSegments = json["segments"] as? [[String: Any]] ?? []

        var turns: [DiarizedTurn] = []
        turns.reserveCapacity(rawSegments.count)

        for segment in rawSegments {
            let speaker = (segment["speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !speaker.isEmpty, !text.isEmpty else { continue }

            let start = timeValue(segment["start"])
            let end = timeValue(segment["end"])
            turns.append(
                DiarizedTurn(
                    speakerKey: speaker,
                    start: start,
                    end: max(end, start),
                    text: text
                )
            )
        }

        turns.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }

        return DiarizationResult(duration: duration, text: combinedText, turns: turns)
    }

    static func mergeAdjacentTurns(_ turns: [DiarizedTurn], gap: TimeInterval = 0.4) -> [DiarizedTurn] {
        guard !turns.isEmpty else { return [] }

        var merged: [DiarizedTurn] = []
        merged.reserveCapacity(turns.count)

        for turn in turns {
            let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var current = turn
            current.text = trimmed

            guard let last = merged.last,
                  last.speakerKey == current.speakerKey,
                  current.start - last.end < gap else {
                merged.append(current)
                continue
            }

            let joined = [last.text, current.text]
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            merged[merged.count - 1] = DiarizedTurn(
                speakerKey: last.speakerKey,
                start: last.start,
                end: max(last.end, current.end),
                text: joined
            )
        }

        return merged
    }

    private static func timeValue(_ value: Any?) -> TimeInterval {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return TimeInterval(int)
        }
        if let string = value as? String, let double = Double(string) {
            return double
        }
        return 0
    }
}

enum SpeakerStyle {
    static let palette: [Color] = [
        Color(hex: 0x4F8CFF),
        Color(hex: 0xE05A5A),
        Color(hex: 0x2BB673),
        Color(hex: 0xC77DFF),
        Color(hex: 0xF0A202),
        Color(hex: 0x00B4D8),
        Color(hex: 0xEF476F),
        Color(hex: 0x06D6A0),
        Color(hex: 0x7B61FF),
        Color(hex: 0xFF7A59),
        Color(hex: 0x3DDC97),
        Color(hex: 0x5B8DEF)
    ]

    static func color(for speakerKey: String) -> Color {
        let hash = speakerKey.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    static func initial(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

enum SpeakerTimeFormatting {
    static func clock(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    static func range(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(clock(start)) – \(clock(end))"
    }

    static func compactRange(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(clock(start))–\(clock(end))"
    }
}
