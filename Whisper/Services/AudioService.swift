//
//  AudioService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import AVFoundation

protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didFinishSegment url: URL, duration: TimeInterval, startTime: TimeInterval)
    func audioService(_ service: AudioService, didUpdateAudioLevel level: Float)
    func audioService(_ service: AudioService, didInterruptRecording reason: String)
    func audioService(_ service: AudioService, didResumeRecording: Bool)
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
    private var isPaused = false
    private var wasInterrupted = false
    weak var delegate: AudioServiceDelegate?
    
    override init() {
        super.init()
        recordingSession = AVAudioSession.sharedInstance()
        setupAudioSessionNotifications()
    }
    
    private func setupAudioSessionNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: recordingSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: recordingSession
        )
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            if isRecording && !isPaused {
                pauseRecording()
                wasInterrupted = true
                delegate?.audioService(self, didInterruptRecording: "Audio session interrupted")
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            if options.contains(.shouldResume) && wasInterrupted {
                resumeRecording()
                wasInterrupted = false
                delegate?.audioService(self, didResumeRecording: true)
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            if isRecording && !isPaused {
                pauseRecording()
                wasInterrupted = true
                delegate?.audioService(self, didInterruptRecording: "Audio device disconnected")
            }
        case .newDeviceAvailable:
            if wasInterrupted {
                resumeRecording()
                wasInterrupted = false
                delegate?.audioService(self, didResumeRecording: true)
            }
        default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func hasSufficientDiskSpace() -> Bool {
        let fileManager = FileManager.default
        guard let path = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        
        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: path.path)
            if let freeSpace = attributes[.systemFreeSize] as? NSNumber {
                let freeSpaceInMB = freeSpace.doubleValue / (1024 * 1024)
                // Require at least 100MB free space
                return freeSpaceInMB > 100
            }
        } catch {
            print("Error checking disk space: \(error)")
        }
        
        return false
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        recordingSession.requestRecordPermission { granted in
            completion(granted)
        }
    }
    
    func startRecording(completion: @escaping (Bool, String?) -> Void) {
        // Check available disk space before starting
        if !hasSufficientDiskSpace() {
            completion(false, "Insufficient disk space. Please free up some space and try again.")
            return
        }
        
        segmentIndex = 0
        segmentStartTime = 0
        startNewSegment(completion: completion)
    }

    private func startNewSegment(completion: ((Bool, String?) -> Void)? = nil) {
        // Record to WAV first (required for real-time writing)
        let tempWavFilename = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default)
            try recordingSession.setActive(true)
            
            audioEngine = AVAudioEngine()
            inputNode = audioEngine?.inputNode
            
            guard let audioEngine = audioEngine, let inputNode = inputNode else {
                completion?(false, nil)
                return
            }
            
            // Use the input node's native format for recording
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Use optimized settings for smaller WAV files
            // 16kHz mono is sufficient for speech and reduces file size
            let recordingSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,  // 16kHz instead of 44.1kHz (smaller files)
                AVNumberOfChannelsKey: 1,   // Mono instead of stereo (2x smaller)
                AVLinearPCMBitDepthKey: 16, // 16-bit instead of 32-bit
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            audioFile = try AVAudioFile(forWriting: tempWavFilename, settings: recordingSettings)

            // Install tap using the input node's format
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }
            
            // Start the engine
            try audioEngine.start()
            
            currentFilePath = tempWavFilename.path
            recordingStartTime = Date()
            isRecording = true
            
            // Start or restart timer - reduced to 20s for faster transcription feedback
            // This provides better UX with shorter wait times while maintaining good transcription quality
            segmentTimer?.invalidate()
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
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
        
        // Convert and write to file if format conversion is needed
        guard let audioFile = audioFile else { return }
        
        let inputFormat = buffer.format
        let outputFormat = audioFile.processingFormat
        
        // If formats match, write directly
        if inputFormat == outputFormat {
            try? audioFile.write(from: buffer)
            return
        }
        
        // Otherwise, convert the format (e.g., 48kHz stereo → 16kHz mono)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            // If conversion fails, try writing directly (AVAudioFile may handle it)
            try? audioFile.write(from: buffer)
            return
        }
        
        // Calculate output buffer size
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if error == nil {
            try? audioFile.write(from: convertedBuffer)
        }
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
        isPaused = true
    }
    
    func resumeRecording() {
        guard isPaused else { return }
        
        do {
            try recordingSession.setActive(true)
            audioEngine?.prepare()
            try audioEngine?.start()
            isRecording = true
            isPaused = false
        } catch {
            print("Failed to resume recording: \(error)")
        }
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
    

}
