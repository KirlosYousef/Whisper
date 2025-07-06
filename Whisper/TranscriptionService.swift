import Foundation
import Speech

class TranscriptionService {
    private let apiKey = " "
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let maxRetries = 5
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    init() {
        requestSpeechRecognitionPermission()
    }
    
    private func requestSpeechRecognitionPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("Speech recognition authorization status: \(status.rawValue)")
        }
    }
    
    func transcribe(audioURL: URL, segmentStart: TimeInterval, duration: TimeInterval, completion: @escaping (String?, Error?) -> Void) {
        // Check network connectivity first
        guard isNetworkAvailable() else {
            completion(nil, TranscriptionError.noNetwork)
            return
        }
        
        transcribeWithRetry(audioURL: audioURL, retryCount: 0, completion: completion)
    }
    
    private func transcribeWithRetry(audioURL: URL, retryCount: Int, completion: @escaping (String?, Error?) -> Void) {
        transcribeWithOpenAI(audioURL: audioURL) { [weak self] text, error in
            if let error = error, retryCount < self?.maxRetries ?? 0 {
                // Exponential backoff: wait 2^retryCount seconds
                let delay = TimeInterval(pow(2.0, Double(retryCount)))
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self?.transcribeWithRetry(audioURL: audioURL, retryCount: retryCount + 1, completion: completion)
                }
            } else if let error = error {
                // Max retries reached, try fallback
                self?.transcribeWithFallback(audioURL: audioURL, completion: completion)
            } else {
                completion(text, nil)
            }
        }
    }
    
    private func transcribeWithOpenAI(audioURL: URL, completion: @escaping (String?, Error?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // file
        let filename = audioURL.lastPathComponent
        let mimetype = "audio/wav"
        if let fileData = try? Data(contentsOf: audioURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimetype)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        // model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        // response_format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)
        // end
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 429 {
                    completion(nil, TranscriptionError.rateLimited)
                    return
                } else if httpResponse.statusCode >= 500 {
                    completion(nil, TranscriptionError.serverError)
                    return
                }
            }
            
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                completion(nil, TranscriptionError.invalidResponse)
                return
            }
            
            completion(text, nil)
        }
        task.resume()
    }
    
    private func transcribeWithFallback(audioURL: URL, completion: @escaping (String?, Error?) -> Void) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            completion(nil, TranscriptionError.fallbackUnavailable)
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        
        speechRecognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                completion(nil, error)
                return
            }
            
            if let result = result, result.isFinal {
                completion(result.bestTranscription.formattedString, nil)
            }
        }
    }
    
    private func isNetworkAvailable() -> Bool {
        // Simple network check - in production, you might want to use Reachability
        guard let url = URL(string: "https://www.apple.com") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var isReachable = false
        
        URLSession.shared.dataTask(with: url) { _, response, _ in
            isReachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 3.0)
        return isReachable
    }
}

// MARK: - Error Types
enum TranscriptionError: LocalizedError {
    case noNetwork
    case rateLimited
    case serverError
    case invalidResponse
    case fallbackUnavailable
    
    var errorDescription: String? {
        switch self {
        case .noNetwork:
            return "No network connection available"
        case .rateLimited:
            return "API rate limit exceeded"
        case .serverError:
            return "Server error occurred"
        case .invalidResponse:
            return "Invalid response from server"
        case .fallbackUnavailable:
            return "Local transcription not available"
        }
    }
}

// Data append helper
private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

