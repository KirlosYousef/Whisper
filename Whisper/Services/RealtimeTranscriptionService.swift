import AVFoundation
import Foundation

enum RealtimeTranscriptionEvent {
    case connected
    case reconnecting(Int)
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case failed(String)
    case disconnected
}

final class RealtimeTranscriptionService {
    private enum RealtimeTuning {
        static let useServerVAD = false
        static let transcriptionDelay: String? = "high"
        static let noiseReductionType = "near_field"
        static let vadThreshold = 0.62
        static let vadPrefixPaddingMs = 420
        static let vadSilenceDurationMs = 720
    }

    private let apiKey: String
    private var webSocket: URLSessionWebSocketTask?
    private var isSocketOpen = false
    private var isSessionReady = false
    private var isStopping = false
    private var connectionToken = UUID()
    private var uncommittedAudioByteCount = 0
    private var pendingAudioChunks: [Data] = []
    private var pendingAudioByteCount = 0
    private var outgoingAudioBuffer = Data()
    private var commitTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var skippedCommitIntervals = 0
    private var handleErrorCount = 0
    private var reconnectAttempts = 0
    private var isReconnectScheduled = false
    private var lastLanguages: [String] = []
    private let sendQueue = DispatchQueue(label: "RealtimeTranscriptionService.send")
    private let minimumCommitByteCount = 24_000
    private let targetCommitByteCount = 96_000
    private let appendChunkByteCount = 9_600
    private let maximumPendingAudioByteCount = 192_000
    private let maxReconnectAttempts = 5
    var onEvent: ((RealtimeTranscriptionEvent) -> Void)?

    init(apiKey: String = OpenAIConfiguration.apiKey) {
        self.apiKey = apiKey
    }

    var isConfigured: Bool {
        apiKey != OpenAIConfiguration.placeholderAPIKey && !apiKey.isEmpty
    }

    func connect(languages: [String] = []) {
        guard isConfigured else {
            onEvent?(.failed("OpenAI API key is not configured."))
            return
        }

        lastLanguages = languages
        reconnectAttempts = 0
        isReconnectScheduled = false
        isStopping = false
        handleErrorCount = 0
        closeSocket(notify: false, resetBuffers: true)
        openConnection()
    }

