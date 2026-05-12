import AVFoundation
import Foundation

enum RealtimeTranscriptionEvent {
    case connected
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case failed(String)
    case disconnected
}

final class RealtimeTranscriptionService {
    private enum RealtimeTuning {
        static let useServerVAD = false
        static let transcriptionDelay: String? = nil
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
    private var commitTimer: DispatchSourceTimer?
    private var skippedCommitIntervals = 0
    private let sendQueue = DispatchQueue(label: "RealtimeTranscriptionService.send")
    private let minimumCommitByteCount = 4_800
    private let targetCommitByteCount = 24_000
    private let maximumPendingAudioByteCount = 96_000
    var onEvent: ((RealtimeTranscriptionEvent) -> Void)?

    init(apiKey: String = OpenAIConfiguration.apiKey) {
        self.apiKey = apiKey
    }

    var isConfigured: Bool {
        apiKey != OpenAIConfiguration.placeholderAPIKey && !apiKey.isEmpty
    }

    func connect(language: String?) {
        guard isConfigured else {
            onEvent?(.failed("OpenAI API key is not configured."))
            return
        }

        disconnect()
        let token = UUID()
        connectionToken = token
        isStopping = false

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            onEvent?(.failed("Realtime URL is invalid."))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocket = task
        task.resume()
        isSocketOpen = true
        isSessionReady = false
        skippedCommitIntervals = 0
        receiveNextMessage(token: token)
        sendSessionUpdate(language: language)
        if !RealtimeTuning.useServerVAD {
            startCommitTimer()
        }
    }

    func sendAudio(_ pcm16Data: Data) {
        guard isSocketOpen, !pcm16Data.isEmpty else { return }
        sendQueue.async { [weak self] in
            guard let self, self.isSocketOpen else { return }
            if self.isSessionReady {
                self.appendAudioOnQueue(pcm16Data)
            } else {
                self.bufferPendingAudioOnQueue(pcm16Data)
            }
        }
    }

    func finish() {
        sendQueue.async { [weak self] in
            self?.commitAudioBufferOnQueue(force: true)
        }
    }

    func disconnect() {
        isStopping = true
        connectionToken = UUID()
        isSocketOpen = false
        isSessionReady = false
        stopCommitTimer()
        uncommittedAudioByteCount = 0
        pendingAudioChunks = []
        pendingAudioByteCount = 0
        skippedCommitIntervals = 0
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        onEvent?(.disconnected)
    }

    private func sendSessionUpdate(language: String?) {
        var transcription: [String: Any] = [
            "model": "gpt-realtime-whisper"
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

        if let language, !language.isEmpty, language.lowercased() != "auto" {
            transcription["language"] = language
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
        timer.schedule(deadline: .now() + 1.4, repeating: 1.4)
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

    private func commitAudioBufferOnQueue(force: Bool) {
        guard isSocketOpen, isSessionReady else {
            return
        }

        let requiredBytes: Int
        if force {
            requiredBytes = minimumCommitByteCount
        } else if uncommittedAudioByteCount >= targetCommitByteCount {
            requiredBytes = targetCommitByteCount
        } else {
            skippedCommitIntervals += 1
            // Avoid stalling if audio cadence is lower than expected.
            // After one timer interval, accept smaller commits.
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
            let chunks = self.pendingAudioChunks
            self.pendingAudioChunks = []
            self.pendingAudioByteCount = 0
            chunks.forEach { self.appendAudioOnQueue($0) }
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
            onEvent?(.failed(message))
        default:
            break
        }
    }

    private func handleError(_ error: Error) {
        guard !isStopping else { return }
        isSocketOpen = false
        isSessionReady = false
        onEvent?(.failed(error.localizedDescription))
    }
}

enum OpenAIConfiguration {
    static let placeholderAPIKey = "YOUR_API_KEY_HERE"

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
