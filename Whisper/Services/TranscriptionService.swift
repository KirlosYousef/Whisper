import Foundation
import Speech

class TranscriptionService {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let maxRetries = 5
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    init() {
        // Load API key from Config.plist
        print("🔍 Attempting to load API key from Config.plist...")
        
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist") {
            print("✅ Found Config.plist at: \(path)")
            
            if let config = NSDictionary(contentsOfFile: path) {
                print("✅ Successfully loaded Config.plist")
                
                if let key = config["OpenAIAPIKey"] as? String {
                    print("✅ Found OpenAIAPIKey in Config.plist")
                    
                    if key != "YOUR_API_KEY_HERE" && !key.isEmpty {
                        self.apiKey = key
                        print("✅ API key loaded successfully: \(String(key.prefix(10)))...")
                    } else {
                        self.apiKey = "YOUR_API_KEY_HERE"
                        print("⚠️  API key is placeholder or empty")
                    }
                } else {
                    self.apiKey = "YOUR_API_KEY_HERE"
                    print("❌ OpenAIAPIKey not found in Config.plist")
                }
            } else {
                self.apiKey = "YOUR_API_KEY_HERE"
                print("❌ Failed to load Config.plist as NSDictionary")
            }
        } else {
            self.apiKey = "YOUR_API_KEY_HERE"
            print("❌ Config.plist not found in app bundle")
            print("   Make sure Config.plist is added to the Xcode project")
        }
        
        if self.apiKey == "YOUR_API_KEY_HERE" {
            print("⚠️  Warning: API key not properly configured")
            print("   Please add your OpenAI API key to Whisper/Config.plist")
            print("   The app will use local speech recognition as fallback")
        }
        
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
            if let _ = error, retryCount < self?.maxRetries ?? 0 {
                // Exponential backoff with jitter: wait 2^retryCount + random(0,0.5)s
                let base = TimeInterval(pow(2.0, Double(retryCount)))
                let jitter = Double.random(in: 0...0.5)
                let delay = min(30.0, base + jitter)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self?.transcribeWithRetry(audioURL: audioURL, retryCount: retryCount + 1, completion: completion)
                }
            } else if let _ = error {
                // Max retries reached, try fallback
                self?.transcribeWithFallback(audioURL: audioURL, completion: completion)
            } else {
                completion(text, nil)
            }
        }
    }
    
    private func transcribeWithOpenAI(audioURL: URL, completion: @escaping (String?, Error?) -> Void) {
        // Check if API key is properly configured
        guard apiKey != "YOUR_API_KEY_HERE" && !apiKey.isEmpty else {
            completion(nil, TranscriptionError.apiKeyNotConfigured)
            return
        }
        
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
        body.append("gpt-4o-mini-transcribe\r\n".data(using: .utf8)!)
        // optional language hint
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("en\r\n".data(using: .utf8)!)
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
                } else if httpResponse.statusCode >= 400 {
                    // Try to parse error message from body
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = json["error"] as? [String: Any],
                       let message = err["message"] as? String {
                        completion(nil, NSError(domain: "TranscriptionService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
                        return
                    } else {
                        completion(nil, TranscriptionError.invalidResponse)
                        return
                    }
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
    case apiKeyNotConfigured
    
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
        case .apiKeyNotConfigured:
            return "OpenAI API key not configured. Please add your API key to Config.plist"
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

