import Foundation

class TranscriptionService {
    // Simulate async transcription
    func transcribe(audioURL: URL, segmentStart: TimeInterval, duration: TimeInterval, completion: @escaping (String?, Error?) -> Void) {
        // In a real app, send the audio segment to a backend
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // Simulate transcription result
            let fakeText = "Transcribed text for segment starting at \(Int(segmentStart))s"
            completion(fakeText, nil)
        }
    }
}
