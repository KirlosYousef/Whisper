import Foundation
import AVFoundation
import SwiftData
import Combine
import SwiftUI

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
    
    private var audioService: AudioService
    private var modelContext: ModelContext
    private var transcriptionService: TranscriptionService
    private var cancellables = Set<AnyCancellable>()
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.audioService = AudioService()
        self.transcriptionService = TranscriptionService()
        fetchRecordings()
        audioService.delegate = self
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
        // Find or create the parent Recording for this session
        let rec: Recording
        if let last = self.recordings.first, last.filePath == url.path {
            rec = last
        } else {
            rec = Recording(duration: 0, filePath: url.path)
            self.modelContext.insert(rec)
            // Insert at front for UI ordering
            self.recordings.insert(rec, at: 0)
        }
        // Update duration
        rec.duration += duration
        let segment = TranscriptionSegment(text: "", status: "processing", timestamp: startTime, recording: rec)
        self.modelContext.insert(segment)
        try? self.modelContext.save()
        self.fetchRecordings()
        // Start transcription
        self.transcriptionService.transcribe(audioURL: url, segmentStart: startTime, duration: duration) { [weak self] text, error in
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
    
    func fetchRecordings() {
        let descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let fetched = try? modelContext.fetch(descriptor) {
            self.recordings = fetched
        }
    }
}

