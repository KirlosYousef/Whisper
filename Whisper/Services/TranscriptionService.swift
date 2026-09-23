//
//  TranscriptionService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import Speech

class TranscriptionService {
    private let endpoint = OpenAIConfiguration.audioTranscriptionsURL
    private let maxRetries = 5
    
    // Optional languages for transcription (empty = auto-detect with device hints)
    var preferredLanguages: [String] = []
    
    init() {
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

    func transcribe(audioURL: URL, segmentStart: TimeInterval, duration: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            transcribe(audioURL: audioURL, segmentStart: segmentStart, duration: duration) { text, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let text {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: TranscriptionError.invalidResponse)
                }
            }
        }
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
        // Check if the Worker URL is configured.
        guard OpenAIConfiguration.isConfigured else {
            completion(nil, TranscriptionError.apiKeyNotConfigured)
            return
        }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
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

    func diarize(audioURL: URL, completion: @escaping (Result<DiarizationResult, Error>) -> Void) {
        guard OpenAIConfiguration.isConfigured else {
            completion(.failure(TranscriptionError.apiKeyNotConfigured))
            return
        }
        diarizeWithRetry(audioURL: audioURL, retryCount: 0, completion: completion)
    }

    static func parseDiarizedJSON(_ data: Data) throws -> DiarizationResult {
        try SpeakerDiarizationParser.parse(data)
    }

    static func mergeAdjacentTurns(_ turns: [DiarizedTurn], gap: TimeInterval = 0.4) -> [DiarizedTurn] {
        SpeakerDiarizationParser.mergeAdjacentTurns(turns, gap: gap)
    }

    private func diarizeWithRetry(audioURL: URL, retryCount: Int, completion: @escaping (Result<DiarizationResult, Error>) -> Void) {
        diarizeWithOpenAI(audioURL: audioURL) { [weak self] result in
            guard let self else { return }

            if case .failure(let error) = result, self.isRetryable(error), retryCount < self.maxRetries {
                let base = TimeInterval(pow(2.0, Double(retryCount)))
                let jitter = Double.random(in: 0...0.5)
                let delay = min(30.0, base + jitter)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.diarizeWithRetry(audioURL: audioURL, retryCount: retryCount + 1, completion: completion)
                }
                return
            }

            completion(result)
        }
    }

    private func diarizeWithOpenAI(audioURL: URL, completion: @escaping (Result<DiarizationResult, Error>) -> Void) {
        guard OpenAIConfiguration.isConfigured else {
            completion(.failure(TranscriptionError.apiKeyNotConfigured))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        let filename = audioURL.lastPathComponent
        guard let fileData = try? Data(contentsOf: audioURL), !fileData.isEmpty else {
            completion(.failure(TranscriptionError.invalidResponse))
            return
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        appendField(name: "model", value: OpenAIConfiguration.diarizationModel)
        appendField(name: "response_format", value: "diarized_json")
        appendField(name: "chunking_strategy", value: "auto")

        let languageHints = preferredLanguages.filter { !$0.isEmpty && $0.lowercased() != "auto" }
        if let language = languageHints.first {
            appendField(name: "language", value: language)
        }

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 429 {
                    completion(.failure(TranscriptionError.rateLimited))
                    return
                } else if httpResponse.statusCode >= 500 {
                    completion(.failure(TranscriptionError.serverError))
                    return
                } else if httpResponse.statusCode >= 400 {
                    if let data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = json["error"] as? [String: Any],
                       let message = err["message"] as? String {
                        completion(.failure(NSError(domain: "TranscriptionService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])))
                        return
                    }
                    completion(.failure(TranscriptionError.invalidResponse))
                    return
                }
            }

            guard let data else {
                completion(.failure(TranscriptionError.invalidResponse))
                return
            }

            do {
                let parsed = try Self.parseDiarizedJSON(data)
                let merged = Self.mergeAdjacentTurns(parsed.turns)
                completion(.success(DiarizationResult(duration: parsed.duration, text: parsed.text, turns: merged)))
            } catch {
                completion(.failure(error))
            }
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
            return "AI service is not configured. Please update the Worker URL."
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
