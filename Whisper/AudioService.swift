import Foundation
#if os(iOS)
import AVFoundation

class AudioService: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var recordingSession: AVAudioSession!
    private var currentFilePath: String?
    private var recordingStartTime: Date?
    
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
            completion(true, currentFilePath)
        } catch {
            completion(false, nil)
        }
    }
    
    func pauseRecording() {
        audioRecorder?.pause()
    }
    
    func stopRecording(completion: @escaping (TimeInterval?, String?) -> Void) {
        audioRecorder?.stop()
        if let start = recordingStartTime, let filePath = currentFilePath {
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