    func sendAudio(_ pcm16Data: Data) {
        guard !pcm16Data.isEmpty else { return }
        sendQueue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            if self.isSocketOpen, self.isSessionReady {
                self.outgoingAudioBuffer.append(pcm16Data)
                if self.outgoingAudioBuffer.count >= self.appendChunkByteCount {
                    self.flushOutgoingAudioOnQueue()
                }
            } else {
                self.bufferPendingAudioOnQueue(pcm16Data)
            }
        }
    }

    func finish() {
        isStopping = true
        sendQueue.async { [weak self] in
            self?.flushOutgoingAudioOnQueue()
            self?.commitAudioBufferOnQueue(force: true)
        }
    }

    func disconnect() {
        isStopping = true
        reconnectAttempts = maxReconnectAttempts
        closeSocket(notify: true, resetBuffers: true)
    }

    private func openConnection() {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            onEvent?(.failed("Realtime URL is invalid."))
            return
        }

        let token = UUID()
        connectionToken = token
        isStopping = false
        isReconnectScheduled = false
        handleErrorCount = 0

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocket = task
        task.resume()
        isSocketOpen = true
        isSessionReady = false
        skippedCommitIntervals = 0
        receiveNextMessage(token: token)
        sendSessionUpdate(languages: lastLanguages)
        if !RealtimeTuning.useServerVAD {
            startCommitTimer()
        }
        startPingTimer()
    }

    private func closeSocket(notify: Bool, resetBuffers: Bool) {
        connectionToken = UUID()
        isSocketOpen = false
        isSessionReady = false
        stopCommitTimer()
        stopPingTimer()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if resetBuffers {
            uncommittedAudioByteCount = 0
            pendingAudioChunks = []
            pendingAudioByteCount = 0
            outgoingAudioBuffer = Data()
            skippedCommitIntervals = 0
        }
        if notify {
            onEvent?(.disconnected)
        }
    }

    private func sendSessionUpdate(languages: [String]) {
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

        sendJSON([
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

    private func startCommitTimer() {
        stopCommitTimer()
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
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
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isSocketOpen, let webSocket = self.webSocket else { return }
            webSocket.sendPing { [weak self] error in
                if let error {
                    self?.handleError(error)
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

    private func commitAudioBufferOnQueue(force: Bool) {
        guard isSocketOpen, isSessionReady else {
            return
        }

        flushOutgoingAudioOnQueue()

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

    private func flushOutgoingAudioOnQueue() {
        guard !outgoingAudioBuffer.isEmpty else { return }
        let data = outgoingAudioBuffer
        outgoingAudioBuffer = Data()
        appendAudioOnQueue(data)
    }

    private func appendAudioOnQueue(_ pcm16Data: Data) {
        uncommittedAudioByteCount += pcm16Data.count
        sendJSONOnQueue([
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString()
        ])
    }

    private func bufferPendingAudioOnQueue(_ pcm16Data: Data) {
        pendingAudioChunks.append(pcm16Data)
        pendingAudioByteCount += pcm16Data.count

        while pendingAudioByteCount > maximumPendingAudioByteCount, !pendingAudioChunks.isEmpty {
            let dropped = pendingAudioChunks.removeFirst()
            pendingAudioByteCount -= dropped.count
        }
    }

    private func markSessionReady() {
        sendQueue.async { [weak self] in
            guard let self, self.isSocketOpen, !self.isSessionReady else { return }
            self.isSessionReady = true
            self.reconnectAttempts = 0
            let chunks = self.pendingAudioChunks
            self.pendingAudioChunks = []
            self.pendingAudioByteCount = 0
            chunks.forEach { self.outgoingAudioBuffer.append($0) }
            self.flushOutgoingAudioOnQueue()
            DispatchQueue.main.async {
                self.onEvent?(.connected)
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        sendQueue.async { [weak self] in
            self?.sendJSONOnQueue(object)
        }
    }

    private func sendJSONOnQueue(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        guard let webSocket, isSocketOpen else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleError(error)
            }
        }
    }

    private func receiveNextMessage(token: UUID) {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            guard token == self.connectionToken else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                if self.isSocketOpen, token == self.connectionToken {
                    self.receiveNextMessage(token: token)
                }
            case .failure(let error):
                if !self.isStopping {
                    self.handleError(error)
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
            markSessionReady()
        case "conversation.item.input_audio_transcription.delta":
            let itemID = event["item_id"] as? String ?? "current"
            let text = (event["delta"] as? String)
                ?? (event["transcript"] as? String)
                ?? (event["text"] as? String)
                ?? ""
            if !text.isEmpty {
                onEvent?(.delta(itemID: itemID, text: text))
            }
        case "conversation.item.input_audio_transcription.completed":
            let itemID = event["item_id"] as? String ?? UUID().uuidString
            let transcript = (event["transcript"] as? String) ?? ""
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onEvent?(.completed(itemID: itemID, transcript: transcript))
            }
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "Realtime transcription failed."
            if message.localizedCaseInsensitiveContains("buffer") &&
                (message.localizedCaseInsensitiveContains("empty") || message.localizedCaseInsensitiveContains("too small")) {
                return
            }
            handleTransientFailure(message)
        default:
            break
        }
    }

    private func handleError(_ error: Error) {
        handleErrorCount += 1
        handleTransientFailure(error.localizedDescription)
    }

    private func handleTransientFailure(_ message: String) {
        sendQueue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            guard !self.isReconnectScheduled else { return }

            if self.reconnectAttempts >= self.maxReconnectAttempts {
                self.closeSocket(notify: false, resetBuffers: false)
                DispatchQueue.main.async {
                    self.onEvent?(.failed(message))
                }
                return
            }

            self.isReconnectScheduled = true
            self.closeSocket(notify: false, resetBuffers: false)
            self.reconnectAttempts += 1
            let delay = min(8.0, pow(2.0, Double(self.reconnectAttempts - 1)) * 0.5)
            DispatchQueue.main.async {
                self.onEvent?(.reconnecting(self.reconnectAttempts))
            }
            self.sendQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopping else { return }
                self.openConnection()
            }
        }
    }
}

enum OpenAIConfiguration {
    static let placeholderAPIKey = "YOUR_API_KEY_HERE"
    static let realtimeTranscriptionModel = "gpt-live-transcribe"
    static let fileTranscriptionModel = "gpt-transcribe"
    static let fileTranscriptionFallbackModel = "gpt-4o-transcribe"
    static let diarizationModel = "gpt-4o-transcribe-diarize"
    static let transcriptionPrompt = "Voice note. Transcribe in the speaker's original language. Do not translate or switch languages."

    static var apiKey: String {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let config = NSDictionary(contentsOfFile: path),
              let key = config["OpenAIAPIKey"] as? String,
              !key.isEmpty else {
            return placeholderAPIKey
        }

        return key
    }
}
