import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case segments20s
    case realtimeOpenAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .segments20s:
            return "20s Segments"
        case .realtimeOpenAI:
            return "Realtime"
        }
    }

    var settingsTitle: String {
        switch self {
        case .segments20s:
            return "20s segments"
        case .realtimeOpenAI:
            return "Realtime"
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .segments20s:
            return "Reliable, queued when offline"
        case .realtimeOpenAI:
            return "Live transcript while you talk"
        }
    }
}
