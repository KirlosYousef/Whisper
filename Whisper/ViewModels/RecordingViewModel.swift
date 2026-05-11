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
    @Published var isRealtimeFallbackActive = false
    @Published var hidesSegmentRowsDuringRealtime = false
    // Track which recordings are currently generating summaries
    @Published private var summaryLoadingRecordingIds: Set<UUID> = []
    @Published var selectedLanguage: String = "auto" {
        didSet {
            // Update transcription service language preference
            transcriptionService.preferredLanguage = selectedLanguage == "auto" ? nil : selectedLanguage
        }
    }
    // Session-scoped translation language shared across tabs (resets on app relaunch)
    @Published var sessionTranslationLanguage: String = Languages.autoCode
    
    private var audioService: AudioService
    private var modelContext: ModelContext
    private var transcriptionService: TranscriptionService
    private var realtimeTranscriptionService: RealtimeTranscriptionService
    private let settingsStore = SettingsStore()
    private var activeTranscriptionMode: TranscriptionMode = .segments20s
    private var realtimeItemOrder: [String] = []
    private var realtimeItemTexts: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NetworkMonitor.shared
    
    // Track the current active recording during a session
    @Published private(set) var activeRecording: Recording? = nil
    // Effective translation language for this session (captured at start)
    private(set) var activeTargetTranslationLanguage: String? = nil
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.audioService = AudioService()
        self.transcriptionService = TranscriptionService()
        self.realtimeTranscriptionService = RealtimeTranscriptionService()
        fetchRecordings()
        audioService.delegate = self
        configureRealtimeCallbacks()
        // Initialize session translation language from persisted default
        self.sessionTranslationLanguage = SettingsStore().defaultTranslationLanguage
        // Observe network status changes
        networkMonitor.onStatusChange = { [weak self] online in
            guard let self = self else { return }
            self.isOnline = online
            AnalyticsService.shared.trackEvent("Network Status Changed", properties: [
                "is_online": online
            ])
            if online {
                self.processQueuedTranscriptions()
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
    
    func requestPermission() {
        AnalyticsService.shared.trackEvent("Recording Permission Requested", properties: nil)
        audioService.requestPermission { granted in
            DispatchQueue.main.async {
                self.permissionDenied = !granted
                self.showPermissionAlert = !granted
                if !granted {
                    AnalyticsService.shared.trackEvent("Recording Permission Denied", properties: nil)
                } else {
                    AnalyticsService.shared.trackEvent("Recording Permission Granted", properties: nil)
                }
            }
        }
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
            isRealtimeConnected = true
            isRealtimeFallbackActive = false
            realtimeStatusText = "Realtime transcription is live"
            AnalyticsService.shared.trackEvent("Realtime Transcription Connected", properties: nil)
        case .delta(let itemID, let text):
            updateLiveTranscript(itemID: itemID, text: text)
        case .completed(let itemID, let transcript):
            finalizeLiveTranscript(itemID: itemID, transcript: transcript)
            persistRealtimeTranscript(transcript)
        case .failed(let message):
            isRealtimeConnected = false
            isRealtimeFallbackActive = true
            hidesSegmentRowsDuringRealtime = false
            realtimeStatusText = "Realtime stopped. Continuing with 20-second segments."
            errorMessage = "Realtime transcription stopped. Falling back to 20-second segments."
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

    private func resetLiveTranscript() {
        liveTranscript = ""
        liveTranscriptWords = []
        realtimeItemOrder = []
        realtimeItemTexts = [:]
        realtimeStatusText = nil
        isRealtimeConnected = false
        isRealtimeFallbackActive = false
        hidesSegmentRowsDuringRealtime = false
    }

    private func updateLiveTranscript(itemID: String, text: String) {
        registerRealtimeItemIfNeeded(itemID)

        let current = realtimeItemTexts[itemID] ?? ""
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIncoming = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedIncoming.hasPrefix(trimmedCurrent), !trimmedCurrent.isEmpty {
            realtimeItemTexts[itemID] = text
        } else {
            realtimeItemTexts[itemID] = current + text
        }

        refreshLiveTranscript()
    }

    private func finalizeLiveTranscript(itemID: String, transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        registerRealtimeItemIfNeeded(itemID)
        realtimeItemTexts[itemID] = trimmed
        refreshLiveTranscript()
    }

    private func registerRealtimeItemIfNeeded(_ itemID: String) {
        if !realtimeItemOrder.contains(itemID) {
            realtimeItemOrder.append(itemID)
        }
    }

    private func refreshLiveTranscript() {
        liveTranscript = realtimeItemOrder
            .compactMap { realtimeItemTexts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        liveTranscriptWords = liveTranscript
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    private func persistRealtimeTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rec = activeRecording else { return }

        let saveCompletedText: (String) -> Void = { [weak self] finalText in
            guard let self else { return }
            let targetSegment = self.nextRealtimeSegment(for: rec)
            targetSegment.status = "completed"
            targetSegment.text = finalText

            if rec.title == nil && !finalText.isEmpty {
                let textCopy = finalText
                Task { @MainActor in
                    let (shortTitle, _) = await SummaryService.generateShortSummary(for: textCopy)
                    rec.title = shortTitle
                    try? self.modelContext.save()
                    self.fetchRecordings()
                }
            }

            try? self.modelContext.save()
            self.fetchRecordings()
            self.attemptAutoSummarizeIfComplete(for: rec)
        }

        AnalyticsService.shared.trackEvent("Realtime Transcription Completed", properties: [
            "text_length": trimmed.count,
            "has_translation": activeTargetTranslationLanguage != nil
        ])

        if let target = activeTargetTranslationLanguage, !target.isEmpty {
            Task { @MainActor in
                let translated = await SummaryService.translate(text: trimmed, to: target)
                saveCompletedText(translated)
            }
        } else {
            saveCompletedText(trimmed)
        }
    }

    private func nextRealtimeSegment(for recording: Recording) -> TranscriptionSegment {
        let segments = (fetchSegments(for: recording) ?? []).sorted { $0.timestamp < $1.timestamp }
        if let segment = segments.first(where: { $0.status == "processing" && $0.text.isEmpty }) {
            return segment
        }

        let timestamp = segments.last.map { $0.timestamp + 0.01 } ?? recording.duration
        let segment = TranscriptionSegment(
            text: "",
            status: "processing",
            timestamp: timestamp,
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

        var changed = false
        for segment in segments where segment.status == "processing" && segment.text.isEmpty {
            segment.status = "completed"
            changed = true
        }

        if changed {
            try? modelContext.save()
            fetchRecordings()
        }
    }
    
    func startRecording() {
        let requestedMode = settingsStore.transcriptionMode
        let canUseRealtime = requestedMode == .realtimeOpenAI && isOnline && realtimeTranscriptionService.isConfigured
        activeTranscriptionMode = canUseRealtime ? .realtimeOpenAI : .segments20s
        resetLiveTranscript()

        if requestedMode == .realtimeOpenAI && !canUseRealtime {
            isRealtimeFallbackActive = true
            realtimeStatusText = isOnline ? "Realtime unavailable. Recording with 20-second segments." : "Offline. Recording with 20-second segments."
            errorMessage = realtimeStatusText
        }

        if activeTranscriptionMode == .segments20s {
            transcriptionService.requestSpeechRecognitionPermission()
        } else {
            hidesSegmentRowsDuringRealtime = true
            realtimeStatusText = "Connecting to realtime transcription..."
            realtimeTranscriptionService.connect(language: selectedLanguage == "auto" ? nil : selectedLanguage)
        }
        
        audioService.startRecording { success, filePath in
            if success {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.isPaused = false
                    // Capture the effective target translation language for this session
                    let effective = self.sessionTranslationLanguage
                    self.activeTargetTranslationLanguage = (effective.lowercased() == "auto") ? nil : effective
                    // Create a new Recording for this session
                    let rec = Recording(duration: 0, filePath: filePath ?? UUID().uuidString, title: nil)
                    self.modelContext.insert(rec)
                    self.activeRecording = rec
                    self.recordings.insert(rec, at: 0)
                    
                    AnalyticsService.shared.trackEvent("Recording Started", properties: [
                        "translation_language": effective,
                        "is_online": self.isOnline,
                        "transcription_mode": self.activeTranscriptionMode.rawValue
                    ])
                }
            } else {
                AnalyticsService.shared.trackEvent("Recording Start Failed", properties: nil)
            }
        }
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
        audioService.stopRecording { duration, filePath in
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                self.hidesSegmentRowsDuringRealtime = false
                if self.activeTranscriptionMode == .realtimeOpenAI {
                    self.realtimeStatusText = "Finishing realtime transcript..."
                    self.realtimeTranscriptionService.finish()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.realtimeTranscriptionService.disconnect()
                        self.completeEmptyRealtimeSegments()
                        if let rec = self.activeRecording {
                            self.attemptAutoSummarizeIfComplete(for: rec)
                        }
                    }
                }
                
                if let rec = self.activeRecording {
                    let segmentCount = self.segments(for: rec).count
                    AnalyticsService.shared.trackEvent("Recording Stopped", properties: [
                        "recording_duration": rec.duration,
                        "segment_count": segmentCount,
                        "is_online": self.isOnline,
                        "transcription_mode": self.activeTranscriptionMode.rawValue
                    ])
                }
            }
            // The last segment will be handled by the delegate callback
        }
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
        let segment = TranscriptionSegment(text: "", status: "processing", timestamp: startTime, filePath: url.path, recording: rec)
        self.modelContext.insert(segment)
        try? self.modelContext.save()
        self.fetchRecordings()

        if activeTranscriptionMode == .realtimeOpenAI && !isRealtimeFallbackActive {
            AnalyticsService.shared.trackEvent("Realtime Audio Segment Saved", properties: [
                "segment_duration": duration,
                "segment_start_time": startTime
            ])
            return
        }

        // Check if we're online before attempting transcription
        if self.isOnline {
            AnalyticsService.shared.trackEvent("Transcription Started", properties: [
                "segment_duration": duration,
                "segment_start_time": startTime,
                "is_online": true
            ])
            // Start transcription
            self.transcriptionService.transcribe(audioURL: url, segmentStart: startTime, duration: duration) { [weak self] text, error in
                DispatchQueue.main.async {
                    if let error = error {
                        if let transcriptionError = error as? TranscriptionError, transcriptionError == .noNetwork {
                            segment.status = "queued"
                            AnalyticsService.shared.trackEvent("Transcription Queued", properties: [
                                "reason": "no_network",
                                "segment_duration": duration
                            ])
                        } else {
                            segment.status = "failed"
                            self?.errorMessage = "Transcription failed: \(error.localizedDescription)"
                            AnalyticsService.shared.trackEvent("Transcription Failed", properties: [
                                "error": error.localizedDescription,
                                "segment_duration": duration
                            ])
                        }
                        segment.text = ""
                    } else if let text = text {
                        AnalyticsService.shared.trackEvent("Transcription Completed", properties: [
                            "segment_duration": duration,
                            "text_length": text.count,
                            "has_translation": self?.activeTargetTranslationLanguage != nil
                        ])
                        // Translate to the session's target language if specified
                        if let target = self?.activeTargetTranslationLanguage, !target.isEmpty {
                            Task { @MainActor in
                                let translated = await SummaryService.translate(text: text, to: target)
                                segment.status = "completed"
                                segment.text = translated
                                // Set the title as soon as first segment is ready
                                if rec.title == nil && !translated.isEmpty {
                                    let translatedCopy = translated
                                    Task { @MainActor in
                                        let (shortTitle, _) = await SummaryService.generateShortSummary(for: translatedCopy)
                                        rec.title = shortTitle
                                        try? self?.modelContext.save()
                                        self?.fetchRecordings()
                                    }
                                }
                                try? self?.modelContext.save()
                                self?.fetchRecordings()
                                // Attempt auto-summary now that this segment is completed
                                self?.attemptAutoSummarizeIfComplete(for: rec)
                            }
                        } else {
                            Task { @MainActor in
                                segment.status = "completed"
                                segment.text = text
                                // Set the title as soon as the first segment is completed and title is not set
                                if rec.title == nil && !text.isEmpty {
                                    let textCopy = text
                                    Task { @MainActor in
                                        let (shortTitle, _) = await SummaryService.generateShortSummary(for: textCopy)
                                        rec.title = shortTitle
                                        try? self?.modelContext.save()
                                        self?.fetchRecordings()
                                    }
                                }
                                // Persist and attempt auto-summary
                                try? self?.modelContext.save()
                                self?.fetchRecordings()
                                self?.attemptAutoSummarizeIfComplete(for: rec)
                            }
                        }
                    }
                    if segment.status != "processing" {
                        try? self?.modelContext.save()
                        self?.fetchRecordings()
                    // Attempt auto-summary if recording is finished and no pending segments
                    if let rec = self?.activeRecording {
                        self?.attemptAutoSummarizeIfComplete(for: rec)
                    }
                    }
                }
            }
        } else {
            // Queue for later processing
            segment.status = "queued"
            AnalyticsService.shared.trackEvent("Transcription Queued", properties: [
                "reason": "offline",
                "segment_duration": duration
            ])
            try? self.modelContext.save()
            self.fetchRecordings()
        }
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
        
        if let queuedSegments = try? modelContext.fetch(descriptor) {
            for segment in queuedSegments {
                if let _ = segment.recording {
                    let audioURL = URL(fileURLWithPath: segment.filePath)
                    transcriptionService.transcribe(
                        audioURL: audioURL,
                        segmentStart: segment.timestamp,
                        duration: 30.0
                    ) { [weak self] text, error in
                        DispatchQueue.main.async {
                            if let error = error {
                                segment.status = "failed"
                                segment.text = ""
                                self?.errorMessage = "Transcription failed: \(error.localizedDescription)"
                            } else if let text = text {
                                // Use default translation language for queued items
                                let defaultLang = SettingsStore().defaultTranslationLanguage
                                if !defaultLang.isEmpty && defaultLang.lowercased() != "auto" {
                                    Task { @MainActor in
                                        let translated = await SummaryService.translate(text: text, to: defaultLang)
                                        segment.status = "completed"
                                        segment.text = translated
                                        try? self?.modelContext.save()
                                        self?.fetchRecordings()
                                        if let rec = segment.recording {
                                            self?.attemptAutoSummarizeIfComplete(for: rec)
                                        }
                                    }
                                } else {
                                    segment.status = "completed"
                                    segment.text = text
                                }
                            }
                            try? self?.modelContext.save()
                            self?.fetchRecordings()
                            if let rec = segment.recording {
                                self?.attemptAutoSummarizeIfComplete(for: rec)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func checkNetworkStatus() {
        // Already handled by NetworkMonitor; expose current state
        isOnline = networkMonitor.isOnline
    }
    
    // MARK: - Auto Summary
    private func attemptAutoSummarizeIfComplete(for recording: Recording) {
        // Only summarize after recording session is stopped
        guard !isRecording else { return }
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
    
    // MARK: - Q&A
    @MainActor
    func answerQuestion(for recording: Recording, question: String) async -> String {
        let transcript = recording.fullTranscript
        do {
            let answer = try await SummaryService.answerQuestion(transcript: transcript, question: question)
            return answer
        } catch {
            return "Failed to answer: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Generic Ask/Act Command
    @MainActor
    func performCommand(for recording: Recording, prompt: String) async -> String {
        let transcript = recording.fullTranscript
        AnalyticsService.shared.trackEvent("Ask/Act Command Executed", properties: [
            "prompt_length": prompt.count,
            "transcript_length": transcript.count,
            "recording_duration": recording.duration
        ])
        
        let result = await SummaryService.performCommand(transcript: transcript, command: prompt)
        
        AnalyticsService.shared.trackEvent("Ask/Act Command Completed", properties: [
            "result_length": result.count,
            "has_result": !result.isEmpty
        ])
        
        return result
    }
    
    var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return recordings
        } else {
            return recordings.filter { recording in
                // Search in transcription segments
                let segments = fetchSegments(for: recording) ?? []
                return segments.contains { segment in
                    segment.text.localizedCaseInsensitiveContains(searchText)
                }
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
    
    // MARK: - Playback
    func play(from timestamp: TimeInterval, in recording: Recording) {
        let segments = fetchSegments(for: recording) ?? []
        let sorted = segments.sorted { $0.timestamp < $1.timestamp }
        // Prefer exact match within 0.5s; otherwise pick the nearest by absolute difference
        if let exact = sorted.first(where: { abs($0.timestamp - timestamp) <= 0.5 }) {
            guard !exact.filePath.isEmpty, FileManager.default.fileExists(atPath: exact.filePath) else {
                DispatchQueue.main.async { self.errorMessage = "Audio file not found for this segment." }
                return
            }
            let url = URL(fileURLWithPath: exact.filePath)
            PlaybackService.shared.playSegment(at: url)
            return
        }
        guard let nearest = sorted.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }) else {
            return
        }
        guard !nearest.filePath.isEmpty, FileManager.default.fileExists(atPath: nearest.filePath) else {
            DispatchQueue.main.async { self.errorMessage = "Audio file not found for this segment." }
            return
        }
        PlaybackService.shared.playSegment(at: URL(fileURLWithPath: nearest.filePath))
    }
    
    func play(segment: TranscriptionSegment) {
        let fm = FileManager.default
        if !segment.filePath.isEmpty, fm.fileExists(atPath: segment.filePath) {
            AnalyticsService.shared.trackEvent("Segment Playback Started", properties: [
                "segment_timestamp": segment.timestamp,
                "has_text": !segment.text.isEmpty
            ])
            PlaybackService.shared.playSegment(at: URL(fileURLWithPath: segment.filePath))
            return
        }
        // Fallback: look for file under Documents/Segments with same filename
        let originalName = URL(fileURLWithPath: segment.filePath).lastPathComponent
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("Segments", isDirectory: true).appendingPathComponent(originalName)
            if fm.fileExists(atPath: candidate.path) {
                segment.filePath = candidate.path
                try? modelContext.save()
                PlaybackService.shared.playSegment(at: candidate)
                return
            }
        }
        DispatchQueue.main.async { self.errorMessage = "Audio file not found for this segment." }
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
        var didDelete = false
        var deletedCount = 0
        for seg in allSegments where seg.status == "completed" && !seg.filePath.isEmpty {
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
