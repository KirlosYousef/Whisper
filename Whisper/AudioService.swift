import Foundation
#if os(iOS)
import AVFoundation

protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didFinishSegment url: URL, duration: TimeInterval, startTime: TimeInterval)
    func audioService(_ service: AudioService, didUpdateAudioLevel level: Float)
}

class AudioService: NSObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var recordingSession: AVAudioSession!
    private var currentFilePath: String?
    private var recordingStartTime: Date?
    private var segmentTimer: Timer?
    private var segmentIndex: Int = 0
    private var segmentStartTime: TimeInterval = 0
    private var audioFile: AVAudioFile?
    private var isRecording = false
    weak var delegate: AudioServiceDelegate?
    
    override init() {
        super.init()
        recordingSession = AVAudioSession.sharedInstance()
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        recordingSession.requestRecordPermission { granted in
            completion(granted)
        }
    }
    
    func startRecording(completion: @escaping (Bool, String?) -> Void) {
        segmentIndex = 0
        segmentStartTime = 0
        startNewSegment(completion: completion)
    }

    private func startNewSegment(completion: ((Bool, String?) -> Void)? = nil) {
        let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default)
            try recordingSession.setActive(true)
            
            audioEngine = AVAudioEngine()
            inputNode = audioEngine?.inputNode
            
            guard let audioEngine = audioEngine, let inputNode = inputNode else {
                completion?(false, nil)
                return
            }
            
            // Use the input node's native format for the tap
            let inputFormat = inputNode.outputFormat(forBus: 0)
            // Use a compatible PCM format for AVAudioFile
            let wavSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let fileFormat = AVAudioFormat(settings: wavSettings) ?? inputFormat
            audioFile = try AVAudioFile(forWriting: audioFilename, settings: wavSettings)
            
            // Install tap with the input node's format
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }
            
            // Start the engine
            try audioEngine.start()
            
            currentFilePath = audioFilename.path
            recordingStartTime = Date()
            isRecording = true
            
            // Start or restart timer
            segmentTimer?.invalidate()
            // TODO: Change back to 30
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.finishCurrentSegmentAndStartNew()
            }
            
            completion?(true, currentFilePath)
        } catch {
            completion?(false, nil)
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }
        
        // Calculate audio level
        let channelData = buffer.floatChannelData?[0]
        let frameLength = Int(buffer.frameLength)
        
        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelData?[i] ?? 0.0
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(rms)
        
        // Normalize to 0-1 range (typical speech is around -30 to -10 dB)
        let normalizedLevel = max(0.0, min(1.0, (db + 60) / 50))
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioService(self!, didUpdateAudioLevel: normalizedLevel)
        }
        
        // Write to file
        try? audioFile?.write(from: buffer)
    }

    private func finishCurrentSegmentAndStartNew() {
        guard isRecording else { return }
        
        stopCurrentSegment()
        let fileURL = URL(fileURLWithPath: currentFilePath ?? "")
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let startTime = segmentStartTime
        delegate?.audioService(self, didFinishSegment: fileURL, duration: duration, startTime: startTime)
        
        // Prepare for next segment
        segmentIndex += 1
        segmentStartTime += duration
        startNewSegment()
    }
    
    private func stopCurrentSegment() {
        isRecording = false
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioFile = nil
    }
    
    func pauseRecording() {
        isRecording = false
        inputNode?.removeTap(onBus: 0)
        audioEngine?.pause()
    }
    
    func stopRecording(completion: @escaping (TimeInterval?, String?) -> Void) {
        segmentTimer?.invalidate()
        segmentTimer = nil
        
        if isRecording {
            stopCurrentSegment()
            let fileURL = URL(fileURLWithPath: currentFilePath ?? "")
            let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
            let startTime = segmentStartTime
            delegate?.audioService(self, didFinishSegment: fileURL, duration: duration, startTime: startTime)
            completion(duration, fileURL.path)
        } else if let start = recordingStartTime, let filePath = currentFilePath {
            let duration = Date().timeIntervalSince(start)
            completion(duration, filePath)
        } else {
            completion(nil, nil)
        }
        
        audioEngine = nil
        inputNode = nil
        currentFilePath = nil
        recordingStartTime = nil
        isRecording = false
    }
    
    // MARK: - Interruption Handling
    func observeInterruptionNotifications(onPause: @escaping () -> Void, onStop: @escaping () -> Void) {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: recordingSession, queue: .main) { notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .began {
                onPause()
            } else if type == .ended {
                // Optionally resume
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: recordingSession, queue: .main) { notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue:reasonValue) else { return }
            if reason == .oldDeviceUnavailable {
                onStop()
            }
        }
    }
}
#endif


