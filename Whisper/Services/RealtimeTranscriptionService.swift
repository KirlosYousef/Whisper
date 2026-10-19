import AVFoundation
import Foundation

enum RealtimeTranscriptionEvent {
    case connected
    case reconnecting(Int)
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    /// The trial minutes ran out (refused at connect, or the Worker closed the stream with 4409).
    case usageExhausted
    /// No active subscription could be verified (refused at connect, or closed with 4403).
    case subscriptionRequired
    case failed(String)
    case disconnected
}

/// Streams 24 kHz PCM16 audio to the Worker's realtime proxy and reports transcript events on the main queue.
/// All mutable state is confined to `queue`.
final class RealtimeTranscriptionService {
    private enum RealtimeTuning {
        static let useServerVAD = false
        static let transcriptionDelay: String? = "high"
        static let noiseReductionType = "near_field"
        static let vadThreshold = 0.62
        static let vadPrefixPaddingMs = 420
        static let vadSilenceDurationMs = 720
    }

    private let queue = DispatchQueue(label: "RealtimeTranscriptionService")
    private var webSocket: URLSessionWebSocketTask?
    private var isSocketOpen = false
    private var isSessionReady = false
    /// `finish()` was called: no new audio, but keep receiving the last transcripts.
    private var isFinishing = false
    /// `disconnect()` or a terminal failure: ignore everything until the next `connect`.
    private var isClosed = true
    private var connectionToken = UUID()
    private var uncommittedAudioByteCount = 0
    private var audioTimeline = RealtimeAudioTimeline(startOffsetMs: 0)
    private var commitTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var skippedCommitIntervals = 0
    private var reconnectAttempts = 0
    private var isReconnectScheduled = false
    private var needsFreshToken = false
    private var lastLanguages: [String] = []
    private var audioSessionID = UUID().uuidString
    private var audioStartOffsetMs = 0
    private var isOnboardingDemo = false
    private let minimumCommitByteCount = 24_000
    private let targetCommitByteCount = 96_000
    private let appendChunkByteCount = 9_600
    private let maximumPendingAudioByteCount = 192_000
    private let maxReconnectAttempts = 5
    /// Called on the main queue.
    var onEvent: ((RealtimeTranscriptionEvent) -> Void)?

    var isConfigured: Bool {
        OpenAIConfiguration.isConfigured
    }

    func connect(
        languages: [String] = [],
        audioSessionID: String = UUID().uuidString,
        startOffsetMs: Int = 0,
        isOnboardingDemo: Bool = false
    ) {
        guard isConfigured else {
            emit(.failed("AI service is not configured. Update the Worker URL."))
            return
        }
        queue.async { [self] in
            lastLanguages = languages
            self.audioSessionID = audioSessionID
            audioStartOffsetMs = max(0, startOffsetMs)
            self.isOnboardingDemo = isOnboardingDemo
            reconnectAttempts = 0
            isReconnectScheduled = false
            needsFreshToken = false
            isFinishing = false
            isClosed = false
            closeSocketOnQueue(resetBuffers: true)
            openConnectionOnQueue()
        }
    }

    func sendAudio(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        queue.async { [self] in
            guard !isClosed, !isFinishing else { return }
            audioTimeline.enqueue(pcm16Data)
            if isSocketOpen, isSessionReady {
                if audioTimeline.bufferedByteCount >= appendChunkByteCount {
                    flushOutgoingAudioOnQueue(flushRemainder: false)
                }
            } else {
                audioTimeline.dropOldest(toFit: maximumPendingAudioByteCount)
            }
        }
    }

    /// Sends the buffered audio and commits it; the connection stays open for the final transcripts.
    func finish() {
        queue.async { [self] in
            guard !isClosed else { return }
            isFinishing = true
            flushOutgoingAudioOnQueue(flushRemainder: true)
            commitAudioBufferOnQueue(force: true)
        }
    }

    func disconnect() {
        queue.async { [self] in
            isClosed = true
            isReconnectScheduled = false
            closeSocketOnQueue(resetBuffers: true)
            emit(.disconnected)
        }
    }

    // MARK: Connection

    private func openConnectionOnQueue() {
        guard !isClosed else { return }
        guard let url = OpenAIConfiguration.realtimeURL else {
            terminate(with: .failed("Realtime URL is invalid."))
            return
        }
        let token = UUID()
        connectionToken = token
        let isDemo = isOnboardingDemo
        let refreshToken = needsFreshToken
        needsFreshToken = false
        Task { [weak self] in
            let authorization: Result<String, Error>
            do {
                if refreshToken {
                    await UsageAccessManager.shared.invalidateSession()
                }
                authorization = .success(try await UsageAccessManager.shared.authorizationHeader(forOnboardingDemo: isDemo))
            } catch {
                authorization = .failure(error)
            }
            self?.queue.async { self?.openSocketOnQueue(authorization: authorization, url: url, token: token) }
        }
    }

