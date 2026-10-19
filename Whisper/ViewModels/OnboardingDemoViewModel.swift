import Foundation
import SwiftUI

enum OnboardingDemoOutcome: String {
    case success
    case skipped
    case permissionDenied = "permission_denied"
    case failed
}

@MainActor
final class OnboardingDemoViewModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case introduction
        case requestingPermission
        case ready
        case connecting
        case recording
        case finishing
        case success
        case shortTranscript
        case failure
    }

    enum StopReason: String {
        case manual
        case automatic
        case interrupted
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var words: [String] = []
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var isRealtimeConnected = false
    @Published private(set) var failureMessage = "We couldn’t hear enough to create your preview."
    @Published private(set) var failureOutcome: OnboardingDemoOutcome = .failed
    @Published private(set) var isMicrophoneReady = false
    @Published private(set) var summary = ""
    @Published private(set) var summaryTodos: [String] = []
    @Published private(set) var isGeneratingSummary = false

    let maximumDuration: TimeInterval = 15
    let minimumManualStopDuration: TimeInterval = 2

    private let userName: String
    private let languageCode: String
    private let translationLanguageCode: String
    private let audioService: AudioService
    private let transcriptionService: TranscriptionService
    nonisolated(unsafe) private let realtimeService: RealtimeTranscriptionService
    private var realtimeTranscriptAccumulator = RealtimeTranscriptAccumulator()
    private var recordingStartedAt: Date?
    private var connectionStartedAt: Date?
    private var connectedAt: Date?
    private var firstTranscriptAt: Date?
    private var finishStartedAt: Date?
    private var recordedDuration: TimeInterval = 0
    private var onboardingAudioSessionID = UUID().uuidString
    private var timer: Timer?
    private var finishTimeout: DispatchWorkItem?
    private var finishDebounce: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?
    private var finalizationTask: Task<Void, Never>?
    private var temporaryURLs: Set<URL> = []
    private var didTrackFirstTranscript = false
    private var didTrackRealtimeConnected = false
    private var didTrackFailure = false
    private var didFinishAttempt = false
    private var didBeginAudio = false
    private var startTrigger = "mic_tap"
    private var attempt = 0

    init(
        userName: String,
        languageCode: String,
        translationLanguageCode: String,
        audioService: AudioService = AudioService(),
        transcriptionService: TranscriptionService = TranscriptionService(),
        realtimeService: RealtimeTranscriptionService = RealtimeTranscriptionService()
    ) {
        self.userName = userName
        self.languageCode = languageCode
        self.translationLanguageCode = translationLanguageCode
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.realtimeService = realtimeService
        super.init()
        transcriptionService.preferredLanguages = Languages.transcriptionHints(from: languageCode)
        AudioService.removeStaleOnboardingDemoFiles()
        audioService.delegate = self
        realtimeService.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleRealtimeEvent(event)
            }
        }
    }

    var examplePrompt: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "there" : trimmed
        return "“Hi, I’m \(name). Remind me to send the launch notes tomorrow.”"
    }

    var elapsed: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return min(maximumDuration, Date().timeIntervalSince(recordingStartedAt))
    }

    var canStopManually: Bool {
        phase == .recording && elapsed >= minimumManualStopDuration
    }

    var transcript: String {
        realtimeTranscriptAccumulator.transcript
    }

    func tryDemo() {
        guard phase == .ready || phase == .failure else { return }
        track("Onboarding Demo Try Tapped")
        phase = .requestingPermission
        audioService.requestPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.track("Onboarding Demo Permission Result", properties: ["result": granted ? "granted" : "denied"])
                if granted {
                    self.isMicrophoneReady = true
                    self.phase = .ready
                    self.startRecording(trigger: "permission_granted")
                } else {
                    self.failureMessage = "Microphone access is off. You can continue without trying the demo."
                    self.failureOutcome = .permissionDenied
                    self.phase = .failure
                    self.trackFailure(category: "permission_denied")
                }
            }
        }
    }

    func startRecording(trigger: String = "mic_tap") {
        guard phase == .ready, isMicrophoneReady else { return }

        resetAttempt()
        attempt += 1
        guard NetworkMonitor.shared.isOnline else {
            fail(category: "offline", message: "The live demo needs an internet connection. You can retry or continue.")
            return
        }
        guard realtimeService.isConfigured else {
            fail(category: "not_configured", message: "The live demo isn’t available right now. You can continue to Revera.")
            return
        }

        connectionStartedAt = Date()
        startTrigger = trigger
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            phase = .connecting
        }
        realtimeService.connect(
            languages: Languages.transcriptionHints(from: languageCode),
            audioSessionID: onboardingAudioSessionID,
            isOnboardingDemo: true
        )
        scheduleConnectTimeout()
    }

    private func beginAudioRecording() {
        guard phase == .connecting, !didBeginAudio else { return }
        didBeginAudio = true
        connectTimeout?.cancel()
        connectTimeout = nil

        audioService.startRecording(splitIntoSegments: false, storagePolicy: .ephemeral) { [weak self] success, path in
            Task { @MainActor in
                guard let self else { return }
                if let path, !path.isEmpty {
                    self.temporaryURLs.insert(URL(fileURLWithPath: path))
                }
                guard success else {
                    self.fail(category: "audio_start", message: path ?? "The microphone couldn’t start. Please try again.")
                    return
                }

                self.recordingStartedAt = Date()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    self.phase = .recording
                }
                HapticsManager.shared.impact(.medium)
                self.track("Onboarding Demo Recording Started", properties: [
                    "attempt": self.attempt,
                    "start_trigger": self.startTrigger
                ])
                self.startProgressTimer()
            }
        }
    }

    private func scheduleConnectTimeout() {
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .connecting else { return }
                self.fail(
                    category: "connect_timeout",
                    message: "Live transcription took too long to start. Please try again."
                )
            }
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func stopManually() {
        guard canStopManually else { return }
        stopRecording(reason: .manual)
    }

    func retry() {
        track("Onboarding Demo Retried", properties: ["from_stage": phaseName])
        cleanupAttempt()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            phase = .ready
        }
    }

    func trackSkip() {
        track("Onboarding Demo Skipped", properties: [
            "stage": phaseName,
            "reason": "user_selected_skip"
        ])
        cleanupAttempt()
    }

    func trackContinue(outcome: OnboardingDemoOutcome) {
        track("Onboarding Demo Continue Tapped", properties: [
            "stage": phaseName,
            "demo_outcome": outcome.rawValue
        ])
        cleanupAttempt()
    }

    func abandon() {
        cleanupAttempt()
    }

    func generateSummary() {
        guard phase == .success, !isGeneratingSummary else { return }
        let transcript = words.joined(separator: " ")
        guard !transcript.isEmpty else { return }

        isGeneratingSummary = true
        track("Onboarding Demo Summary Requested", properties: ["word_count": words.count])
        Task {
                    let result = await SummaryService.generateSummary(for: transcript, isOnboardingDemo: true)
            guard phase == .success else { return }
            summary = result.summary
            summaryTodos = result.todos
            isGeneratingSummary = false
            HapticsManager.shared.notification(.success)
            track("Onboarding Demo Summary Completed", properties: [
                "summary_length": result.summary.count,
                "todo_count": result.todos.count
            ])
        }
    }

    private func startProgressTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.progress = min(1, self.elapsed / self.maximumDuration)
                if self.elapsed >= self.maximumDuration {
                    self.stopRecording(reason: .automatic)
                }
            }
        }
    }

    private func stopRecording(reason: StopReason) {
        guard phase == .recording || phase == .connecting else { return }
        timer?.invalidate()
        timer = nil
        phase = .finishing
        finishStartedAt = Date()

        let duration = elapsed
        recordedDuration = duration
        track("Onboarding Demo Recording Stopped", properties: [
            "recording_duration": duration,
            "stop_reason": reason.rawValue,
            "word_count": words.count
        ])

        audioService.stopRecording { [weak self] _, path in
            Task { @MainActor in
                guard let self else { return }
                if let path, !path.isEmpty {
                    self.temporaryURLs.insert(URL(fileURLWithPath: path))
                }
            }
        }
        realtimeService.finish()
        scheduleFinishTimeout()
        if !words.isEmpty {
            scheduleFinishDebounce()
        }
    }

    private func scheduleFinishTimeout() {
        finishTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.evaluateResult() }
        }
        finishTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func scheduleFinishDebounce() {
        finishDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.evaluateResult() }
        }
        finishDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func evaluateResult() {
        guard phase == .finishing, !didFinishAttempt else { return }
        didFinishAttempt = true
        finishTimeout?.cancel()
        finishDebounce?.cancel()
        realtimeService.disconnect()

        if words.count >= 3 {
            finishSuccessfulDemo()
        } else if words.isEmpty {
            deleteTemporaryFiles()
            failureMessage = "We didn’t catch any words. Try one more time, a little closer to your microphone."
            phase = .failure
            trackFailure(category: "no_speech")
        } else {
            deleteTemporaryFiles()
            failureMessage = "We caught your voice. Try one full sentence for the best preview."
            phase = .shortTranscript
            trackFailure(category: "insufficient_speech")
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeTranscriptionEvent) {
        switch event {
        case .connected:
            isRealtimeConnected = true
            connectedAt = Date()
            if !didTrackRealtimeConnected {
                didTrackRealtimeConnected = true
                track("Onboarding Demo Realtime Connected", properties: [
                    "connection_latency_ms": milliseconds(from: connectionStartedAt, to: connectedAt),
                    "attempt": attempt
                ])
            }
            if phase == .connecting {
                beginAudioRecording()
            }
        case .reconnecting:
            isRealtimeConnected = false
        case .delta(let itemID, let text):
            realtimeTranscriptAccumulator.mergeDelta(itemID: itemID, text: text)
            publishTranscript()
        case .completed(let itemID, let transcript):
            realtimeTranscriptAccumulator.finalize(itemID: itemID, transcript: transcript)
            publishTranscript()
            if phase == .finishing {
                scheduleFinishDebounce()
            }
        case .failed(let message):
            isRealtimeConnected = false
            if phase == .connecting {
                fail(category: "realtime_failed", message: "Live transcription didn’t start. Please try again or continue.")
                return
            }
            if phase == .recording {
                stopRecording(reason: .interrupted)
                failureMessage = "Live transcription paused. Please try again or continue."
                trackFailure(category: "realtime_failed", extra: ["error": message])
            }
        case .disconnected:
            isRealtimeConnected = false
        case .usageExhausted:
            isRealtimeConnected = false
            if phase == .recording || phase == .connecting {
                stopRecording(reason: .automatic)
            }
        }
    }

    private func publishTranscript() {
        words = realtimeTranscriptAccumulator.words
        guard !didTrackFirstTranscript, !words.isEmpty else { return }
        didTrackFirstTranscript = true
        firstTranscriptAt = Date()
        HapticsManager.shared.impact(.light)
        track("Onboarding Demo First Transcript Received", properties: [
            "first_word_latency_ms": milliseconds(from: recordingStartedAt, to: firstTranscriptAt),
            "attempt": attempt
        ])
    }

    private func finishSuccessfulDemo() {
        let liveTranscript = realtimeTranscriptAccumulator.transcript
        let originalWordCount = words.count
        let target = Languages.translationTarget(from: translationLanguageCode)
        let audioURL = temporaryURLs.first(where: { AudioService.isUsableAudioFile(at: $0.path) })

        finalizationTask?.cancel()
        finalizationTask = Task {
            var refinedTranscript = liveTranscript
            var refinementSucceeded = false
            if let audioURL {
                do {
                    let rawResult = try await transcriptionService.transcribe(
                        audioURL: audioURL,
                        segmentStart: 0,
                        duration: recordedDuration,
                        audioSessionID: onboardingAudioSessionID,
                        isOnboardingDemo: true
                    )
                    try Task.checkCancellation()
                    let result = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !result.isEmpty {
                        refinedTranscript = result
                        refinementSucceeded = true
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    track("Onboarding Demo Final Transcript Refinement Failed", properties: [
                        "failure_category": "file_transcription",
                        "kept_live_transcript": true,
                        "attempt": attempt
                    ])
                }
            }

            let processedTranscript = await TranscriptLanguageProcessor.translate(refinedTranscript, to: target, isOnboardingDemo: true)
            guard !Task.isCancelled, phase == .finishing else { return }

            realtimeTranscriptAccumulator.replace(with: processedTranscript)
            words = realtimeTranscriptAccumulator.words
            deleteTemporaryFiles()
            let translated = target != nil && processedTranscript != refinedTranscript
            let properties: [String: Any] = [
                "word_count": words.count,
                "original_word_count": originalWordCount,
                "recording_duration": recordedDuration,
                "connection_latency_ms": milliseconds(from: connectionStartedAt, to: connectedAt),
                "completion_latency_ms": milliseconds(from: finishStartedAt, to: Date()),
                "attempt": attempt,
                "translation_language": target ?? "none",
                "translated": translated,
                "final_transcript_refined": refinementSucceeded
            ]

            track("Onboarding Demo Completed", properties: properties)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                phase = .success
            }
            HapticsManager.shared.notification(.success)
            track("Onboarding Demo Success Shown", properties: properties)
            finalizationTask = nil
        }
    }

    private func fail(category: String, message: String) {
        failureMessage = message
        failureOutcome = .failed
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            phase = .failure
        }
        trackFailure(category: category)
        cleanupAttempt()
    }

    private func trackFailure(category: String, extra: [String: Any] = [:]) {
        guard !didTrackFailure else { return }
        didTrackFailure = true
        var properties = extra
        properties["failure_category"] = category
        properties["stage"] = phaseName
        properties["is_online"] = NetworkMonitor.shared.isOnline
        properties["has_partial_text"] = !words.isEmpty
        properties["attempt"] = attempt
        track("Onboarding Demo Failed", properties: properties)
    }

    private func resetAttempt() {
        cleanupAttempt()
        onboardingAudioSessionID = UUID().uuidString
        words = []
        realtimeTranscriptAccumulator.reset()
        progress = 0
        audioLevel = 0
        isRealtimeConnected = false
        recordingStartedAt = nil
        connectionStartedAt = nil
        connectedAt = nil
        firstTranscriptAt = nil
        finishStartedAt = nil
        recordedDuration = 0
        didTrackFirstTranscript = false
        didTrackRealtimeConnected = false
        didTrackFailure = false
        didFinishAttempt = false
        didBeginAudio = false
        startTrigger = "mic_tap"
        failureOutcome = .failed
    }

    private func cleanupAttempt() {
        timer?.invalidate()
        timer = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        finishDebounce?.cancel()
        finishDebounce = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        realtimeService.disconnect()
        audioService.stopRecording { [weak self] _, path in
            Task { @MainActor in
                if let path, !path.isEmpty {
                    self?.temporaryURLs.insert(URL(fileURLWithPath: path))
                }
                self?.deleteTemporaryFiles()
            }
        }
        deleteTemporaryFiles()
    }

    private func deleteTemporaryFiles() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
    }

    private var phaseName: String {
        switch phase {
        case .introduction: "introduction"
        case .requestingPermission: "requesting_permission"
        case .ready: "ready"
        case .connecting: "connecting"
        case .recording: "recording"
        case .finishing: "finishing"
        case .success: "success"
        case .shortTranscript: "short_transcript"
        case .failure: "failure"
        }
    }

    private func milliseconds(from start: Date?, to end: Date?) -> Int {
        guard let start, let end else { return 0 }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    private func track(_ event: String, properties: [String: Any] = [:]) {
        AnalyticsService.shared.trackEvent(event, properties: properties)
    }
}

extension OnboardingDemoViewModel: AudioServiceDelegate {
    nonisolated func audioService(_ service: AudioService, didFinishSegment url: URL, duration: TimeInterval, startTime: TimeInterval) {
        Task { @MainActor in temporaryURLs.insert(url) }
    }

    nonisolated func audioService(_ service: AudioService, didUpdateAudioLevel level: Float) {
        Task { @MainActor in audioLevel = level }
    }

    nonisolated func audioService(_ service: AudioService, didReceiveRealtimeAudio data: Data) {
        realtimeService.sendAudio(data)
    }

    nonisolated func audioService(_ service: AudioService, didInterruptRecording reason: String) {
        Task { @MainActor in
            failureMessage = "Your recording was interrupted. You can retry when you’re ready."
            stopRecording(reason: .interrupted)
            trackFailure(category: "audio_interrupted", extra: ["reason": reason])
        }
    }

    nonisolated func audioService(_ service: AudioService, didResumeRecording: Bool) {}
}
