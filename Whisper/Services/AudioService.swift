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
    func audioService(_ service: AudioService, didReceiveRealtimeAudio data: Data)
    func audioService(_ service: AudioService, didInterruptRecording reason: String)
    func audioService(_ service: AudioService, didResumeRecording: Bool)
}

extension AudioServiceDelegate {
    func audioService(_ service: AudioService, didReceiveRealtimeAudio data: Data) {}
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
    private var sessionAudioFile: AVAudioFile?
    private var sessionFilePath: String?
    private var sessionChunkURLs: [URL] = []
    private let realtimeOutputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)
    private var realtimeConverter: AVAudioConverter?
    private var realtimeInputFormat: AVAudioFormat?
    private var fileConverter: AVAudioConverter?
    private var fileConverterInputFormat: AVAudioFormat?
    private var lastAudioLevelPublishTime: CFAbsoluteTime = 0
    private var isRecording = false
    private var isPaused = false
    private var wasInterrupted = false
    private var isTapInstalled = false
    private var shouldSplitIntoSegments = true
    private var sessionStartTime: Date?
    weak var delegate: AudioServiceDelegate?

    static let minDiarizationDuration: TimeInterval = 1.0
    static let minDiarizationFileSize = 1000
    static let wavRecordingSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    
    override init() {
        super.init()
        recordingSession = AVAudioSession.sharedInstance()
        setupAudioSessionNotifications()
    }
    
    private func segmentsDirectoryURL() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent("Segments", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission() { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            recordingSession.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }
    
    func startRecording(splitIntoSegments: Bool = true, completion: @escaping (Bool, String?) -> Void) {
        // Check available disk space before starting
        if !hasSufficientDiskSpace() {
            completion(false, "Insufficient disk space. Please free up some space and try again.")
            return
        }
        
        shouldSplitIntoSegments = splitIntoSegments
        segmentIndex = 0
        segmentStartTime = 0
        sessionStartTime = nil
        sessionChunkURLs = []
        closeSessionFile()
        if shouldSplitIntoSegments {
            createSessionFile()
        }
        startNewSegment(completion: completion)
    }

    private func startNewSegment(completion: ((Bool, String?) -> Void)? = nil) {
        // Record to persistent WAV file under Documents/Segments so it survives app relaunch
        let wavURL: URL
        if let dir = segmentsDirectoryURL() {
            wavURL = dir.appendingPathComponent(UUID().uuidString + ".wav")
        } else {
            // Fallback to temporary if documents dir is unavailable
            wavURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        }
        
        do {
            teardownEngine()

            try recordingSession.setCategory(.playAndRecord, mode: .measurement, options: [])
            try recordingSession.setActive(true, options: [])

            let engine = AVAudioEngine()
            audioEngine = engine
            let node = engine.inputNode
            inputNode = node

            let inputFormat = node.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                teardownEngine()
                completion?(false, "Microphone is not available.")
                return
            }
            
            audioFile = try AVAudioFile(forWriting: wavURL, settings: Self.wavRecordingSettings)

            node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }
            isTapInstalled = true

            engine.prepare()
            try engine.start()
            
            currentFilePath = wavURL.path
            lastAudioLevelPublishTime = 0
            if sessionStartTime == nil {
                sessionStartTime = Date()
            }
            recordingStartTime = Date()
            isRecording = true
            let pathForCaller = (shouldSplitIntoSegments ? sessionFilePath : nil) ?? currentFilePath
            
            if shouldSplitIntoSegments {
                segmentTimer?.invalidate()
                segmentTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
                    self?.finishCurrentSegmentAndStartNew()
                }
            }
            
            completion?(true, pathForCaller)
        } catch {
            teardownEngine()
            completion?(false, nil)
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioLevelPublishTime >= 0.07 {
            lastAudioLevelPublishTime = now
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0.0
            if let channelData, frameLength > 0 {
                for i in 0..<frameLength {
                    let sample = channelData[i]
                    sum += sample * sample
                }
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let db = 20 * log10(max(rms, 0.000_001))
            let normalizedLevel = max(0.0, min(1.0, (db + 60) / 50))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.audioService(self, didUpdateAudioLevel: normalizedLevel)
            }
        }

        if let realtimeData = convertToRealtimePCM(buffer) {
            delegate?.audioService(self, didReceiveRealtimeAudio: realtimeData)
        }

        guard let audioFile else { return }
        writeToFile(buffer, audioFile: audioFile)
    }

    private func finishCurrentSegmentAndStartNew() {
        guard isRecording else { return }

                
        stopCurrentSegment()
        let fileURL = URL(fileURLWithPath: currentFilePath ?? "")
        if !fileURL.path.isEmpty {
            sessionChunkURLs.append(fileURL)
        }
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
        removeTapIfNeeded()
        audioEngine?.stop()
        audioFile = nil
    }

    private func removeTapIfNeeded() {
        guard isTapInstalled else { return }
        inputNode?.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func teardownEngine() {
        isRecording = false
        removeTapIfNeeded()
        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil
        inputNode = nil
        audioFile = nil
        realtimeConverter = nil
        realtimeInputFormat = nil
        fileConverter = nil
        fileConverterInputFormat = nil
    }

    private func createSessionFile() {
        guard let dir = segmentsDirectoryURL() else { return }
        let wavURL = dir.appendingPathComponent(UUID().uuidString + "-session.wav")
        do {
            sessionAudioFile = try AVAudioFile(forWriting: wavURL, settings: Self.wavRecordingSettings)
            sessionFilePath = wavURL.path
        } catch {
            print("AudioService: failed to create session WAV: \(error)")
            sessionAudioFile = nil
            sessionFilePath = nil
        }
    }

    private func closeSessionFile() {
        sessionAudioFile = nil
    }
    
    func pauseRecording() {
        isRecording = false
        removeTapIfNeeded()
        audioEngine?.pause()
        isPaused = true
    }
    
    func resumeRecording() {
        guard isPaused else { return }
        
        do {
            try recordingSession.setActive(true)
            
            // Ensure audio engine exists
            if audioEngine == nil {
                audioEngine = AVAudioEngine()
            }
            if inputNode == nil {
                inputNode = audioEngine?.inputNode
            }
            guard let audioEngine = audioEngine, let inputNode = inputNode else { return }
            
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
            removeTapIfNeeded()
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }
            isTapInstalled = true
            
            audioEngine.prepare()
            try audioEngine.start()
            
            if shouldSplitIntoSegments {
                segmentTimer?.invalidate()
                segmentTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
                    self?.finishCurrentSegmentAndStartNew()
                }
            }
            
            isRecording = true
            isPaused = false
        } catch {
            print("Failed to resume recording: \(error)")
        }
    }
    
    func stopRecording(completion: @escaping (TimeInterval?, String?) -> Void) {
        segmentTimer?.invalidate()
        segmentTimer = nil
        let sessionDuration = currentSessionDuration()
        
        var finishedChunkURL: URL?
        if isRecording {
            stopCurrentSegment()
            let fileURL = URL(fileURLWithPath: currentFilePath ?? "")
            if !fileURL.path.isEmpty {
                sessionChunkURLs.append(fileURL)
            }
            finishedChunkURL = fileURL
            let chunkDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
            let reportedDuration = shouldSplitIntoSegments ? chunkDuration : sessionDuration
            let startTime = shouldSplitIntoSegments ? segmentStartTime : 0
            delegate?.audioService(self, didFinishSegment: fileURL, duration: reportedDuration, startTime: startTime)
        }

        closeSessionFile()

        let returnedPath: String?
        if shouldSplitIntoSegments {
            returnedPath = resolvedSessionPath() ?? finishedChunkURL?.path ?? currentFilePath
        } else {
            returnedPath = finishedChunkURL?.path ?? currentFilePath
        }

        if isRecording || sessionStartTime != nil || recordingStartTime != nil {
            completion(sessionDuration, returnedPath)
        } else {
            completion(nil, nil)
        }
        
        audioEngine = nil
        inputNode = nil
        realtimeConverter = nil
        realtimeInputFormat = nil
        fileConverter = nil
        fileConverterInputFormat = nil
        currentFilePath = nil
        recordingStartTime = nil
        sessionStartTime = nil
        sessionChunkURLs = []
        sessionFilePath = nil
        isRecording = false
    }

    private func resolvedSessionPath() -> String? {
        if let sessionFilePath, Self.isUsableAudioFile(at: sessionFilePath) {
            return sessionFilePath
        }
        if sessionChunkURLs.count >= 2, let dir = segmentsDirectoryURL() {
            let output = dir.appendingPathComponent(UUID().uuidString + "-session.wav")
            do {
                try Self.concatenateWAVFiles(sessionChunkURLs, to: output)
                if Self.isUsableAudioFile(at: output.path) {
                    return output.path
                }
            } catch {
                print("AudioService: session concat failed: \(error)")
            }
        }
        if let first = sessionChunkURLs.first, Self.isUsableAudioFile(at: first.path) {
            return first.path
        }
        return sessionFilePath
    }

    static func isUsableAudioFile(at path: String) -> Bool {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size >= minDiarizationFileSize
    }

    static func concatenateWAVFiles(_ urls: [URL], to outputURL: URL) throws {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let firstURL = existing.first else {
            throw NSError(domain: "AudioService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio files to concatenate"])
        }

        let firstFile = try AVAudioFile(forReading: firstURL)
        let output = try AVAudioFile(forWriting: outputURL, settings: firstFile.fileFormat.settings)

        for url in existing {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                continue
            }
            try file.read(into: buffer)
            if file.processingFormat == output.processingFormat {
                try output.write(from: buffer)
            } else if let converter = AVAudioConverter(from: file.processingFormat, to: output.processingFormat) {
                let ratio = output.processingFormat.sampleRate / file.processingFormat.sampleRate
                let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: capacity) else { continue }
                var didProvideInput = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if didProvideInput {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    didProvideInput = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                var error: NSError?
                converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
                if error == nil, converted.frameLength > 0 {
                    try output.write(from: converted)
                }
            }
        }
    }

    private func currentSessionDuration() -> TimeInterval {
        Date().timeIntervalSince(sessionStartTime ?? recordingStartTime ?? Date())
    }

    private func writeToFile(_ buffer: AVAudioPCMBuffer, audioFile: AVAudioFile) {
        let inputFormat = buffer.format
        let outputFormat = audioFile.processingFormat
        let bufferToWrite: AVAudioPCMBuffer

        if inputFormat == outputFormat {
            bufferToWrite = buffer
        } else {
            if fileConverter == nil || fileConverterInputFormat?.isEqual(inputFormat) != true {
                fileConverterInputFormat = inputFormat
                fileConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
            }

            guard let converter = fileConverter else {
                try? audioFile.write(from: buffer)
                if let sessionAudioFile {
                    try? sessionAudioFile.write(from: buffer)
                }
                return
            }

            guard let convertedBuffer = convert(buffer, with: converter, outputFormat: outputFormat) else {
                try? audioFile.write(from: buffer)
                return
            }
            bufferToWrite = convertedBuffer
        }

        try? audioFile.write(from: bufferToWrite)
        if let sessionAudioFile {
            try? sessionAudioFile.write(from: bufferToWrite)
        }
    }

    private func convertToRealtimePCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let outputFormat = realtimeOutputFormat else { return nil }
        if let data = pcmData(from: buffer, outputFormat: outputFormat) {
            return data
        }

        realtimeConverter = nil
        realtimeInputFormat = nil
        return pcmData(from: buffer, outputFormat: outputFormat)
    }

    private func pcmData(from buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) -> Data? {
        if realtimeConverter == nil || realtimeInputFormat?.isEqual(buffer.format) != true {
            realtimeInputFormat = buffer.format
            realtimeConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }

        guard let converter = realtimeConverter,
              let convertedBuffer = convert(buffer, with: converter, outputFormat: outputFormat) else {
            return nil
        }

        let bytesPerFrame = Int(convertedBuffer.format.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(convertedBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0,
              let bytes = convertedBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        return Data(bytes: bytes, count: min(Int(convertedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize), byteCount))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var didProvideInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        guard error == nil, convertedBuffer.frameLength > 0 else { return nil }
        return convertedBuffer
    }
}
