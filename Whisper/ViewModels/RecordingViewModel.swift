//
//  NetworkMonitor.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import AVFoundation
import SwiftData
import Combine
import SwiftUI
import Network
import UIKit

class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private(set) var isOnline: Bool = true
    var onStatusChange: ((Bool) -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            guard let self = self else { return }
            if self.isOnline != online {
                self.isOnline = online
                DispatchQueue.main.async {
                    self.onStatusChange?(online)
                }
            }
        }
        monitor.start(queue: queue)
    }
}

class RecordingViewModel: ObservableObject, AudioServiceDelegate {
    @Published var isRecording = false
    @Published var isStartingRecording = false
    @Published var isPreparingRealtime = false
    @Published var isFinishingRealtime = false
    @Published var isPaused = false
    @Published var recordings: [Recording] = []
    @Published var permissionDenied = false
    @Published var showPermissionAlert = false
    @Published var errorMessage: String? = nil
    @Published var audioLevel: Float = 0.0
    @Published var isInterrupted = false
    @Published var interruptionMessage: String? = nil
    @Published var isOnline = true
    @Published var isRefreshing = false
    @Published var searchText = ""
    @Published var liveTranscript = ""
    @Published var liveTranscriptWords: [String] = []
    @Published var realtimeStatusText: String? = nil
    @Published var isRealtimeConnected = false
    @Published private(set) var isTrialUsageExhausted = false
    @Published var isRealtimeFallbackActive = false
    @Published var hidesSegmentRowsDuringRealtime = false
    @Published private(set) var preRecordingTranscriptionModeOverride: TranscriptionMode? = nil
    // Track which recordings are currently generating summaries
    @Published private var summaryLoadingRecordingIds: Set<UUID> = []
    @Published var selectedLanguage: String = "auto" {
        didSet {
            transcriptionService.preferredLanguages = Languages.transcriptionHints(from: selectedLanguage)
        }
    }
    // Session-scoped translation language shared across tabs (resets on app relaunch)
    @Published var sessionTranslationLanguage: String = Languages.autoCode
    
    var audioService: AudioService
    private var modelContext: ModelContext
    private var transcriptionService: TranscriptionService
    private var realtimeTranscriptionService: RealtimeTranscriptionService
    private var activeAudioSessionID = UUID().uuidString
    private let settingsStore = SettingsStore()
    private var activeTranscriptionMode: TranscriptionMode = .segments20s
    private var realtimeTranscriptAccumulator = RealtimeTranscriptAccumulator()
    private var realtimeDisconnectWorkItem: DispatchWorkItem?
    private var realtimeFlushTimeoutWorkItem: DispatchWorkItem?
    private var realtimeFlushDebounceWorkItem: DispatchWorkItem?
    private var realtimePrepareTimeoutWorkItem: DispatchWorkItem?
    private var isWaitingForRealtimeFlush = false
    /// Resumed once with the first answer to a realtime connect made while starting a recording.
    private var realtimeConnectContinuation: CheckedContinuation<RealtimeConnectResult, Never>?
    /// Changes when a start is cancelled, so a start still waiting on access, permission or connect stops there.
    private var startAttemptID = UUID()
    /// The trial ran out while this realtime session was streaming; the rest of the audio waits for an upgrade.
    private var realtimeUsageExhaustedDuringSession = false
    private var inFlightSegmentTranscriptions: Set<UUID> = []
    private var inFlightSpeakerIdentification: Set<UUID> = []
    @Published private(set) var identifyingSpeakerRecordingIds: Set<UUID> = []
    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NetworkMonitor.shared
    
    // Track the current active recording during a session
    @Published private(set) var activeRecording: Recording? = nil
    // Effective translation language for this session (captured at start)
    private(set) var activeTargetTranslationLanguage: String? = nil

    var hasUsageLockedTranscriptions: Bool {
        recordings.contains { recording in recording.segments.contains { $0.status == "locked" } }
    }

    /// Transcribes audio that was saved while transcription minutes or the subscription were unavailable.
    @MainActor
    func retryUsageLockedTranscriptionsWhenAccessIsAvailable(refreshFirst: Bool = true) async {
        let usageAccess = UsageAccessManager.shared
        if refreshFirst {
            await usageAccess.refresh(force: true)
        }
        repairStoredAudioPaths()
        guard usageAccess.accessState.canTranscribe else {
            if usageAccess.accessState.isTrialExhausted {
                isTrialUsageExhausted = true
            }
            return
        }
        isTrialUsageExhausted = false
        clearErrorMessage()
        let segments = recordings.flatMap(\.segments).filter {
            $0.status == "locked" && !inFlightSegmentTranscriptions.contains($0.id)
        }
        for segment in segments {
            guard let recording = segment.recording else { continue }
            let url = URL(fileURLWithPath: segment.filePath)
            startFileTranscription(
                url: url,
                duration: max(recording.duration, 0.1),
                startTime: segment.timestamp,
                recording: recording
            )
        }
    }

    /// Points saved paths back at their files after iOS moved the app's data folder, and gives up on audio
    /// that waits for transcription but no longer exists, so it can't hold the "saved audio" banner forever.
    func repairStoredAudioPaths() {
        guard let recordings = try? modelContext.fetch(FetchDescriptor<Recording>()) else { return }
        var changed = false
        for recording in recordings {
            if let url = AudioService.resolvedAudioURL(forStoredPath: recording.filePath), url.path != recording.filePath {
                recording.filePath = url.path
                changed = true
            }
            for segment in recording.segments {
                for keyPath in [\TranscriptionSegment.filePath, \TranscriptionSegment.sessionFilePath] {
                    let stored = segment[keyPath: keyPath]
                    if let url = AudioService.resolvedAudioURL(forStoredPath: stored), url.path != stored {
                        segment[keyPath: keyPath] = url.path
                        changed = true
                    }
                }
                let waiting = segment.status == "locked" || segment.status == "queued"
                if waiting, !inFlightSegmentTranscriptions.contains(segment.id),
                   AudioService.resolvedAudioURL(forStoredPath: segment.filePath) == nil {
                    segment.status = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "failed" : "completed"
                    changed = true
                }
            }
        }
        if changed {
            try? modelContext.save()
            fetchRecordings()
        }
    }

    private func setErrorMessage(_ message: String) {
        errorMessage = message
    }

