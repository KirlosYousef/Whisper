import Foundation
protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didFinishSegment url: URL, duration: TimeInterval, startTime: TimeInterval)
}

#if os(iOS)
import AVFoundation

class AudioService: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var recordingSession: AVAudioSession!
    private var currentFilePath: String?
    private var recordingStartTime: Date?
    private var segmentTimer: Timer?
    private var segmentIndex: Int = 0
    private var segmentStartTime: TimeInterval = 0
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
        let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default)
            try recordingSession.setActive(true)
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            currentFilePath = audioFilename.path
            recordingStartTime = Date()
            // Start or restart timer
            segmentTimer?.invalidate()
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
                self?.finishCurrentSegmentAndStartNew()
            }
            completion?(true, currentFilePath)
        } catch {
            completion?(false, nil)
        }
    }

    private func finishCurrentSegmentAndStartNew() {
        guard let audioRecorder = audioRecorder, audioRecorder.isRecording else { return }
        audioRecorder.stop()
        let fileURL = URL(fileURLWithPath: currentFilePath ?? "")
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let startTime = segmentStartTime
        delegate?.audioService(self, didFinishSegment: fileURL, duration: duration, startTime: startTime)
        // Prepare for next segment
        segmentIndex += 1
        segmentStartTime += duration
        startNewSegment()
    }

    
    func pauseRecording() {
        audioRecorder?.pause()
    }
    
    func stopRecording(completion: @escaping (TimeInterval?, String?) -> Void) {
        segmentTimer?.invalidate()
        segmentTimer = nil
        if let audioRecorder = audioRecorder, audioRecorder.isRecording {
            audioRecorder.stop()
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
        audioRecorder = nil
        currentFilePath = nil
        recordingStartTime = nil
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


