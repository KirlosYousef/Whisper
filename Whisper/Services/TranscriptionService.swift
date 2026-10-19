//
//  TranscriptionService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation

class TranscriptionService {
    private let endpoint = OpenAIConfiguration.audioTranscriptionsURL
    private let maxRetries = 5
    
    // Optional languages for transcription (empty = auto-detect with device hints)
    var preferredLanguages: [String] = []
    
    init() {
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
        let sessionID = audioSessionID ?? UUID().uuidString
        Task {
            do {
                let result = try await diarizeChunked(audioURL: audioURL, audioSessionID: sessionID)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    static func parseDiarizedJSON(_ data: Data) throws -> DiarizationResult {
        try SpeakerDiarizationParser.parse(data)
    }

    static func mergeAdjacentTurns(_ turns: [DiarizedTurn], gap: TimeInterval = 0.4) -> [DiarizedTurn] {
        SpeakerDiarizationParser.mergeAdjacentTurns(turns, gap: gap)
    }

    /// A speaker clip sent to the endpoint so later chunks reuse the speaker labels from the first chunk.
    private struct KnownSpeaker {
        var name: String
        var referenceDataURI: String
    }

    /// Splits the recording into bounded chunks, uploads them one at a time in order, and merges the results.
    /// Any chunk that fails after its retries fails the whole call.
    private func diarizeChunked(audioURL: URL, audioSessionID: String) async throws -> DiarizationResult {
        let totalDuration = try DiarizationAudioEncoder.duration(of: audioURL)
        let plan = DiarizationChunkPlanner.plan(totalDuration: totalDuration)
        guard !plan.isEmpty else {
            throw TranscriptionError.invalidResponse
        }

        var completedChunks: [(offset: TimeInterval, result: DiarizationResult)] = []
        var knownSpeakers: [KnownSpeaker] = []

        for (index, range) in plan.enumerated() {
            let chunkURL = try DiarizationAudioEncoder.encodeChunk(
                source: audioURL,
                start: range.start,
                duration: range.duration
            )
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let operationID = UUID().uuidString
            let parsed = try await diarizeChunkWithRetry(
                fileURL: chunkURL,
                chunkIndex: index,
                startTime: range.start,
                operationID: operationID,
                audioSessionID: audioSessionID,
                knownSpeakers: knownSpeakers
            )

            if index == 0, plan.count > 1 {
                knownSpeakers = Self.knownSpeakers(from: parsed.turns, sourceURL: audioURL)
            }

            let remapped = DiarizationResult(
                duration: parsed.duration,
                text: parsed.text,
                turns: DiarizationChunkMerger.remap(turns: parsed.turns, chunkIndex: index)
            )
            completedChunks.append((offset: range.start, result: remapped))
        }

        return DiarizationChunkMerger.merge(chunks: completedChunks)
    }

    /// Builds the speaker clips sent with later chunks. Clips that fail to encode are skipped.
    private static func knownSpeakers(from turns: [DiarizedTurn], sourceURL: URL) -> [KnownSpeaker] {
        DiarizationReferenceSelector.select(from: turns).compactMap { reference in
            guard let clip = try? DiarizationAudioEncoder.encodeReferenceClip(
                source: sourceURL,
                start: reference.start,
                duration: reference.duration
            ) else {
                return nil
            }
            return KnownSpeaker(
                name: "\(DiarizationChunkMerger.knownSpeakerPrefix)\(reference.speakerKey)",
                referenceDataURI: "data:audio/wav;base64,\(clip.base64EncodedString())"
            )
        }
    }

    /// Retries one chunk with the same operation ID and byte-identical request, so the server can replay its cached result.
    private func diarizeChunkWithRetry(
        fileURL: URL,
        chunkIndex: Int,
        startTime: TimeInterval,
        operationID: String,
        audioSessionID: String,
        knownSpeakers: [KnownSpeaker]
    ) async throws -> DiarizationResult {
        var retryCount = 0
        while true {
            do {
                return try await diarizeChunk(
                    fileURL: fileURL,
                    chunkIndex: chunkIndex,
                    startTime: startTime,
                    operationID: operationID,
                    audioSessionID: audioSessionID,
                    knownSpeakers: knownSpeakers
                )
            } catch {
                guard isRetryable(error), retryCount < maxRetries else {
                    throw error
                }
                let base = TimeInterval(pow(2.0, Double(retryCount)))
                let jitter = Double.random(in: 0...0.5)
                let delay = min(30.0, base + jitter)
                retryCount += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func diarizeChunk(
        fileURL: URL,
        chunkIndex: Int,
        startTime: TimeInterval,
        operationID: String,
        audioSessionID: String,
        knownSpeakers: [KnownSpeaker]
    ) async throws -> DiarizationResult {
        guard OpenAIConfiguration.isConfigured else {
            throw TranscriptionError.apiKeyNotConfigured
        }

        guard let fileData = try? Data(contentsOf: fileURL), !fileData.isEmpty else {
            throw TranscriptionError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk-\(chunkIndex).m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        appendField(name: "model", value: OpenAIConfiguration.diarizationModel)
        appendField(name: "response_format", value: "diarized_json")
        appendField(name: "chunking_strategy", value: "auto")

        let languageHints = preferredLanguages.filter { !$0.isEmpty && $0.lowercased() != "auto" }
        if let language = languageHints.first {
            appendField(name: "language", value: language)
        }

        for speaker in knownSpeakers {
            appendField(name: "known_speaker_names[]", value: speaker.name)
            appendField(name: "known_speaker_references[]", value: speaker.referenceDataURI)
        }

        body.append("--\(boundary)--\r\n")
        request.httpBody = body
        request.setValue(operationID, forHTTPHeaderField: "X-Usage-Operation-ID")
        request.setValue("diarization", forHTTPHeaderField: "X-Usage-Operation-Type")
        request.setValue(audioSessionID, forHTTPHeaderField: "X-Audio-Session-ID")
        request.setValue(String(Int(round(startTime * 1000))), forHTTPHeaderField: "X-Audio-Start-MS")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var authorizedRequest = request
        authorizedRequest.setValue(try await UsageAccessManager.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: authorizedRequest)
        if let httpResponse = response as? HTTPURLResponse,
           let error = Self.responseError(forStatus: httpResponse.statusCode, body: data) {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                await UsageAccessManager.shared.invalidateSession()
            }
            throw error
        }
        let parsed = try Self.parseDiarizedJSON(data)
        return DiarizationResult(
            duration: parsed.duration,
            text: parsed.text,
            turns: Self.mergeAdjacentTurns(parsed.turns)
        )
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
