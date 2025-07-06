import Foundation
import AVFoundation
import SwiftData
import Combine

// Direct imports (all files must be in the same target)

class RecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordings: [Recording] = []
    @Published var permissionDenied = false
    @Published var showPermissionAlert = false
    @Published var errorMessage: String? = nil
    
    private var audioService: AudioService
    private var modelContext: ModelContext
    private var transcriptionService: TranscriptionService
    private var cancellables = Set<AnyCancellable>()
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.audioService = AudioService()
        self.transcriptionService = TranscriptionService()
        fetchRecordings()
        audioService.observeInterruptionNotifications(onPause: { [weak self] in
            self?.pauseRecording()
        }, onStop: { [weak self] in
            self?.stopRecording()
        })
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
            guard let duration = duration, let filePath = filePath else {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.isPaused = false
                }
                return
            }
            let recording = Recording(duration: duration, filePath: filePath)
            self.modelContext.insert(recording)
            self.segmentAndTranscribe(recording: recording)
            self.fetchRecordings()
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
            }
        }
    }
    
    private func segmentAndTranscribe(recording: Recording) {
        let segmentLength: TimeInterval = 30.0
        let totalDuration = recording.duration
        let audioURL = URL(fileURLWithPath: recording.filePath)
        let numSegments = Int(ceil(totalDuration / segmentLength))
        for i in 0..<numSegments {
            let start = TimeInterval(i) * segmentLength
            let duration = min(segmentLength, totalDuration - start)
            let segment = TranscriptionSegment(text: "", status: "pending", timestamp: start, recording: recording)
            self.modelContext.insert(segment)
            // Simulate async transcription
            self.transcriptionService.transcribe(audioURL: audioURL, segmentStart: start, duration: duration) { [weak self] text, error in
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
    
    func fetchRecordings() {
        let descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let fetched = try? modelContext.fetch(descriptor) {
            self.recordings = fetched
        }
    }
}

