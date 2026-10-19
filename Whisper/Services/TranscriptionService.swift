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
    
    func transcribe(
        audioURL: URL,
        segmentStart: TimeInterval,
        duration: TimeInterval,
        audioSessionID: String? = nil,
        isOnboardingDemo: Bool = false,
        completion: @escaping (String?, Error?) -> Void
    ) {
        // Network connectivity is checked in RecordingViewModel using NetworkMonitor
        // No blocking check needed here - let the API call fail naturally if offline
        let operationID = UUID().uuidString
        transcribeWithRetry(
            audioURL: audioURL,
            retryCount: 0,
            operationID: operationID,
            audioSessionID: audioSessionID ?? operationID,
            startMs: max(0, Int((segmentStart * 1_000).rounded(.down))),
            isOnboardingDemo: isOnboardingDemo,
            completion: completion
        )
    }

    func transcribe(
        audioURL: URL,
        segmentStart: TimeInterval,
        duration: TimeInterval,
        audioSessionID: String? = nil,
        isOnboardingDemo: Bool = false
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            transcribe(
                audioURL: audioURL,
                segmentStart: segmentStart,
                duration: duration,
                audioSessionID: audioSessionID,
                isOnboardingDemo: isOnboardingDemo
            ) { text, error in
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
    
    private func transcribeWithRetry(
        audioURL: URL,
        retryCount: Int,
        model: String = OpenAIConfiguration.fileTranscriptionModel,
        operationID: String,
        audioSessionID: String,
        startMs: Int,
        isOnboardingDemo: Bool,
        completion: @escaping (String?, Error?) -> Void
    ) {
        transcribeWithOpenAI(
            audioURL: audioURL,
            model: model,
            operationID: operationID,
            audioSessionID: audioSessionID,
            startMs: startMs,
            isOnboardingDemo: isOnboardingDemo
        ) { [weak self] text, error in
            guard let self else { return }

            if let error {
                if error is UsageAccessError || (error as? TranscriptionError) == .alreadyProcessed {
                    completion(nil, error)
                    return
                }
                if self.isRetryable(error), retryCount < self.maxRetries {
                    let base = TimeInterval(pow(2.0, Double(retryCount)))
                    let jitter = Double.random(in: 0...0.5)
                    let delay = min(30.0, base + jitter)
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.transcribeWithRetry(audioURL: audioURL, retryCount: retryCount + 1, model: model, operationID: operationID, audioSessionID: audioSessionID, startMs: startMs, isOnboardingDemo: isOnboardingDemo, completion: completion)
                    }
                    return
                }

                if model == OpenAIConfiguration.fileTranscriptionModel {
                    self.transcribeWithRetry(
                        audioURL: audioURL,
                        retryCount: 0,
                        model: OpenAIConfiguration.fileTranscriptionFallbackModel,
                        operationID: operationID,
                        audioSessionID: audioSessionID,
                        startMs: startMs,
                        isOnboardingDemo: isOnboardingDemo,
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
    
    private func transcribeWithOpenAI(
        audioURL: URL,
        model: String,
        operationID: String,
        audioSessionID: String,
        startMs: Int,
        isOnboardingDemo: Bool,
        completion: @escaping (String?, Error?) -> Void
    ) {
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

        request.setValue(operationID, forHTTPHeaderField: "X-Usage-Operation-ID")
        request.setValue("transcription", forHTTPHeaderField: "X-Usage-Operation-Type")
        request.setValue(audioSessionID, forHTTPHeaderField: "X-Audio-Session-ID")
        request.setValue(String(startMs), forHTTPHeaderField: "X-Audio-Start-MS")

        Task {
            do {
                var authorizedRequest = request
                authorizedRequest.setValue(
                    try await UsageAccessManager.shared.authorizationHeader(forOnboardingDemo: isOnboardingDemo),
                    forHTTPHeaderField: "Authorization"
                )
                let (data, response) = try await URLSession.shared.data(for: authorizedRequest)
            
            if let httpResponse = response as? HTTPURLResponse,
               let error = Self.responseError(forStatus: httpResponse.statusCode, body: data) {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    await UsageAccessManager.shared.invalidateSession()
                }
                completion(nil, error)
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
            } catch {
                completion(nil, error)
            }
        }
    }

    /// Maps a Worker response status to the error the caller should see, or nil when the response is usable.
    /// Side effects (such as invalidating the usage session on 401/403) belong to the caller.
    static func responseError(forStatus statusCode: Int, body: Data?) -> Error? {
        guard statusCode >= 400 else { return nil }
        if statusCode >= 500 { return TranscriptionError.serverError }

        var json: [String: Any]?
        if let body {
            json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }

        switch statusCode {
        case 401:
            return TranscriptionError.serverError
        case 402:
            return UsageAccessError.trialExhausted
        case 403:
            return UsageAccessError.noVerifiedSubscription
        case 409:
            let code = json?["code"] as? String
            if code == "operation_pending" {
                return TranscriptionError.serverError
            }
            return TranscriptionError.alreadyProcessed
        case 426:
            return UsageAccessError.updateRequired
        case 429:
            return TranscriptionError.rateLimited
        default:
            if let message = json?["error"] as? String {
                return NSError(domain: "TranscriptionService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return TranscriptionError.invalidResponse
        }
    }

    func diarize(audioURL: URL, audioSessionID: String? = nil, completion: @escaping (Result<DiarizationResult, Error>) -> Void) {
        guard OpenAIConfiguration.isConfigured else {
            completion(.failure(TranscriptionError.apiKeyNotConfigured))
            return
        }
        diarizeWithRetry(audioURL: audioURL, retryCount: 0, operationID: UUID().uuidString, audioSessionID: audioSessionID ?? UUID().uuidString, completion: completion)
    }

    static func parseDiarizedJSON(_ data: Data) throws -> DiarizationResult {
        try SpeakerDiarizationParser.parse(data)
    }

    static func mergeAdjacentTurns(_ turns: [DiarizedTurn], gap: TimeInterval = 0.4) -> [DiarizedTurn] {
        SpeakerDiarizationParser.mergeAdjacentTurns(turns, gap: gap)
    }

    private func diarizeWithRetry(audioURL: URL, retryCount: Int, operationID: String, audioSessionID: String, completion: @escaping (Result<DiarizationResult, Error>) -> Void) {
        diarizeWithOpenAI(audioURL: audioURL, operationID: operationID, audioSessionID: audioSessionID) { [weak self] result in
            guard let self else { return }

            if case .failure(let error) = result, self.isRetryable(error), retryCount < self.maxRetries {
                let base = TimeInterval(pow(2.0, Double(retryCount)))
                let jitter = Double.random(in: 0...0.5)
                let delay = min(30.0, base + jitter)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.diarizeWithRetry(audioURL: audioURL, retryCount: retryCount + 1, operationID: operationID, audioSessionID: audioSessionID, completion: completion)
                }
                return
            }

            completion(result)
        }
    }

    private func diarizeWithOpenAI(audioURL: URL, operationID: String, audioSessionID: String, completion: @escaping (Result<DiarizationResult, Error>) -> Void) {
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
        request.setValue(operationID, forHTTPHeaderField: "X-Usage-Operation-ID")
        request.setValue("diarization", forHTTPHeaderField: "X-Usage-Operation-Type")
        request.setValue(audioSessionID, forHTTPHeaderField: "X-Audio-Session-ID")
        request.setValue("0", forHTTPHeaderField: "X-Audio-Start-MS")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)

        Task {
            do {
                var authorizedRequest = request
                authorizedRequest.setValue(try await UsageAccessManager.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: authorizedRequest)
                if let httpResponse = response as? HTTPURLResponse,
                   let error = Self.responseError(forStatus: httpResponse.statusCode, body: data) {
                    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                        await UsageAccessManager.shared.invalidateSession()
                    }
                    completion(.failure(error))
                    return
                }
                let parsed = try Self.parseDiarizedJSON(data)
                let merged = Self.mergeAdjacentTurns(parsed.turns)
                completion(.success(DiarizationResult(duration: parsed.duration, text: parsed.text, turns: merged)))
            } catch {
                completion(.failure(error))
            }
        }
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
    case alreadyProcessed
    
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
        case .alreadyProcessed:
            return "This audio was already processed."
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