    private func openSocketOnQueue(authorization: Result<String, Error>, url: URL, token: UUID) {
        guard !isClosed, token == connectionToken else { return }
        let header: String
        switch authorization {
        case .failure(let error):
            let failure = (error as? UsageAccessError).map { RealtimeConnectionFailure.classify($0) } ?? .transient
            handleFailure(failure, message: error.localizedDescription)
            return
        case .success(let value):
            header = value
        }

        var request = URLRequest(url: url)
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue(audioSessionID, forHTTPHeaderField: "X-Audio-Session-ID")
        request.setValue(String(audioStartOffsetMs), forHTTPHeaderField: "X-Audio-Start-MS")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocket = task
        isSocketOpen = true
        isSessionReady = false
        skippedCommitIntervals = 0
        // Anything uncommitted went to the previous socket; the Worker skips audio it already received.
        uncommittedAudioByteCount = 0
        task.resume()
        receiveNextMessage(on: task, token: token)
        sendSessionUpdateOnQueue(languages: lastLanguages)
        if !RealtimeTuning.useServerVAD {
            startCommitTimer()
        }
        startPingTimer()
    }

    private func closeSocketOnQueue(resetBuffers: Bool) {
        connectionToken = UUID()
        isSocketOpen = false
        isSessionReady = false
        stopCommitTimer()
        stopPingTimer()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if resetBuffers {
            uncommittedAudioByteCount = 0
            audioTimeline.reset(startOffsetMs: audioStartOffsetMs)
            skippedCommitIntervals = 0
        }
    }

    private func terminate(with event: RealtimeTranscriptionEvent) {
        isClosed = true
        isReconnectScheduled = false
        closeSocketOnQueue(resetBuffers: true)
        emit(event)
    }

    private func handleFailure(_ failure: RealtimeConnectionFailure, message: String) {
        guard !isClosed else { return }
        switch failure {
        case .usageExhausted:
            terminate(with: .usageExhausted)
        case .subscriptionRequired:
            Task { await UsageAccessManager.shared.invalidateSession() }
            terminate(with: .subscriptionRequired)
        case .updateRequired:
            terminate(with: .failed(UsageAccessError.updateRequired.localizedDescription))
        case .sessionExpired:
            needsFreshToken = true
            scheduleReconnect(message: message)
        case .transient:
            scheduleReconnect(message: message)
        }
    }

