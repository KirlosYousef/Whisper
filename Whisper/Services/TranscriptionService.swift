//
//  TranscriptionService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import Speech

class TranscriptionService {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let maxRetries = 5
    
    // Optional languages for transcription (empty = auto-detect with device hints)
    var preferredLanguages: [String] = []
    
    init() {
        // Load API key from Config.plist
        print("🔍 Attempting to load API key from Config.plist...")
        
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist") {
            print("✅ Found Config.plist at: \(path)")
            
            if let config = NSDictionary(contentsOfFile: path) {
                print("✅ Successfully loaded Config.plist")
                
                if let key = config["OpenAIAPIKey"] as? String {
                    print("✅ Found OpenAIAPIKey in Config.plist")
                    
                    if key != OpenAIConfiguration.placeholderAPIKey && !key.isEmpty {
                        self.apiKey = key
                        print("✅ API key loaded successfully: \(String(key.prefix(10)))...")
                    } else {
                        self.apiKey = OpenAIConfiguration.placeholderAPIKey
                        print("⚠️  API key is placeholder or empty")
                    }
                } else {
                    self.apiKey = OpenAIConfiguration.placeholderAPIKey
                    print("❌ OpenAIAPIKey not found in Config.plist")
                }
            } else {
                self.apiKey = OpenAIConfiguration.placeholderAPIKey
                print("❌ Failed to load Config.plist as NSDictionary")
            }
        } else {
            self.apiKey = OpenAIConfiguration.placeholderAPIKey
            print("❌ Config.plist not found in app bundle")
            print("   Make sure Config.plist is added to the Xcode project")
        }
        
        if self.apiKey == OpenAIConfiguration.placeholderAPIKey {
            print("⚠️  Warning: API key not properly configured")
            print("   Please add your OpenAI API key to Whisper/Config.plist")
            print("   The app will use local speech recognition as fallback")
        }
    }
    
    func requestSpeechRecognitionPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("Speech recognition authorization status: \(status.rawValue)")
        }
    }
    
    func transcribe(audioURL: URL, segmentStart: TimeInterval, duration: TimeInterval, completion: @escaping (String?, Error?) -> Void) {
        // Network connectivity is checked in RecordingViewModel using NetworkMonitor
        // No blocking check needed here - let the API call fail naturally if offline
        transcribeWithRetry(audioURL: audioURL, retryCount: 0, completion: completion)
    }
    
    private func transcribeWithRetry(audioURL: URL, retryCount: Int, model: String = OpenAIConfiguration.fileTranscriptionModel, completion: @escaping (String?, Error?) -> Void) {
        transcribeWithOpenAI(audioURL: audioURL, model: model) { [weak self] text, error in
            guard let self else { return }

            if let error {
                if self.isRetryable(error), retryCount < self.maxRetries {
                    let base = TimeInterval(pow(2.0, Double(retryCount)))
                    let jitter = Double.random(in: 0...0.5)
                    let delay = min(30.0, base + jitter)
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.transcribeWithRetry(audioURL: audioURL, retryCount: retryCount + 1, model: model, completion: completion)
                    }
                    return
                }

                if model == OpenAIConfiguration.fileTranscriptionModel {
                    self.transcribeWithRetry(
                        audioURL: audioURL,
                        retryCount: 0,
                        model: OpenAIConfiguration.fileTranscriptionFallbackModel,
                        completion: completion
                    )
                    return
                }

                completion(nil, error)
                return
            }

            completion(text, nil)
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError == .rateLimited || transcriptionError == .serverError
        }
        return false
    }
    
    private func transcribeWithOpenAI(audioURL: URL, model: String, completion: @escaping (String?, Error?) -> Void) {
        // Check if API key is properly configured
        guard apiKey != OpenAIConfiguration.placeholderAPIKey && !apiKey.isEmpty else {
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
        body.append("\(model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(OpenAIConfiguration.transcriptionPrompt)\r\n".data(using: .utf8)!)
        let languageHints = preferredLanguages.filter { !$0.isEmpty && $0.lowercased() != "auto" }
        if model == OpenAIConfiguration.fileTranscriptionModel {
            for language in languageHints {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"languages[]\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(language)\r\n".data(using: .utf8)!)
            }
        } else if let language = languageHints.first {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }
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
            
            guard let data = data else {
                completion(nil, TranscriptionError.invalidResponse)
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                completion(text, nil)
                return
            }

            guard let text = String(data: data, encoding: .utf8) else {
                completion(nil, TranscriptionError.invalidResponse)
                return
            }

            completion(text, nil)
        }
        task.resume()
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
