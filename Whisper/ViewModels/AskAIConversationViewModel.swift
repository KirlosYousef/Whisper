import SwiftUI

enum AskAIConversationContext {
    case onboarding
    case recording(duration: TimeInterval)

    var analyticsProperties: [String: Any] {
        switch self {
        case .onboarding:
            return ["conversation_context": "onboarding_demo"]
        case .recording(let duration):
            return [
                "conversation_context": "recording",
                "recording_duration": duration
            ]
        }
    }
}

@MainActor
final class AskAIConversationViewModel: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        let content: String
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isResponding = false
    @Published private(set) var isGeneratingSuggestions = false
    @Published private(set) var errorMessage: String?

    private let transcript: String
    private let context: AskAIConversationContext
    private var hasLoadedSuggestions = false
    private var suggestionTask: Task<[String], Never>?
    private var suggestionGenerationID = UUID()

    init(transcript: String, context: AskAIConversationContext) {
        self.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = context
    }

    var canSend: Bool {
        !isResponding && !transcript.isEmpty
    }

    func loadSuggestionsIfNeeded() async {
        guard !hasLoadedSuggestions else { return }
        hasLoadedSuggestions = true
        await regenerateSuggestions()
    }

    func send(_ input: String, source: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !trimmed.isEmpty else { return }

        suggestionTask?.cancel()
        suggestions = []
        errorMessage = nil
        let priorHistory = serviceHistory
        messages.append(Message(role: .user, content: trimmed))
        isResponding = true
        trackRequest(message: trimmed, source: source)

        Task {
            do {
                let answer = try await SummaryService.continueTranscriptConversation(
                    transcript: transcript,
                    history: priorHistory,
                    message: trimmed
                )
                guard !Task.isCancelled else { return }
                let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    errorMessage = "Revera didn’t return an answer. Please try again."
                    trackFailure(source: source, category: "empty_response")
                } else {
                    messages.append(Message(role: .assistant, content: cleaned))
                    HapticsManager.shared.selection()
                    trackCompletion(answer: cleaned, source: source)
                    if case .recording = context {
                        LovePromptManager.shared.noteAskAct()
                    }
                }
            } catch {
                errorMessage = "I couldn’t answer that right now. Please try again."
                trackFailure(source: source, category: "request_failed")
            }
            isResponding = false
            await regenerateSuggestions()
        }
    }

    func retrySuggestions() {
        Task { await regenerateSuggestions() }
    }

    private func regenerateSuggestions() async {
        suggestionTask?.cancel()
        let generationID = UUID()
        suggestionGenerationID = generationID
        isGeneratingSuggestions = true
        let history = serviceHistory
        let task = Task {
            await SummaryService.suggestedConversationPrompts(
                transcript: transcript,
                history: history,
                limit: 3
            )
        }
        suggestionTask = task
        let generated = await task.value
        guard suggestionGenerationID == generationID else { return }
        suggestions = generated
        isGeneratingSuggestions = false
        suggestionTask = nil
    }

    private var serviceHistory: [TranscriptConversationMessage] {
        messages.map {
            TranscriptConversationMessage(
                role: $0.role == .user ? .user : .assistant,
                content: $0.content
            )
        }
    }

    private func trackRequest(message: String, source: String) {
        var properties = context.analyticsProperties
        properties["prompt_length"] = message.count
        properties["transcript_length"] = transcript.count
        properties["input_source"] = source
        properties["conversation_turn"] = messages.filter { $0.role == .user }.count

        let event = context.isOnboarding
            ? "Onboarding Demo Ask AI Requested"
            : "Ask/Act Command Executed"
        AnalyticsService.shared.trackEvent(event, properties: properties)
    }

    private func trackCompletion(answer: String, source: String) {
        var properties = context.analyticsProperties
        properties["answer_length"] = answer.count
        properties["result_length"] = answer.count
        properties["has_answer"] = true
        properties["has_result"] = true
        properties["input_source"] = source
        properties["conversation_turn"] = messages.filter { $0.role == .user }.count

        let event = context.isOnboarding
            ? "Onboarding Demo Ask AI Completed"
            : "Ask/Act Command Completed"
        AnalyticsService.shared.trackEvent(event, properties: properties)
    }

    private func trackFailure(source: String, category: String) {
        var properties = context.analyticsProperties
        properties["failure_category"] = category
        properties["input_source"] = source
        properties["conversation_turn"] = messages.filter { $0.role == .user }.count
        AnalyticsService.shared.trackEvent("Ask AI Conversation Failed", properties: properties)
    }
}

private extension AskAIConversationContext {
    var isOnboarding: Bool {
        if case .onboarding = self { return true }
        return false
    }
}
