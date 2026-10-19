//
//  DiarizationChunking.swift
//  Whisper
//

import Foundation

/// A contiguous slice of a recording, in seconds from the start of the recording.
struct DiarizationChunkRange: Equatable {
    var start: TimeInterval
    var duration: TimeInterval

    var end: TimeInterval { start + duration }
}

/// Splits a recording into the consecutive ranges that are sent to the diarization endpoint.
/// Pure and deterministic: the same duration always yields the same ranges, so retries replay
/// identical requests on the server.
enum DiarizationChunkPlanner {
    static let maxChunkDuration: TimeInterval = 1200
    static let minTailDuration: TimeInterval = 60
    static let maxMergedChunkDuration: TimeInterval = 1380

    static func plan(totalDuration: TimeInterval) -> [DiarizationChunkRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }

        let chunkCount = Int(ceil(totalDuration / maxChunkDuration))
        var lengths = [TimeInterval](repeating: maxChunkDuration, count: max(chunkCount, 1))
        lengths[lengths.count - 1] = totalDuration - maxChunkDuration * TimeInterval(lengths.count - 1)

        // Avoid a tiny tail chunk: fold it into the previous chunk when that stays within the cap,
        // otherwise rebalance the last two chunks evenly.
        if lengths.count >= 2, let tail = lengths.last, tail < minTailDuration {
            let previous = lengths[lengths.count - 2]
            let combined = previous + tail
            if combined <= maxMergedChunkDuration {
                lengths.removeLast()
                lengths[lengths.count - 1] = combined
            } else {
                lengths[lengths.count - 2] = combined / 2
                lengths[lengths.count - 1] = combined - combined / 2
            }
        }

        var ranges: [DiarizationChunkRange] = []
        ranges.reserveCapacity(lengths.count)
        var cursor: TimeInterval = 0
        for length in lengths {
            ranges.append(DiarizationChunkRange(start: cursor, duration: length))
            cursor += length
        }
        return ranges
    }
}

/// Keeps speaker keys consistent across chunks and shifts chunk-local times onto the whole recording.
enum DiarizationChunkMerger {
    static let knownSpeakerPrefix = "known_"

    /// Maps one chunk's speaker labels to recording-wide keys.
    /// Chunk 0 defines the canonical keys and is returned unchanged. In later chunks a `known_<key>`
    /// label maps back to `<key>`, and any other label is a new speaker namespaced as `<label>-<chunkIndex>`.
    static func remap(turns: [DiarizedTurn], chunkIndex: Int) -> [DiarizedTurn] {
        guard chunkIndex > 0 else { return turns }
        return turns.map { turn in
            var remapped = turn
            if turn.speakerKey.hasPrefix(knownSpeakerPrefix) {
                remapped.speakerKey = String(turn.speakerKey.dropFirst(knownSpeakerPrefix.count))
            } else {
                remapped.speakerKey = "\(turn.speakerKey)-\(chunkIndex)"
            }
            return remapped
        }
    }

    /// Combines per-chunk results (already remapped) into one recording-level result.
    static func merge(chunks: [(offset: TimeInterval, result: DiarizationResult)]) -> DiarizationResult {
        guard let last = chunks.last else {
            return DiarizationResult(duration: 0, text: "", turns: [])
        }

        var turns: [DiarizedTurn] = []
        var texts: [String] = []
        for chunk in chunks {
            turns.append(contentsOf: chunk.result.turns.map { turn in
                var shifted = turn
                shifted.start += chunk.offset
                shifted.end += chunk.offset
                return shifted
            })
            let text = chunk.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                texts.append(text)
            }
        }

        turns.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }

        return DiarizationResult(
            duration: last.offset + last.result.duration,
            text: texts.joined(separator: " "),
            turns: SpeakerDiarizationParser.mergeAdjacentTurns(turns)
        )
    }
}

/// A clip from the recording that identifies one speaker in later chunks.
struct DiarizationSpeakerReference: Equatable {
    var speakerKey: String
    var start: TimeInterval
    var duration: TimeInterval
}

enum DiarizationReferenceSelector {
    static let minTurnDuration: TimeInterval = 2
    static let maxClipDuration: TimeInterval = 10
    static let maxSpeakers = 4

    /// For each speaker with at least one turn of `minTurnDuration` or longer, picks that speaker's
    /// longest such turn. Returns at most `maxSpeakers`, ordered by total talk time.
    static func select(from turns: [DiarizedTurn]) -> [DiarizationSpeakerReference] {
        var talkTime: [String: TimeInterval] = [:]
        var longestTurn: [String: DiarizedTurn] = [:]

        for turn in turns {
            let duration = max(0, turn.end - turn.start)
            talkTime[turn.speakerKey, default: 0] += duration

            guard duration >= minTurnDuration else { continue }
            if let current = longestTurn[turn.speakerKey] {
                if duration > max(0, current.end - current.start) {
                    longestTurn[turn.speakerKey] = turn
                }
            } else {
                longestTurn[turn.speakerKey] = turn
            }
        }

        let ranked = longestTurn.keys.sorted { lhs, rhs in
            let lhsTime = talkTime[lhs, default: 0]
            let rhsTime = talkTime[rhs, default: 0]
            if lhsTime == rhsTime {
                return lhs < rhs
            }
            return lhsTime > rhsTime
        }

        return ranked.prefix(maxSpeakers).compactMap { key in
            guard let turn = longestTurn[key] else { return nil }
            return DiarizationSpeakerReference(
                speakerKey: key,
                start: turn.start,
                duration: min(maxClipDuration, turn.end - turn.start)
            )
        }
    }
}
