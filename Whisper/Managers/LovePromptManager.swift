//
//  LovePromptManager.swift
//  Whisper
//

import Foundation
import SwiftUI

@MainActor
final class LovePromptManager: ObservableObject {
    static let shared = LovePromptManager()

    static let appStoreID = "6748306699"

    enum Trigger: String {
        case askAct
        case shareOrExport
        case secondRecording
        case twoPlaybacks
    }

    @Published var isPresented = false
    @Published private(set) var lastTrigger: Trigger?

    @AppStorage("lovePromptCompleted") private var completed = false
    @AppStorage("lovePromptRecordingCount") private var recordingCount = 0
    @AppStorage("lovePromptPlayedRecordingIds") private var playedIdsRaw = ""

    private var isScheduled = false

    private init() {}

    var hasCompletedPrompt: Bool { completed }

    func noteAskAct() {
        schedule(.askAct, delay: 1.2)
    }

    func noteShareOrExport(delay: TimeInterval = 1.0) {
        schedule(.shareOrExport, delay: delay)
    }

    func noteRecordingFinished(duration: TimeInterval) {
        guard duration >= 3 else { return }
        recordingCount += 1
        if recordingCount >= 2 {
            schedule(.secondRecording, delay: 1.4)
        }
    }

    func notePlaybackFinished(recordingId: UUID) {
        var ids = Set(playedIdsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let inserted = ids.insert(recordingId.uuidString).inserted
        guard inserted else { return }
        playedIdsRaw = ids.sorted().joined(separator: ",")
        if ids.count >= 2 {
            schedule(.twoPlaybacks, delay: 0.9)
        }
    }

    func dismissCompleted() {
        completed = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            isPresented = false
        }
    }

    func dismissWithoutCompleting() {
        completed = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            isPresented = false
        }
        AnalyticsService.shared.trackEvent("Love Prompt Dismissed", properties: [
            "trigger": lastTrigger?.rawValue ?? "unknown"
        ])
    }

    private func schedule(_ trigger: Trigger, delay: TimeInterval) {
        guard !completed, !isPresented, !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            guard !self.completed, !self.isPresented else { return }
            self.lastTrigger = trigger
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                self.isPresented = true
            }
            HapticsManager.shared.impact(.light)
            AnalyticsService.shared.trackEvent("Love Prompt Shown", properties: [
                "trigger": trigger.rawValue
            ])
        }
    }
}