    private func scheduleReconnect(message: String) {
        guard !isClosed, !isFinishing, !isReconnectScheduled else { return }
        closeSocketOnQueue(resetBuffers: false)
        guard reconnectAttempts < maxReconnectAttempts else {
            terminate(with: .failed(message))
            return
        }
        isReconnectScheduled = true
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        emit(.reconnecting(attempt))
        let delay = min(8.0, pow(2.0, Double(attempt - 1)) * 0.5)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isReconnectScheduled else { return }
            self.isReconnectScheduled = false
            self.openConnectionOnQueue()
        }
    }

    private func socketFailed(_ task: URLSessionWebSocketTask, token: UUID, message: String) {
        guard token == connectionToken, !isClosed else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let closeCode = task.closeCode == .invalid ? nil : task.closeCode.rawValue
        let failure = RealtimeConnectionFailure.classify(httpStatus: status, closeCode: closeCode)
        // After `finish()` only a usage or subscription close matters; a plain close is the normal end.
        if isFinishing, !failure.isTerminal { return }
        handleFailure(failure, message: message)
    }

    // MARK: Session

    private func sendSessionUpdateOnQueue(languages: [String]) {
        var transcription: [String: Any] = [
            "model": OpenAIConfiguration.realtimeTranscriptionModel,
            "prompt": OpenAIConfiguration.transcriptionPrompt
        ]
        if let delay = RealtimeTuning.transcriptionDelay {
            transcription["delay"] = delay
        }
        let turnDetection: Any = RealtimeTuning.useServerVAD
            ? [
                "type": "server_vad",
                "threshold": RealtimeTuning.vadThreshold,
                "prefix_padding_ms": RealtimeTuning.vadPrefixPaddingMs,
                "silence_duration_ms": RealtimeTuning.vadSilenceDurationMs
            ]
            : NSNull()

        let languageHints = languages.filter { !$0.isEmpty && $0.lowercased() != "auto" }
        if !languageHints.isEmpty {
            transcription["languages"] = languageHints
        }

        sendJSONOnQueue([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "noise_reduction": [
                            "type": RealtimeTuning.noiseReductionType
                        ],
                        "transcription": transcription,
                        "turn_detection": turnDetection
                    ]
                ]
            ]
        ])
    }

    private func markSessionReadyOnQueue() {
        guard isSocketOpen, !isSessionReady else { return }
        isSessionReady = true
        reconnectAttempts = 0
        flushOutgoingAudioOnQueue(flushRemainder: false)
        emit(.connected)
    }

    // MARK: Timers

    private func startCommitTimer() {
        stopCommitTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.commitAudioBufferOnQueue(force: false)
        }
        commitTimer = timer
        timer.resume()
    }

    private func stopCommitTimer() {
        commitTimer?.cancel()
        commitTimer = nil
    }

    private func startPingTimer() {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isSocketOpen, let webSocket = self.webSocket else { return }
            let token = self.connectionToken
            webSocket.sendPing { [weak self] error in
                guard let error else { return }
                self?.queue.async {
                    self?.socketFailed(webSocket, token: token, message: error.localizedDescription)
                }
            }
        }
        pingTimer = timer
        timer.resume()
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: Audio

    private func commitAudioBufferOnQueue(force: Bool) {
        guard isSocketOpen, isSessionReady else {
            return
        }

        flushOutgoingAudioOnQueue(flushRemainder: false)

        let requiredBytes: Int
        if force {
            requiredBytes = 1
        } else if uncommittedAudioByteCount >= targetCommitByteCount {
            requiredBytes = targetCommitByteCount
        } else {
            skippedCommitIntervals += 1
            if skippedCommitIntervals >= 1 && uncommittedAudioByteCount >= minimumCommitByteCount {
                requiredBytes = minimumCommitByteCount
            } else {
                return
            }
        }

        guard uncommittedAudioByteCount >= requiredBytes else {
            return
        }

        skippedCommitIntervals = 0
        uncommittedAudioByteCount = 0
        sendJSONOnQueue(["type": "input_audio_buffer.commit"])
    }

    private func flushOutgoingAudioOnQueue(flushRemainder: Bool) {
        guard isSocketOpen, isSessionReady else { return }
        let appends = audioTimeline.takeAppends(maxBytes: appendChunkByteCount, flushRemainder: flushRemainder)
        for append in appends {
            appendAudioOnQueue(append.data, startMs: append.startMs)
        }
    }

    private func appendAudioOnQueue(_ pcm16Data: Data, startMs: Int) {
        uncommittedAudioByteCount += pcm16Data.count
        sendJSONOnQueue([
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
            "audio_start_ms": startMs
        ])
    }

    // MARK: Messages

    private func sendJSONOnQueue(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        guard let webSocket, isSocketOpen else { return }
        let token = connectionToken
        webSocket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                self?.socketFailed(webSocket, token: token, message: error.localizedDescription)
            }
        }
    }

    private func receiveNextMessage(on task: URLSessionWebSocketTask, token: UUID) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard token == self.connectionToken, !self.isClosed else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if self.isSocketOpen, token == self.connectionToken {
                        self.receiveNextMessage(on: task, token: token)
                    }
                case .failure(let error):
                    self.socketFailed(task, token: token, message: error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            data = nil
        }

        guard let data,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "session.updated", "transcription_session.updated":
            markSessionReadyOnQueue()
        case "conversation.item.input_audio_transcription.delta":
            let itemID = event["item_id"] as? String ?? "current"
            let text = (event["delta"] as? String)
                ?? (event["transcript"] as? String)
                ?? (event["text"] as? String)
                ?? ""
            if !text.isEmpty {
                emit(.delta(itemID: itemID, text: text))
            }
        case "conversation.item.input_audio_transcription.completed":
            let itemID = event["item_id"] as? String ?? UUID().uuidString
            let transcript = (event["transcript"] as? String) ?? ""
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit(.completed(itemID: itemID, transcript: transcript))
            }
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "Realtime transcription failed."
            if message.localizedCaseInsensitiveContains("buffer") &&
                (message.localizedCaseInsensitiveContains("empty") || message.localizedCaseInsensitiveContains("too small")) {
                return
            }
            handleFailure(.transient, message: message)
        default:
            break
        }
    }

    private func emit(_ event: RealtimeTranscriptionEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}

enum OpenAIConfiguration {
    // Replace this with the deployed Worker URL. The OpenAI key never belongs in the iOS app.
    static let workerBaseURL = "https://whisper-openai-proxy.kirlos-yousef.workers.dev"
    static let workerURLPlaceholder = "https://whisper-openai-proxy.YOUR_ACCOUNT.workers.dev"
    static let realtimeTranscriptionModel = "gpt-live-transcribe"
    static let fileTranscriptionModel = "gpt-transcribe"
    static let fileTranscriptionFallbackModel = "gpt-4o-transcribe"
    static let diarizationModel = "gpt-4o-transcribe-diarize"
    static let transcriptionPrompt = "Voice note. Transcribe in the speaker's original language. Do not translate or switch languages."

    static var isConfigured: Bool {
        workerBaseURL != workerURLPlaceholder && workerBaseURL.hasPrefix("https://")
    }

    static var audioTranscriptionsURL: URL {
        URL(string: "\(workerBaseURL)/v1/audio/transcriptions")!
    }

    static var chatCompletionsURL: URL {
        URL(string: "\(workerBaseURL)/v1/chat/completions")!
    }

    static var realtimeURL: URL? {
        guard var components = URLComponents(string: workerBaseURL) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/realtime"
        components.query = "intent=transcription"
        return components.url
    }
}
