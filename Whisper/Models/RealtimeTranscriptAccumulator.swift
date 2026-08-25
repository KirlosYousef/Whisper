import Foundation

/// Shared realtime transcript assembly for both full recordings and ephemeral previews.
struct RealtimeTranscriptAccumulator {
    private var itemOrder: [String] = []
    private var itemTexts: [String: String] = [:]

    var transcript: String {
        itemOrder
            .compactMap { itemTexts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var words: [String] {
        transcript
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    mutating func reset() {
        itemOrder.removeAll()
        itemTexts.removeAll()
    }

    mutating func mergeDelta(itemID: String, text: String) {
        register(itemID)
        let current = itemTexts[itemID] ?? ""
        itemTexts[itemID] = mergedText(current: current, incoming: text)
    }

    mutating func finalize(itemID: String, transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        register(itemID)
        itemTexts[itemID] = trimmed
    }

    mutating func replace(with transcript: String) {
        reset()
        finalize(itemID: "final", transcript: transcript)
    }

    private mutating func register(_ itemID: String) {
        if !itemOrder.contains(itemID) {
            itemOrder.append(itemID)
        }
    }

    private func mergedText(current: String, incoming: String) -> String {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else { return trimmedCurrent }
        guard !trimmedCurrent.isEmpty else { return trimmedIncoming }

        if trimmedIncoming.hasPrefix(trimmedCurrent) {
            return trimmedIncoming
        }

        let incomingWords = trimmedIncoming.split(whereSeparator: \.isWhitespace)
        if incomingWords.count >= 3,
           wordOverlapRatio(between: trimmedCurrent, and: trimmedIncoming) >= 0.45 {
            return trimmedIncoming
        }

        return appendWithOverlap(current: trimmedCurrent, incoming: trimmedIncoming)
    }

    private func appendWithOverlap(current: String, incoming: String) -> String {
        let maxOverlap = min(current.count, incoming.count)
        guard maxOverlap > 0 else { return current + incoming }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if current.suffix(overlap) == incoming.prefix(overlap) {
                return current + incoming.dropFirst(overlap)
            }
        }

        if incoming.first?.isPunctuation == true {
            return current + incoming
        }
        return current + " " + incoming
    }

    private func wordOverlapRatio(between lhs: String, and rhs: String) -> Double {
        let lhsWords = Set(lhs.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        let rhsWords = Set(rhs.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return 0 }

        let intersection = lhsWords.intersection(rhsWords).count
        let union = lhsWords.union(rhsWords).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
}

enum TranscriptLanguageProcessor {
    static func translate(_ transcript: String, to targetCode: String?) async -> String {
        guard let targetCode, !targetCode.isEmpty else { return transcript }
        let translated = await SummaryService.translate(text: transcript, to: targetCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? transcript : translated
    }
}
