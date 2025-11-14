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
    @Published var showClearConfirmation = false
    @Published var selectedLanguage: String = "auto" {
        didSet {
            // Update transcription service language preference
            transcriptionService.preferredLanguage = selectedLanguage == "auto" ? nil : selectedLanguage
        }
    }
    
    private var audioService: AudioService
    private var modelContext: ModelContext
    private var transcriptionService: TranscriptionService
    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NetworkMonitor.shared
    
    // Track the current active recording during a session
    private var activeRecording: Recording? = nil
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.audioService = AudioService()
        self.transcriptionService = TranscriptionService()
        fetchRecordings()
        audioService.delegate = self
        // Observe network status changes
        networkMonitor.onStatusChange = { [weak self] online in
            guard let self = self else { return }
            self.isOnline = online
            if online {
                self.processQueuedTranscriptions()
            }
        }
        self.isOnline = networkMonitor.isOnline
    }
    
    func requestPermission() {
        audioService.requestPermission { granted in
            DispatchQueue.main.async {
                self.permissionDenied = !granted
                self.showPermissionAlert = !granted
            }
        }
    }
    
    func startRecording() {
        audioService.startRecording { success, filePath in
            if success {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.isPaused = false
                    // Create a new Recording for this session
                    let rec = Recording(duration: 0, filePath: filePath ?? UUID().uuidString, title: nil)
                    self.modelContext.insert(rec)
                    self.activeRecording = rec
                    self.recordings.insert(rec, at: 0)
                }
            }
        }
    }
    
    func pauseRecording() {
        audioService.pauseRecording()
        isPaused = true
    }
    
    func stopRecording() {
        audioService.stopRecording { duration, filePath in
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                // Clear the active recording when session ends
                if let rec = self.activeRecording {
                    Task {
                        let transcript = rec.fullTranscript
                        if !transcript.isEmpty {
                            let (summary, _) = await SummaryService.generateShortSummary(for: transcript)
                            rec.summary = summary
                            try? self.modelContext.save()
                            self.fetchRecordings()
                        }
                    }
                }
                self.activeRecording = nil
            }
            // The last segment will be handled by the delegate callback
        }
    }
    
    // MARK: - AudioServiceDelegate
    func audioService(_ service: AudioService, didUpdateAudioLevel level: Float) {
        DispatchQueue.main.async {
            self.audioLevel = level
        }
    }
    
    func audioService(_ service: AudioService, didInterruptRecording reason: String) {
        DispatchQueue.main.async {
            self.isInterrupted = true
            self.interruptionMessage = reason
        }
    }
    
    func audioService(_ service: AudioService, didResumeRecording: Bool) {
        DispatchQueue.main.async {
            self.isInterrupted = false
            self.interruptionMessage = nil
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
        // Check if we're online before attempting transcription
        if self.isOnline {
            // Start transcription
            self.transcriptionService.transcribe(audioURL: url, segmentStart: startTime, duration: duration) { [weak self] text, error in
                DispatchQueue.main.async {
                    if let error = error {
                        if let transcriptionError = error as? TranscriptionError, transcriptionError == .noNetwork {
                            segment.status = "queued"
                        } else {
                            segment.status = "failed"
                            self?.errorMessage = "Transcription failed: \(error.localizedDescription)"
                        }
                        segment.text = ""
                    } else if let text = text {
                        segment.status = "completed"
                        segment.text = text
                        // Set the title as soon as the first segment is completed and title is not set
                        if rec.title == nil && !text.isEmpty {
                            Task {
                                let (shortTitle, _) = await SummaryService.generateShortSummary(for: text)
                                DispatchQueue.main.async {
                                    rec.title = shortTitle
                                    try? self?.modelContext.save()
                                    self?.fetchRecordings()
                                }
                            }
                        }
                    }
                    try? self?.modelContext.save()
                    self?.fetchRecordings()
                }
            }
        } else {
            // Queue for later processing
            segment.status = "queued"
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
                                segment.status = "completed"
                                segment.text = text
                            }
                            try? self?.modelContext.save()
                            self?.fetchRecordings()
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
        let keywords = await SummaryService.extractKeywords(for: transcript, maxKeywords: 8)
        if !keywords.isEmpty {
            recording.keywords = keywords
            try? modelContext.save()
            fetchRecordings()
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
            for rec in allRecordings {
                modelContext.delete(rec)
            }
            try? modelContext.save()
            fetchRecordings()
        }
    }
    
    // MARK: - Storage Cleanup
    func cleanupProcessedAudioFiles() {
        guard let allSegments = try? modelContext.fetch(FetchDescriptor<TranscriptionSegment>()) else { return }
        var didDelete = false
        for seg in allSegments where seg.status == "completed" && !seg.filePath.isEmpty {
            do {
                try FileManager.default.removeItem(atPath: seg.filePath)
                seg.filePath = ""
                didDelete = true
            } catch {
                print("Cleanup failed for \(seg.filePath): \(error)")
            }
        }
        if didDelete {
            try? modelContext.save()
            fetchRecordings()
        }
    }
}