    private func clearErrorMessage() {
        errorMessage = nil
    }
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.audioService = AudioService()
        self.transcriptionService = TranscriptionService()
        self.realtimeTranscriptionService = RealtimeTranscriptionService()
        repairStoredAudioPaths()
        fetchRecordings()
        audioService.delegate = self
        configureRealtimeCallbacks()
        syncSessionDefaultsFromSettings()
        transcriptionService.preferredLanguages = Languages.transcriptionHints(from: selectedLanguage)
        // Observe network status changes
        networkMonitor.onStatusChange = { [weak self] online in
            guard let self = self else { return }
            self.isOnline = online
            AnalyticsService.shared.trackEvent("Network Status Changed", properties: [
                "is_online": online
            ])
            if online {
                self.processQueuedTranscriptions()
                self.processPendingSpeakerIdentifications()
            }
        }
        self.isOnline = networkMonitor.isOnline
    }
    
    // Public accessor for segments (for UI bindings in Record and Detail screens)
    func segments(for recording: Recording) -> [TranscriptionSegment] {
        let descriptor = FetchDescriptor<TranscriptionSegment>()
        let allSegments = (try? modelContext.fetch(descriptor)) ?? []
        return allSegments.filter { $0.recording?.id == recording.id }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func syncSessionDefaultsFromSettings() {
        sessionTranslationLanguage = settingsStore.defaultTranslationLanguage
    }

    var preRecordingTranscriptionMode: TranscriptionMode {
        preRecordingTranscriptionModeOverride ?? settingsStore.transcriptionMode
    }

    func setPreRecordingTranscriptionMode(_ mode: TranscriptionMode) {
        preRecordingTranscriptionModeOverride = mode
        settingsStore.transcriptionMode = mode
    }

    private func resetPreRecordingTranscriptionMode() {
        preRecordingTranscriptionModeOverride = nil
    }
    
    private func configureRealtimeCallbacks() {
        realtimeTranscriptionService.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleRealtimeEvent(event)
            }
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeTranscriptionEvent) {
        switch event {
        case .connected:
            if realtimeConnectContinuation != nil {
                resolveRealtimeConnect(.connected)
                return
            }
            guard isRecording else { return }
            isRealtimeConnected = true
            realtimeStatusText = "Realtime transcription is live"
            clearErrorMessage()
            AnalyticsService.shared.trackEvent("Realtime Transcription Connected", properties: nil)
        case .reconnecting(let attempt):
            // While starting, the connect timeout decides; reconnects are not shown yet.
            guard isRecording else { return }
            isRealtimeConnected = false
            realtimeStatusText = "Reconnecting live captions…"
            AnalyticsService.shared.trackEvent("Realtime Transcription Reconnecting", properties: [
                "attempt": attempt
            ])
        case .delta(let itemID, let text):
            updateLiveTranscript(itemID: itemID, text: text)
        case .completed(let itemID, let transcript):
            finalizeLiveTranscript(itemID: itemID, transcript: transcript)
            if isWaitingForRealtimeFlush {
                scheduleRealtimeFlushDebounce()
            }
        case .usageExhausted:
            if realtimeConnectContinuation != nil {
                resolveRealtimeConnect(.usageExhausted)
                return
            }
            guard isRecording || isStartingRecording || isWaitingForRealtimeFlush else { return }
            isRealtimeConnected = false
            isTrialUsageExhausted = true
            realtimeUsageExhaustedDuringSession = true
            realtimeStatusText = "Your 30 trial minutes are used. The rest of this recording is saved and transcribes after you upgrade."
            Task { await UsageAccessManager.shared.refresh() }
            AnalyticsService.shared.trackEvent("Trial Transcription Minutes Exhausted", properties: [
                "audio_session_id": activeAudioSessionID
            ])
        case .subscriptionRequired:
            if realtimeConnectContinuation != nil {
                resolveRealtimeConnect(.subscriptionRequired)
                return
            }
            guard isRecording || isStartingRecording else { return }
            pauseLiveCaptions(message: UsageAccessError.noVerifiedSubscription.localizedDescription)
            AnalyticsService.shared.trackEvent("Realtime Transcription Failed", properties: [
                "error": "subscription_required"
            ])
        case .failed(let message):
            if realtimeConnectContinuation != nil {
                resolveRealtimeConnect(.unavailable(message))
                return
            }
            guard isRecording || isStartingRecording else { return }
            pauseLiveCaptions(message: "Live captions paused. Your recording is still being saved.")
            AnalyticsService.shared.trackEvent("Realtime Transcription Failed", properties: [
                "error": message
            ])
        case .disconnected:
            isRealtimeConnected = false
            if !isRecording {
                realtimeStatusText = nil
            }
        }
    }

    /// Live captions stopped mid-recording. The audio file keeps recording and is transcribed after stop.
    private func pauseLiveCaptions(message: String) {
        isRealtimeConnected = false
        isRealtimeFallbackActive = true
        hidesSegmentRowsDuringRealtime = false
        realtimeStatusText = message
    }

    private func resetLiveTranscript() {
        realtimeDisconnectWorkItem?.cancel()
        realtimeDisconnectWorkItem = nil
        realtimeFlushTimeoutWorkItem?.cancel()
        realtimeFlushTimeoutWorkItem = nil
        realtimeFlushDebounceWorkItem?.cancel()
        realtimeFlushDebounceWorkItem = nil
        isWaitingForRealtimeFlush = false
        liveTranscript = ""
        liveTranscriptWords = []
        realtimeTranscriptAccumulator.reset()
        realtimeStatusText = nil
        isRealtimeConnected = false
        isRealtimeFallbackActive = false
        hidesSegmentRowsDuringRealtime = false
    }

    private func updateLiveTranscript(itemID: String, text: String) {
        realtimeTranscriptAccumulator.mergeDelta(itemID: itemID, text: text)
        refreshLiveTranscript()
    }

    private func finalizeLiveTranscript(itemID: String, transcript: String) {
        realtimeTranscriptAccumulator.finalize(itemID: itemID, transcript: transcript)
        refreshLiveTranscript()
    }

    private func refreshLiveTranscript() {
        liveTranscript = realtimeTranscriptAccumulator.transcript
        liveTranscriptWords = realtimeTranscriptAccumulator.words
    }

    func usesFullTranscriptDisplay(for recording: Recording) -> Bool {
        if usesSpeakerTurnDisplay(for: recording) { return false }
        if activeRecording?.id == recording.id {
            return activeTranscriptionMode == .realtimeOpenAI && !isRealtimeFallbackActive
        }

        return recording.transcriptionModeRawValue == TranscriptionMode.realtimeOpenAI.rawValue ||
            hasLegacyRealtimeMicroSegments(for: recording)
    }

    func usesSpeakerTurnDisplay(for recording: Recording) -> Bool {
        if isRecording, activeRecording?.id == recording.id {
            return false
        }
        return recording.hasSpeakerLabels
    }

    func isIdentifyingSpeakers(for recording: Recording) -> Bool {
        identifyingSpeakerRecordingIds.contains(recording.id) || recording.speakerStatus == .processing
    }

    /// After stop, hide unlabeled text and show progress until speaker turns are ready.
    func isBuildingSpeakerTranscript(for recording: Recording) -> Bool {
        if isRecording, activeRecording?.id == recording.id {
            return false
        }
        if isWaitingForRealtimeFlush, activeRecording?.id == recording.id {
            return false
        }
        if recording.hasSpeakerLabels {
            return false
        }
        if identifyingSpeakerRecordingIds.contains(recording.id) {
            return true
        }
        switch recording.speakerStatus {
        case .pending, .processing:
            return true
        default:
            return false
        }
    }

    func canIdentifySpeakers(for recording: Recording) -> Bool {
        switch recording.speakerStatus {
        case .skipped, .failed, .pending:
            return true
        case .processing, .completed:
            return false
        }
    }

    func transcriptWords(for recording: Recording) -> [String] {
        let source: String
        let persistedTranscript = recording.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeRecording?.id == recording.id && isRecording && !liveTranscriptWords.isEmpty {
            source = liveTranscript
        } else if !persistedTranscript.isEmpty {
            source = persistedTranscript
        } else {
            source = liveTranscript
        }

        return source
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    private func hasLegacyRealtimeMicroSegments(for recording: Recording) -> Bool {
        let completedTextSegments = segments(for: recording).filter {
            $0.status == "completed" &&
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard completedTextSegments.count > 1, recording.duration > 1 else { return false }

        let latestTimestamp = completedTextSegments.map(\.timestamp).max() ?? 0
        return latestTimestamp < 1
    }

    private func realtimeTranscriptSegment(for recording: Recording) -> TranscriptionSegment {
        let segments = (fetchSegments(for: recording) ?? []).sorted { $0.timestamp < $1.timestamp }
        if let segment = segments.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return segment
        }

        let segment = TranscriptionSegment(
            text: "",
            status: "processing",
            timestamp: 0,
            filePath: recording.filePath,
            recording: recording
        )
        modelContext.insert(segment)
        return segment
    }

    private func completeEmptyRealtimeSegments() {
        guard activeTranscriptionMode == .realtimeOpenAI,
              let recording = activeRecording,
              let segments = fetchSegments(for: recording) else {
            return
        }

        let emptyProcessing = segments.filter { $0.status == "processing" && $0.text.isEmpty }
        guard !emptyProcessing.isEmpty else { return }

        for segment in emptyProcessing {
            segment.status = "failed"
        }
        try? modelContext.save()
        fetchRecordings()
    }
    
    /// Starts a recording in separate steps, each finishing before the next begins:
    /// 1. access (trial minutes or subscription), 2. microphone permission, 3. live captions (realtime only), 4. audio capture.
    /// Nothing is prompted or connected when access says the user must upgrade first.
    @MainActor
    func startRecording() async -> RecordingStartOutcome {
        guard !isStartingRecording, !isRecording, !isFinishingRealtime else { return .cancelled }
        let attempt = UUID()
        startAttemptID = attempt
        isStartingRecording = true
        prepareForNewSession()

        // Step 1: access.
        let access = await UsageAccessManager.shared.accessForRecording(isOnline: isOnline)
        guard attempt == startAttemptID else { return .cancelled }
        let decision = RecordingStartPolicy.decide(
            access: access,
            requestedMode: preRecordingTranscriptionMode,
            isOnline: isOnline,
            realtimeConfigured: realtimeTranscriptionService.isConfigured
        )
        var mode: TranscriptionMode
        var notice: RecordingStartNotice?
        switch decision {
        case .requireUpgrade:
            isStartingRecording = false
            isTrialUsageExhausted = true
            AnalyticsService.shared.trackEvent("Recording Blocked", properties: ["reason": "trial_exhausted"])
            return .needsUpgrade
        case .requireSubscription:
            isStartingRecording = false
            AnalyticsService.shared.trackEvent("Recording Blocked", properties: ["reason": "no_subscription"])
            return .needsSubscription
        case .start(let decidedMode, let decidedNotice):
            mode = decidedMode
            notice = decidedNotice
        }

        // Step 2: microphone permission.
        AnalyticsService.shared.trackEvent("Recording Permission Requested", properties: nil)
        let granted = await audioService.requestPermission()
        guard attempt == startAttemptID else { return .cancelled }
        permissionDenied = !granted
        guard granted else {
            isStartingRecording = false
            showPermissionAlert = true
            AnalyticsService.shared.trackEvent("Recording Permission Denied", properties: nil)
            return .permissionDenied
        }
        AnalyticsService.shared.trackEvent("Recording Permission Granted", properties: nil)

        // Step 3: live captions.
        if mode == .realtimeOpenAI {
            activeTranscriptionMode = .realtimeOpenAI
            hidesSegmentRowsDuringRealtime = true
            isPreparingRealtime = true
            let result = await connectRealtime()
            guard attempt == startAttemptID else { return .cancelled }
            isPreparingRealtime = false
            switch result {
            case .connected:
                break
            case .usageExhausted:
                realtimeTranscriptionService.disconnect()
                hidesSegmentRowsDuringRealtime = false
                isStartingRecording = false
                isTrialUsageExhausted = true
                await UsageAccessManager.shared.refresh()
                return .needsUpgrade
            case .subscriptionRequired:
                realtimeTranscriptionService.disconnect()
                mode = .segments20s
                setErrorMessage(UsageAccessError.noVerifiedSubscription.localizedDescription)
            case .unavailable(let reason):
                realtimeTranscriptionService.disconnect()
                mode = .segments20s
                notice = .realtimeUnavailable
                AnalyticsService.shared.trackEvent("Realtime Transcription Failed", properties: [
                    "error": reason,
                    "during_prepare": true
                ])
            }
        }
        activeTranscriptionMode = mode
        if mode == .segments20s {
            hidesSegmentRowsDuringRealtime = false
        }
        realtimeStatusText = notice?.message

        // Step 4: audio capture.
        return await beginAudioCapture(attempt: attempt)
    }

    /// Clears everything left over from the previous recording.
    private func prepareForNewSession() {
        realtimeDisconnectWorkItem?.cancel()
        realtimeDisconnectWorkItem = nil
        realtimeFlushTimeoutWorkItem?.cancel()
        realtimeFlushTimeoutWorkItem = nil
        realtimeFlushDebounceWorkItem?.cancel()
        realtimeFlushDebounceWorkItem = nil
        realtimePrepareTimeoutWorkItem?.cancel()
        realtimePrepareTimeoutWorkItem = nil
        isWaitingForRealtimeFlush = false
        isFinishingRealtime = false
        inFlightSegmentTranscriptions.removeAll()
        activeAudioSessionID = UUID().uuidString
        isTrialUsageExhausted = false
        realtimeUsageExhaustedDuringSession = false
        activeTranscriptionMode = .segments20s
        resetLiveTranscript()
        clearErrorMessage()
        transcriptionService.preferredLanguages = transcriptionLanguageHints()
    }

    @MainActor
    private func connectRealtime() async -> RealtimeConnectResult {
        await withCheckedContinuation { continuation in
            realtimeConnectContinuation = continuation
            realtimeTranscriptionService.connect(
                languages: Languages.realtimeHints(selected: selectedLanguage, stored: settingsStore.transcriptionLanguage),
                audioSessionID: activeAudioSessionID
            )
            let timeout = DispatchWorkItem { [weak self] in
                self?.resolveRealtimeConnect(.unavailable("connect_timeout"))
            }
            realtimePrepareTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)
        }
    }

    private func resolveRealtimeConnect(_ result: RealtimeConnectResult) {
        realtimePrepareTimeoutWorkItem?.cancel()
        realtimePrepareTimeoutWorkItem = nil
        guard let continuation = realtimeConnectContinuation else { return }
        realtimeConnectContinuation = nil
        continuation.resume(returning: result)
    }

    @MainActor
    private func beginAudioCapture(attempt: UUID) async -> RecordingStartOutcome {
        let splitIntoSegments = activeTranscriptionMode == .segments20s
        let (success, filePath) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            audioService.startRecording(splitIntoSegments: splitIntoSegments) { success, filePath in
                continuation.resume(returning: (success, filePath))
            }
        }
        guard attempt == startAttemptID else {
            if success {
                // Cancelled while the microphone started: discard this audio without filing it under another recording.
                audioService.delegate = nil
                audioService.stopRecording { _, _ in }
                audioService.delegate = self
            }
            return .cancelled
        }
        guard success else {
            isStartingRecording = false
            hidesSegmentRowsDuringRealtime = false
            realtimeStatusText = nil
            if activeTranscriptionMode == .realtimeOpenAI {
                realtimeTranscriptionService.disconnect()
            }
            setErrorMessage(filePath?.isEmpty == false ? filePath! : "The microphone couldn’t start. Please try again.")
            AnalyticsService.shared.trackEvent("Recording Start Failed", properties: nil)
            return .failed
        }

        isStartingRecording = false
        isRecording = true
        isPaused = false
        let effective = sessionTranslationLanguage
        activeTargetTranslationLanguage = Languages.translationTarget(from: effective)
        let rec = Recording(
            id: UUID(uuidString: activeAudioSessionID) ?? UUID(),
            duration: 0,
            filePath: filePath ?? UUID().uuidString,
            title: nil,
            transcriptionModeRawValue: activeTranscriptionMode.rawValue
        )
        rec.speakerStatus = settingsStore.identifySpeakers ? .pending : .skipped
        modelContext.insert(rec)
        activeRecording = rec
        recordings.insert(rec, at: 0)

        if activeTranscriptionMode == .realtimeOpenAI, !isRealtimeFallbackActive, !realtimeUsageExhaustedDuringSession {
            isRealtimeConnected = true
            realtimeStatusText = nil
            HapticsManager.shared.impact(.medium)
            AnalyticsService.shared.trackEvent("Realtime Transcription Connected", properties: nil)
        }

        AnalyticsService.shared.trackEvent("Recording Started", properties: [
            "translation_language": effective,
            "is_online": isOnline,
            "transcription_mode": activeTranscriptionMode.rawValue
        ])
        return .started
    }

    /// Stops a start that is still waiting on access, permission or the realtime connection.
    private func cancelPendingStart() {
        startAttemptID = UUID()
        resolveRealtimeConnect(.unavailable("cancelled"))
        realtimeTranscriptionService.disconnect()
        isStartingRecording = false
        isPreparingRealtime = false
        hidesSegmentRowsDuringRealtime = false
        realtimeStatusText = nil
        resetLiveTranscript()
    }
    
    func pauseRecording() {
        audioService.pauseRecording()
        isPaused = true
        if let rec = activeRecording {
            AnalyticsService.shared.trackEvent("Recording Paused", properties: [
                "recording_duration": rec.duration,
                "segment_count": segments(for: rec).count
            ])
        }
    }
    
    func stopRecording() {
        if isStartingRecording && !isRecording {
            cancelPendingStart()
            return
        }

        isStartingRecording = false
        isPreparingRealtime = false
        audioService.stopRecording { duration, filePath in
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                self.resetPreRecordingTranscriptionMode()
                self.hidesSegmentRowsDuringRealtime = false
                if self.activeTranscriptionMode == .realtimeOpenAI {
                    self.beginRealtimeStopFlush()
                } else if let rec = self.activeRecording {
                    self.ensurePendingSegmentsAreQueuedAfterStop(for: rec)
                    self.maybeIdentifySpeakersAfterTranscription(for: rec)
                }
                
                if let rec = self.activeRecording {
                    if let filePath, AudioService.isUsableAudioFile(at: filePath) || FileManager.default.fileExists(atPath: filePath) {
                        rec.filePath = filePath
                    }
                    if let duration, duration > rec.duration {
                        rec.duration = duration
                    }
                    let segmentCount = self.segments(for: rec).count
                    AnalyticsService.shared.trackEvent("Recording Stopped", properties: [
                        "recording_duration": rec.duration,
                        "segment_count": segmentCount,
                        "is_online": self.isOnline,
                        "transcription_mode": self.activeTranscriptionMode.rawValue
                    ])
                    LovePromptManager.shared.noteRecordingFinished(duration: rec.duration)
                }
            }
            // The last segment will be handled by the delegate callback
        }
    }

    private func beginRealtimeStopFlush() {
        isWaitingForRealtimeFlush = true
        isFinishingRealtime = true
        realtimeStatusText = nil
        realtimeTranscriptionService.finish()
        scheduleRealtimeFlushTimeout()
        scheduleRealtimeFlushDebounce()
    }

    private func scheduleRealtimeFlushTimeout() {
        realtimeFlushTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.completeRealtimeStopFlush()
        }
        realtimeFlushTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    private func scheduleRealtimeFlushDebounce() {
        realtimeFlushDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.completeRealtimeStopFlush()
        }
        realtimeFlushDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func completeRealtimeStopFlush() {
        guard isWaitingForRealtimeFlush else { return }
        isWaitingForRealtimeFlush = false
        isFinishingRealtime = false
        realtimeFlushTimeoutWorkItem?.cancel()
        realtimeFlushDebounceWorkItem?.cancel()
        realtimeFlushTimeoutWorkItem = nil
        realtimeFlushDebounceWorkItem = nil
        persistLiveTranscriptIfNeeded()
        realtimeTranscriptionService.disconnect()
        if let rec = activeRecording {
            if realtimeUsageExhaustedDuringSession {
                holdRealtimeRecordingForUpgrade(rec)
            } else if settingsStore.identifySpeakers, AudioService.isUsableAudioFile(at: rec.filePath) {
                identifySpeakersIfNeeded(for: rec)
            } else {
                // Captions that dropped mid-recording cover only part of it, so transcribe the whole file.
                transcribeRealtimeRecordingIfNeeded(rec, replacingLiveText: isRealtimeFallbackActive)
            }
        }
    }

    /// The trial ran out mid-stream: keep the live text, and save the whole recording to transcribe after an upgrade.
    /// The Worker charges only audio the live stream did not already cover.
    private func holdRealtimeRecordingForUpgrade(_ recording: Recording) {
        realtimeStatusText = nil
        guard AudioService.isUsableAudioFile(at: recording.filePath) else { return }
        let alreadyHeld = segments(for: recording).contains {
            $0.status == "locked" && $0.filePath == recording.filePath && $0.timestamp == 0
        }
        if !alreadyHeld {
            modelContext.insert(TranscriptionSegment(
                text: "",
                status: "locked",
                timestamp: 0,
                filePath: recording.filePath,
                recording: recording
            ))
        }
        if recording.speakerStatus != .skipped {
            recording.speakerStatus = .pending
        }
        try? modelContext.save()
        fetchRecordings()
    }

    private func transcribeRealtimeRecordingIfNeeded(_ recording: Recording, replacingLiveText: Bool = false) {
        let url = URL(fileURLWithPath: recording.filePath)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.filePath)[.size] as? NSNumber)?.intValue ?? 0
        let hasLiveText = !recording.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasLiveText, !replacingLiveText || fileSize <= 1000 {
            realtimeStatusText = nil
            attemptAutoSummarizeIfComplete(for: recording)
            return
        }
        
        guard FileManager.default.fileExists(atPath: recording.filePath), fileSize > 1000 else {
            realtimeStatusText = nil
            setErrorMessage("Nothing was captured. Please try recording again.")
            completeEmptyRealtimeSegments()
            return
        }

        realtimeStatusText = "Transcribing recording..."
        startFileTranscription(url: url, duration: recording.duration, startTime: 0, recording: recording)
    }

    private func persistLiveTranscriptIfNeeded() {
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let rec = activeRecording else { return }
        let segment = realtimeTranscriptSegment(for: rec)
        if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count < text.count {
            segment.status = "completed"
            segment.text = text
        }
        assignTitleIfNeeded(to: rec, from: text)
        try? modelContext.save()
        fetchRecordings()
    }

    private func assignTitleIfNeeded(to recording: Recording, from text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recording.title == nil || recording.title?.isEmpty == true, !trimmed.isEmpty else { return }

        recording.title = fallbackTitle(from: trimmed)
        try? modelContext.save()
        fetchRecordings()

        let textCopy = trimmed
        Task { @MainActor in
            let (shortTitle, _) = await SummaryService.generateShortSummary(for: textCopy)
            let improved = shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !improved.isEmpty else { return }
            recording.title = improved
            try? self.modelContext.save()
            self.fetchRecordings()
        }
    }

    private func fallbackTitle(from text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return trimmed }
        let prefix = String(trimmed.prefix(40))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

    private func transcriptionLanguageHints() -> [String] {
        if selectedLanguage.lowercased() != Languages.autoCode {
            return Languages.transcriptionHints(from: selectedLanguage)
        }
        return Languages.transcriptionHints(from: settingsStore.transcriptionLanguage)
    }
    
    func resumeRecording() {
        audioService.resumeRecording()
        isPaused = false
        isRecording = true
        if let rec = activeRecording {
            AnalyticsService.shared.trackEvent("Recording Resumed", properties: [
                "recording_duration": rec.duration,
                "segment_count": segments(for: rec).count
            ])
        }
    }
    
    // MARK: - Summary Loading Helpers
    func isSummaryGenerating(for recording: Recording) -> Bool {
        summaryLoadingRecordingIds.contains(recording.id)
    }
    
    @MainActor
    func generateFullSummary(for recording: Recording) async {
        // Avoid duplicate work
        guard !isSummaryGenerating(for: recording) else { return }
        summaryLoadingRecordingIds.insert(recording.id)
        defer { summaryLoadingRecordingIds.remove(recording.id) }
        
        let transcript = recording.fullTranscript
        guard !transcript.isEmpty else { return }
        
        AnalyticsService.shared.trackEvent("Summary Generation Started", properties: [
            "recording_duration": recording.duration,
            "transcript_length": transcript.count,
            "segment_count": segments(for: recording).count,
            "is_auto": recording.summary?.isEmpty ?? true
        ])
        
        let (summary, todos) = await SummaryService.generateSummary(for: transcript)
        recording.summary = summary
        recording.todoList = todos
        try? modelContext.save()
        fetchRecordings()
        
        AnalyticsService.shared.trackEvent("Summary Generation Completed", properties: [
            "summary_length": summary.count,
            "todo_count": todos.count,
            "recording_duration": recording.duration
        ])
    }
    
    // MARK: - AudioServiceDelegate
    func audioService(_ service: AudioService, didUpdateAudioLevel level: Float) {
        DispatchQueue.main.async {
            self.audioLevel = level
        }
    }

    func audioService(_ service: AudioService, didReceiveRealtimeAudio data: Data) {
        guard activeTranscriptionMode == .realtimeOpenAI, !isRealtimeFallbackActive, !isPaused else { return }
        realtimeTranscriptionService.sendAudio(data)
    }
    
    func audioService(_ service: AudioService, didInterruptRecording reason: String) {
        DispatchQueue.main.async {
            self.isInterrupted = true
            self.interruptionMessage = reason
            AnalyticsService.shared.trackEvent("Recording Interrupted", properties: [
                "reason": reason,
                "is_online": self.isOnline
            ])
        }
    }
    
    func audioService(_ service: AudioService, didResumeRecording: Bool) {
        DispatchQueue.main.async {
            self.isInterrupted = false
            self.interruptionMessage = nil
            AnalyticsService.shared.trackEvent("Recording Resumed After Interruption", properties: nil)
        }
    }
    
    func audioService(_ service: AudioService, didFinishSegment url: URL, duration: TimeInterval, startTime: TimeInterval) {
        // Always use the activeRecording for this session
        guard let rec = self.activeRecording else {
            // Fallback: create a new Recording if something went wrong
            let fallback = Recording(duration: 0, filePath: url.path)
            self.modelContext.insert(fallback)
            self.recordings.insert(fallback, at: 0)
            self.activeRecording = fallback
            fallback.duration += duration
            let segment = TranscriptionSegment(text: "", status: "processing", timestamp: startTime, filePath: url.path, recording: fallback)
            self.modelContext.insert(segment)
            try? self.modelContext.save()
            self.fetchRecordings()
            return
        }
        // Update duration
        rec.duration += duration
        
        if activeTranscriptionMode == .realtimeOpenAI && !isRealtimeFallbackActive {
            rec.filePath = url.path
            AnalyticsService.shared.trackEvent("Realtime Audio Segment Saved", properties: [
                "segment_duration": duration,
                "segment_start_time": startTime
            ])
            try? self.modelContext.save()
            self.fetchRecordings()
            return
        }

        startFileTranscription(url: url, duration: duration, startTime: startTime, recording: rec)
    }

    private func startFileTranscription(url: URL, duration: TimeInterval, startTime: TimeInterval, recording rec: Recording) {
        let matchingSegments = segments(for: rec).filter { $0.filePath == url.path }
        let existing = matchingSegments.first { $0.status == "locked" }
            ?? matchingSegments.first { $0.status == "processing" || $0.status == "queued" }
            ?? matchingSegments.first
        let segment: TranscriptionSegment
        if let existing {
            segment = existing
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segment.status = "processing"
            }
        } else {
            segment = TranscriptionSegment(text: "", status: "processing", timestamp: startTime, filePath: url.path, recording: rec)
            modelContext.insert(segment)
        }
        try? modelContext.save()
        fetchRecordings()

        guard isOnline else {
            segment.status = "queued"
            AnalyticsService.shared.trackEvent("Transcription Queued", properties: [
                "reason": "offline",
                "segment_duration": duration
            ])
            try? modelContext.save()
            fetchRecordings()
            return
        }

        inFlightSegmentTranscriptions.insert(segment.id)
        AnalyticsService.shared.trackEvent("Transcription Started", properties: [
            "segment_duration": duration,
            "segment_start_time": startTime,
            "is_online": true
        ])
        transcriptionService.transcribe(
            audioURL: url,
            segmentStart: startTime,
            duration: duration,
            audioSessionID: rec.id.uuidString
        ) { [weak self] text, error in
            DispatchQueue.main.async {
                self?.inFlightSegmentTranscriptions.remove(segment.id)
                self?.applyTranscriptionResult(segment: segment, recording: rec, duration: duration, text: text, error: error)
            }
        }
    }

    private func applyTranscriptionResult(
        segment: TranscriptionSegment,
        recording rec: Recording,
        duration: TimeInterval,
        text: String?,
        error: Error?
    ) {
        if !isRecording {
            realtimeStatusText = nil
        }

        if let error {
            let existingText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let accessError = error as? UsageAccessError {
                if !existingText.isEmpty {
                    segment.status = "completed"
                    if !segments(for: rec).contains(where: { $0.status == "locked" && $0.filePath == segment.filePath }) {
                        let unprocessed = TranscriptionSegment(
                            text: "",
                            status: "locked",
                            timestamp: segment.timestamp,
                            filePath: segment.filePath,
                            recording: rec
                        )
                        modelContext.insert(unprocessed)
                    }
                } else {
                    segment.status = "locked"
                    segment.text = ""
                }
                if case .trialExhausted = accessError {
                    // The usage banner and the upgrade offer explain this; refresh so they appear right away.
                    isTrialUsageExhausted = true
                    Task { await UsageAccessManager.shared.refresh() }
                } else {
                    setErrorMessage(accessError.localizedDescription)
                }
                AnalyticsService.shared.trackEvent("Saved Transcription Held For Subscription", properties: [
                    "segment_duration": duration,
                    "segment_start_time": segment.timestamp
                ])
            } else if let transcriptionError = error as? TranscriptionError, transcriptionError == .alreadyProcessed {
                // Retrying cannot help and this is not a subscription problem, so never lock the segment.
                if existingText.isEmpty {
                    segment.status = "failed"
                    setErrorMessage("Transcription failed: \(error.localizedDescription)")
                } else {
                    segment.status = "completed"
                    assignTitleIfNeeded(to: rec, from: existingText)
                }
            } else if !existingText.isEmpty {
                segment.status = "completed"
                assignTitleIfNeeded(to: rec, from: existingText)
                AnalyticsService.shared.trackEvent("Transcription Failed", properties: [
                    "error": error.localizedDescription,
                    "segment_duration": duration,
                    "kept_live_transcript": true
                ])
            } else if let transcriptionError = error as? TranscriptionError, transcriptionError == .noNetwork {
                segment.status = "queued"
                AnalyticsService.shared.trackEvent("Transcription Queued", properties: [
                    "reason": "no_network",
                    "segment_duration": duration
                ])
                segment.text = ""
            } else {
                segment.status = "failed"
                setErrorMessage("Transcription failed: \(error.localizedDescription)")
                AnalyticsService.shared.trackEvent("Transcription Failed", properties: [
                    "error": error.localizedDescription,
                    "segment_duration": duration
                ])
                segment.text = ""
            }
        } else if let text {
            clearErrorMessage()
            AnalyticsService.shared.trackEvent("Transcription Completed", properties: [
                "segment_duration": duration,
                "text_length": text.count,
                "has_translation": activeTargetTranslationLanguage != nil
            ])
            if let target = activeTargetTranslationLanguage, !target.isEmpty {
                Task { @MainActor in
                    let translated = await TranscriptLanguageProcessor.translate(text, to: target)
                    segment.status = "completed"
                    segment.text = translated
                    self.removeSupersededSegments(by: segment, in: rec)
                    self.assignTitleIfNeeded(to: rec, from: translated)
                    try? self.modelContext.save()
                    self.fetchRecordings()
                    self.attemptAutoSummarizeIfComplete(for: rec)
                    self.maybeIdentifySpeakersAfterTranscription(for: rec)
                }
            } else {
                Task { @MainActor in
                    segment.status = "completed"
                    segment.text = text
                    self.removeSupersededSegments(by: segment, in: rec)
                    self.assignTitleIfNeeded(to: rec, from: text)
                    try? self.modelContext.save()
                    self.fetchRecordings()
                    self.attemptAutoSummarizeIfComplete(for: rec)
                    self.maybeIdentifySpeakersAfterTranscription(for: rec)
                }
            }
        }

        if segment.status != "processing" {
            try? modelContext.save()
            fetchRecordings()
            attemptAutoSummarizeIfComplete(for: rec)
            maybeIdentifySpeakersAfterTranscription(for: rec)
        }
    }
    
    /// A transcript of the whole recording replaces the partial live text saved before the trial ran out.
    private func removeSupersededSegments(by segment: TranscriptionSegment, in recording: Recording) {
        guard segment.timestamp == 0, segment.filePath == recording.filePath else { return }
        let superseded = segments(for: recording).filter {
            $0.id != segment.id && $0.timestamp == 0 && ($0.speakerKey ?? "").isEmpty
        }
        guard !superseded.isEmpty else { return }
        for old in superseded {
            modelContext.delete(old)
        }
        // The summary was written from the partial text.
        recording.summary = nil
        recording.todoList = nil
    }

    func fetchRecordings() {
        let descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let fetched = try? modelContext.fetch(descriptor) {
            self.recordings = fetched
        }
    }
    
    func refreshRecordings() {
        isRefreshing = true
        fetchRecordings()
        processQueuedTranscriptions()
        processPendingSpeakerIdentifications()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isRefreshing = false
        }
    }
    
    func processQueuedTranscriptions() {
        let descriptor = FetchDescriptor<TranscriptionSegment>(
            predicate: #Predicate<TranscriptionSegment> { segment in
                segment.status == "queued"
            }
        )
        guard let queuedSegments = try? modelContext.fetch(descriptor) else { return }
        for segment in queuedSegments where !inFlightSegmentTranscriptions.contains(segment.id) {
            guard let recording = segment.recording,
                  let url = AudioService.resolvedAudioURL(forStoredPath: segment.filePath) else { continue }
            startFileTranscription(url: url, duration: 20, startTime: segment.timestamp, recording: recording)
        }
    }

    private func ensurePendingSegmentsAreQueuedAfterStop(for recording: Recording) {
        let pending = segments(for: recording).filter {
            $0.status == "processing" &&
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !inFlightSegmentTranscriptions.contains($0.id)
        }
        guard !pending.isEmpty else { return }

        for segment in pending {
            segment.status = "queued"
        }

        try? modelContext.save()
        fetchRecordings()
        processQueuedTranscriptions()
        maybeIdentifySpeakersAfterTranscription(for: recording)
    }
    
    func checkNetworkStatus() {
        // Already handled by NetworkMonitor; expose current state
        isOnline = networkMonitor.isOnline
    }
    
    // MARK: - Auto Summary
    private func attemptAutoSummarizeIfComplete(for recording: Recording) {
        // Only summarize after recording session is stopped
        guard !isRecording else { return }
        if recording.speakerStatus == .pending || recording.speakerStatus == .processing {
            return
        }
        if recording.speakerStatus == .pending || recording.speakerStatus == .processing {
            return
        }
        // Avoid re-generating if we already have a non-empty summary
        if let existing = recording.summary, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        guard let segments = fetchSegments(for: recording) else { return }
        let hasPending = segments.contains { $0.status == "processing" || $0.status == "queued" }
        guard !hasPending else { return }
        let transcript = recording.fullTranscript
        guard !transcript.isEmpty else { return }
        Task { @MainActor in
            await self.generateFullSummary(for: recording)
        }
    }
    
    var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return recordings
        } else {
            return recordings.filter { recording in
                let segments = fetchSegments(for: recording) ?? []
                if segments.contains(where: { $0.text.localizedCaseInsensitiveContains(searchText) }) {
                    return true
                }
                let names = recording.speakerKeysInAppearanceOrder().map { recording.displayName(for: $0) }
                if names.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) {
                    return true
                }
                if recording.title?.localizedCaseInsensitiveContains(searchText) == true {
                    return true
                }
                return false
            }
        }
    }
    
    // MARK: - Keywords
    @MainActor
    func extractKeywords(for recording: Recording) async -> [String] {
        let transcript = recording.fullTranscript
        AnalyticsService.shared.trackEvent("Keywords Extraction Started", properties: [
            "recording_duration": recording.duration,
            "transcript_length": transcript.count
        ])
        
        let keywords = await SummaryService.extractKeywords(for: transcript, maxKeywords: 8)
        if !keywords.isEmpty {
            recording.keywords = keywords
            try? modelContext.save()
            fetchRecordings()
            LovePromptManager.shared.noteShareOrExport()
            
            AnalyticsService.shared.trackEvent("Keywords Extraction Completed", properties: [
                "keyword_count": keywords.count,
                "recording_duration": recording.duration
            ])
        }
        return keywords
    }
    
    private func fetchSegments(for recording: Recording) -> [TranscriptionSegment]? {
        guard let allSegments = try? modelContext.fetch(FetchDescriptor<TranscriptionSegment>()) else { return nil }
        return allSegments.filter { $0.recording?.id == recording.id }
    }

    // MARK: - Speaker identification

    func retrySpeakerIdentification(for recording: Recording) {
        identifySpeakersIfNeeded(for: recording, manualRetry: true)
    }

    func resumeInterruptedSpeakerIdentification(for recording: Recording) {
        guard recording.speakerStatus == .processing || recording.speakerStatus == .pending else { return }
        guard !inFlightSpeakerIdentification.contains(recording.id) else { return }
        identifySpeakersIfNeeded(for: recording, manualRetry: true)
    }

    func identifySpeakersIfNeeded(for recording: Recording, manualRetry: Bool = false) {
        if isRecording, activeRecording?.id == recording.id {
            return
        }
        guard !inFlightSpeakerIdentification.contains(recording.id) else { return }

        if !settingsStore.identifySpeakers && !manualRetry {
            skipSpeakerIdentification(for: recording, reason: "off")
            return
        }

        if recording.speakerStatus == .completed, recording.hasSpeakerLabels, !manualRetry {
            return
        }

        if recording.speakerStatus == .skipped, !manualRetry, settingsStore.identifySpeakers {
            return
        }

        guard let sessionURL = ensureSessionWAV(for: recording) else {
            skipSpeakerIdentification(for: recording, reason: "no_audio")
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sessionURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if recording.duration < AudioService.minDiarizationDuration || fileSize < AudioService.minDiarizationFileSize {
            skipSpeakerIdentification(for: recording, reason: "too_short")
            return
        }

        // Uploading the recording would only be refused; it runs once Unlimited is active.
        let trialExhausted = MainActor.assumeIsolated { UsageAccessManager.shared.accessState.isTrialExhausted }
        guard isOnline, !trialExhausted else {
            recording.speakerStatus = .pending
            try? modelContext.save()
            fetchRecordings()
            return
        }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
            self.inFlightSpeakerIdentification.insert(recording.id)
            self.identifyingSpeakerRecordingIds.insert(recording.id)
            recording.speakerStatus = .processing
            if self.activeRecording?.id == recording.id {
                self.realtimeStatusText = nil
            }
            try? self.modelContext.save()
            self.fetchRecordings()
        }

        let duration = recording.duration
        let mode = recording.transcriptionModeRawValue ?? activeTranscriptionMode.rawValue
        AnalyticsService.shared.trackEvent("Speakers Identification Started", properties: [
            "duration": duration,
            "mode": mode,
            "file_size": fileSize
        ])

        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SpeakerIdentification") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }

        transcriptionService.diarize(audioURL: sessionURL, audioSessionID: recording.id.uuidString) { [weak self] result in
            DispatchQueue.main.async {
                self?.applyDiarizationResult(
                    result,
                    recording: recording,
                    sessionPath: sessionURL.path,
                    manualRetry: manualRetry
                )
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
        }
    }

    /// Speaker identification runs only after every segment of a recording has finished transcribing.
    func processPendingSpeakerIdentifications() {
        fetchRecordings()
        for recording in recordings where recording.speakerStatus == .pending {
            maybeIdentifySpeakersAfterTranscription(for: recording)
        }
    }

    private func maybeIdentifySpeakersAfterTranscription(for recording: Recording) {
        guard !isRecording || activeRecording?.id != recording.id else { return }
        let segs = segments(for: recording)
        let hasPending = segs.contains { $0.status == "processing" || $0.status == "queued" }
        guard !hasPending else { return }
        identifySpeakersIfNeeded(for: recording)
    }

    private func skipSpeakerIdentification(for recording: Recording, reason: String) {
        recording.speakerStatus = .skipped
        identifyingSpeakerRecordingIds.remove(recording.id)
        if activeRecording?.id == recording.id, realtimeStatusText == "Identifying speakers…" {
            realtimeStatusText = nil
        }
        try? modelContext.save()
        fetchRecordings()
        AnalyticsService.shared.trackEvent("Speakers Identification Skipped", properties: [
            "reason": reason
        ])
        attemptAutoSummarizeIfComplete(for: recording)
    }

    private func ensureSessionWAV(for recording: Recording) -> URL? {
        if AudioService.isUsableAudioFile(at: recording.filePath) {
            return URL(fileURLWithPath: recording.filePath)
        }

        let chunkURLs = segments(for: recording)
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.filePath)
            .filter { AudioService.isUsableAudioFile(at: $0) }
            .map { URL(fileURLWithPath: $0) }

        if chunkURLs.count == 1 {
            recording.filePath = chunkURLs[0].path
            try? modelContext.save()
            return chunkURLs[0]
        }

        guard chunkURLs.count >= 2,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent("Segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("\(recording.id.uuidString)-session.wav")
        do {
            try AudioService.concatenateWAVFiles(chunkURLs, to: output)
            if AudioService.isUsableAudioFile(at: output.path) {
                recording.filePath = output.path
                try? modelContext.save()
                return output
            }
        } catch {
            print("RecordingViewModel: session concat failed: \(error)")
        }
        return nil
    }

    private func applyDiarizationResult(
        _ result: Result<DiarizationResult, Error>,
        recording: Recording,
        sessionPath: String,
        manualRetry: Bool
    ) {
        inFlightSpeakerIdentification.remove(recording.id)
        identifyingSpeakerRecordingIds.remove(recording.id)
        if activeRecording?.id == recording.id {
            realtimeStatusText = nil
        }

        switch result {
        case .failure(let error as UsageAccessError):
            // Not a speaker problem: try again once transcription access is back.
            recording.speakerStatus = .pending
            if case .trialExhausted = error {
                isTrialUsageExhausted = true
            }
            try? modelContext.save()
            fetchRecordings()
            AnalyticsService.shared.trackEvent("Speakers Identification Held For Subscription", properties: nil)
        case .failure(let error):
            recording.speakerStatus = .failed
            try? modelContext.save()
            fetchRecordings()
            AnalyticsService.shared.trackEvent("Speakers Identification Failed", properties: [
                "error": error.localizedDescription,
                "kept_existing_transcript": true
            ])
            if activeRecording?.id == recording.id {
                setErrorMessage("Couldn’t identify speakers. Your transcript was kept.")
            }
            attemptAutoSummarizeIfComplete(for: recording)

        case .success(let diarization):
            let turns = diarization.turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !turns.isEmpty else {
                recording.speakerStatus = .failed
                try? modelContext.save()
                fetchRecordings()
                AnalyticsService.shared.trackEvent("Speakers Identification Failed", properties: [
                    "error": "empty_turns",
                    "kept_existing_transcript": true
                ])
                attemptAutoSummarizeIfComplete(for: recording)
                return
            }

            let existing = segments(for: recording)
            withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                for segment in existing {
                    modelContext.delete(segment)
                }

                for turn in turns {
                    let segment = TranscriptionSegment(
                        text: turn.text,
                        status: "completed",
                        timestamp: turn.start,
                        filePath: sessionPath,
                        speakerKey: turn.speakerKey,
                        startTime: turn.start,
                        endTime: turn.end,
                        sessionFilePath: sessionPath,
                        recording: recording
                    )
                    modelContext.insert(segment)
                }

                recording.filePath = sessionPath
                recording.speakerCount = Set(turns.map(\.speakerKey)).count
                recording.speakerStatus = .completed
                try? modelContext.save()
                fetchRecordings()
            }

            let target = translationLanguage(for: recording)
            let translated = target != nil
            let duration = recording.duration
            let speakerCount = recording.speakerCount
            let turnCount = turns.count

            Task { @MainActor in
                if let target {
                    let labeled = self.segments(for: recording)
                    for segment in labeled {
                        let translatedText = await TranscriptLanguageProcessor.translate(segment.text, to: target)
                        if !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            segment.text = translatedText
                        }
                    }
                    try? self.modelContext.save()
                    self.fetchRecordings()
                }

                self.assignTitleIfNeeded(to: recording, from: recording.attributedTranscript)
                try? self.modelContext.save()
                self.fetchRecordings()
                AnalyticsService.shared.trackEvent("Speakers Identification Completed", properties: [
                    "duration": duration,
                    "speaker_count": speakerCount,
                    "turn_count": turnCount,
                    "translated": translated
                ])
                self.attemptAutoSummarizeIfComplete(for: recording)
            }
        }
    }

    private func translationLanguage(for recording: Recording) -> String? {
        if activeRecording?.id == recording.id {
            return activeTargetTranslationLanguage
        }
        return Languages.translationTarget(from: sessionTranslationLanguage)
    }

    func playbackURL(for segment: TranscriptionSegment) -> URL? {
        let fm = FileManager.default
        let candidates = [
            segment.sessionFilePath,
            segment.recording?.filePath ?? "",
            segment.filePath
        ]
        for path in candidates where !path.isEmpty && fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let originalName = URL(fileURLWithPath: segment.filePath).lastPathComponent
        if !originalName.isEmpty,
           let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("Segments", isDirectory: true).appendingPathComponent(originalName)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func canPlay(_ segment: TranscriptionSegment) -> Bool {
        playbackURL(for: segment) != nil
    }

    func updateSpeakerName(_ name: String, for speakerKey: String, in recording: Recording) {
        recording.setDisplayName(name, for: speakerKey)
        try? modelContext.save()
    }

    func saveSpeakerNames(for recording: Recording) {
        try? modelContext.save()
        fetchRecordings()
        AnalyticsService.shared.trackEvent("Speaker Renamed", properties: [
            "speaker_count": recording.speakerCount
        ])
    }
    
    // MARK: - Playback
    func play(from timestamp: TimeInterval, in recording: Recording) {
        let segments = fetchSegments(for: recording) ?? []
        let sorted = segments.sorted { $0.timestamp < $1.timestamp }
        // Prefer exact match within 0.5s; otherwise pick the nearest by absolute difference
        if let exact = sorted.first(where: { abs($0.timestamp - timestamp) <= 0.5 }) {
            guard !exact.filePath.isEmpty, FileManager.default.fileExists(atPath: exact.filePath) else {
                DispatchQueue.main.async { self.setErrorMessage("Audio file not found for this segment.") }
                return
            }
            clearErrorMessage()
            let url = URL(fileURLWithPath: exact.filePath)
            playWholeFile(url, recordingId: recording.id)
            return
        }
        guard let nearest = sorted.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }) else {
            return
        }
        guard !nearest.filePath.isEmpty, FileManager.default.fileExists(atPath: nearest.filePath) else {
            DispatchQueue.main.async { self.setErrorMessage("Audio file not found for this segment.") }
            return
        }
        clearErrorMessage()
        playWholeFile(URL(fileURLWithPath: nearest.filePath), recordingId: recording.id)
    }

    private func playWholeFile(_ url: URL, recordingId: UUID) {
        PlaybackService.shared.play(url: url, start: 0, end: .greatestFiniteMagnitude) {
            Task { @MainActor in
                LovePromptManager.shared.notePlaybackFinished(recordingId: recordingId)
            }
        }
    }
    
    func play(segment: TranscriptionSegment, onFinish: (() -> Void)? = nil) {
        guard let url = playbackURL(for: segment) else {
            DispatchQueue.main.async { self.setErrorMessage("Audio file not found for this segment.") }
            return
        }
        AnalyticsService.shared.trackEvent("Segment Playback Started", properties: [
            "segment_timestamp": segment.timestamp,
            "has_text": !segment.text.isEmpty
        ])
        clearErrorMessage()
        let recordingId = segment.recording?.id
        let wrappedFinish: () -> Void = {
            Task { @MainActor in
                if let recordingId {
                    LovePromptManager.shared.notePlaybackFinished(recordingId: recordingId)
                }
                onFinish?()
            }
        }
        if segment.canPlayRangedSession {
            PlaybackService.shared.play(url: url, start: segment.playbackStart, end: segment.playbackEnd, onFinish: wrappedFinish)
        } else {
            PlaybackService.shared.play(url: url, start: 0, end: .greatestFiniteMagnitude, onFinish: wrappedFinish)
        }
    }
    
    func clearAllRecordings() {
        let descriptor = FetchDescriptor<Recording>()
        if let allRecordings = try? modelContext.fetch(descriptor) {
            let count = allRecordings.count
            for rec in allRecordings {
                modelContext.delete(rec)
            }
            try? modelContext.save()
            fetchRecordings()
            
            AnalyticsService.shared.trackEvent("All Recordings Cleared", properties: [
                "recording_count": count
            ])
        }
    }
    
    // MARK: - Storage Cleanup
    func cleanupProcessedAudioFiles() {
        guard let allSegments = try? modelContext.fetch(FetchDescriptor<TranscriptionSegment>()) else { return }
        var protectedPaths = Set<String>()
        if let recordings = try? modelContext.fetch(FetchDescriptor<Recording>()) {
            for rec in recordings {
                if !rec.filePath.isEmpty { protectedPaths.insert(rec.filePath) }
            }
        }
        for seg in allSegments {
            if !seg.sessionFilePath.isEmpty { protectedPaths.insert(seg.sessionFilePath) }
        }

        var didDelete = false
        var deletedCount = 0
        for seg in allSegments where seg.status == "completed" && !seg.filePath.isEmpty {
            if protectedPaths.contains(seg.filePath) { continue }
            do {
                try FileManager.default.removeItem(atPath: seg.filePath)
                seg.filePath = ""
                didDelete = true
                deletedCount += 1
            } catch {
                print("Cleanup failed for \(seg.filePath): \(error)")
            }
        }
        if didDelete {
            try? modelContext.save()
            fetchRecordings()
            
            AnalyticsService.shared.trackEvent("Cache Cleaned", properties: [
                "files_deleted": deletedCount
            ])
        }
    }
}











