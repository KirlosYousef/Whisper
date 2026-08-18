//
//  OnboardingViewModel.swift
//  Whisper
//
//  Created by Kirlos Yousef on 3/12/2025.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Models

struct OnboardingOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?

    init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    init(_ title: String) {
        self.id = title
        self.title = title
        self.subtitle = nil
    }
}

struct OnboardingQuestion {
    let id: String
    let title: String
    let caption: String?
    let isSearchable: Bool
    let options: [OnboardingOption]

    init(
        id: String,
        title: String,
        caption: String? = nil,
        isSearchable: Bool = false,
        options: [OnboardingOption]
    ) {
        self.id = id
        self.title = title
        self.caption = caption
        self.isSearchable = isSearchable
        self.options = options
    }

    init(id: String, title: String, options: [String]) {
        self.init(id: id, title: title, caption: nil, isSearchable: false, options: options.map { OnboardingOption($0) })
    }
}

struct OnboardingResponse {
    var answers: [String: String] = [:]
    var userName: String = ""
}

enum OnboardingStep {
    case introduction
    case questions
    case nameEntry
    case microphone
    case completed
}

// MARK: - ViewModel

final class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .introduction
    @Published var currentQuestionIndex: Int = 0
    @Published var selectedAnswers: [String: String] = [:]
    @Published var userName: String = ""
    @Published var isNameValid: Bool = false
    @Published var isRequestingMicrophonePermission: Bool = false

    private let settingsStore = SettingsStore()
    private lazy var audioService = AudioService()
    private var microphonePermissionResult: String?

    // MARK: - Questions

    let questions: [OnboardingQuestion] = OnboardingViewModel.makeQuestions()

    private static func makeQuestions() -> [OnboardingQuestion] {
        [
            OnboardingQuestion(
                id: "primary_use_case",
                title: "What do you primarily want to use Revera AI for?",
                options: [
                    "Meetings & Interviews",
                    "Personal Notes & Ideas",
                    "Language Learning",
                    "Content Creation",
                    "Other"
                ]
            ),
            OnboardingQuestion(
                id: "recording_frequency",
                title: "How often do you record audio?",
                options: [
                    "Daily",
                    "Weekly",
                    "Occasionally",
                    "First time user"
                ]
            ),
            OnboardingQuestion(
                id: "most_important",
                title: "What's most important to you?",
                options: [
                    "Accuracy",
                    "Speed",
                    "Summaries",
                    "AI Assistance",
                    "All of the above"
                ]
            ),
            OnboardingQuestion(
                id: "use_context",
                title: "What's your primary use case?",
                options: [
                    "Work/Professional",
                    "Personal",
                    "Both"
                ]
            ),
            OnboardingQuestion(
                id: "language_needs",
                title: "What language should we transcribe to?",
                caption: "You can change this later in Settings.",
                isSearchable: true,
                options: languagePreferenceOptions
            ),
            OnboardingQuestion(
                id: "realtime_needs",
                title: "How do you want to transcribe?",
                caption: "You can change this later in Settings.",
                options: transcriptionModeOptions
            )
        ]
    }

    private static var languagePreferenceOptions: [OnboardingOption] {
        var options = [OnboardingOption(id: Languages.autoCode, title: Languages.autoDisplay)]
        options += Languages.supported.map { OnboardingOption(id: $0.code, title: $0.name) }
        return options
    }

    private static var transcriptionModeOptions: [OnboardingOption] {
        [TranscriptionMode.realtimeOpenAI, .segments20s].map {
            OnboardingOption(id: $0.rawValue, title: $0.settingsTitle, subtitle: $0.settingsSubtitle)
        }
    }

    // MARK: - Computed Properties

    var currentQuestion: OnboardingQuestion? {
        guard currentQuestionIndex >= 0 && currentQuestionIndex < questions.count else {
            return nil
        }
        return questions[currentQuestionIndex]
    }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(currentQuestionIndex) / Double(questions.count)
    }

    var progressText: String {
        "Question \(currentQuestionIndex + 1) of \(questions.count)"
    }

    var canProceedToNextQuestion: Bool {
        guard let question = currentQuestion else { return false }
        return selectedAnswers[question.id] != nil
    }

    var canSubmitName: Bool {
        isNameValid
    }

    var isLastQuestion: Bool {
        currentQuestionIndex == questions.count - 1
    }

    // MARK: - Methods

    func selectAnswer(_ answer: String) {
        guard let question = currentQuestion else { return }
        selectedAnswers[question.id] = answer
        persistPreferenceIfNeeded(questionId: question.id, answer: answer)
        AnalyticsService.shared.trackEvent("Onboarding Question Answered", properties: [
            "question_id": question.id,
            "question_title": question.title,
            "answer": answer,
            "question_number": currentQuestionIndex + 1,
            "total_questions": questions.count
        ])
        HapticsManager.shared.selection()
    }

    func nextQuestion() {
        guard canProceedToNextQuestion, !isLastQuestion else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentQuestionIndex += 1
        }
        HapticsManager.shared.impact(.light)
    }

    func goBack() {
        switch currentStep {
        case .questions:
            if currentQuestionIndex == 0 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentStep = .introduction
                }
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentQuestionIndex -= 1
                }
            }
        case .nameEntry:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStep = .questions
            }
        case .microphone:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStep = .nameEntry
            }
        default:
            return
        }
        HapticsManager.shared.impact(.light)
    }

    func updateUserName(_ name: String) {
        userName = name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isNameValid = !trimmedName.isEmpty && trimmedName.count <= 50
    }

    func proceedToQuestions() {
        applyPreferenceDefaults()
        AnalyticsService.shared.trackEvent("Onboarding Started", properties: nil)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = .questions
            currentQuestionIndex = 0
        }
        HapticsManager.shared.impact(.medium)
    }

    func proceedToNameEntry() {
        guard isLastQuestion, canProceedToNextQuestion else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = .nameEntry
        }
        HapticsManager.shared.impact(.medium)
    }

    func proceedToMicrophone() {
        guard canSubmitName else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = .microphone
        }
        HapticsManager.shared.impact(.medium)
    }

    func requestMicrophonePermission(completion: @escaping () -> Void) {
        guard !isRequestingMicrophonePermission else { return }
        isRequestingMicrophonePermission = true
        audioService.requestPermission { [weak self] granted in
            guard let self else { return }
            self.isRequestingMicrophonePermission = false
            self.microphonePermissionResult = granted ? "granted" : "denied"
            AnalyticsService.shared.trackEvent(
                granted ? "Onboarding Microphone Granted" : "Onboarding Microphone Denied",
                properties: nil
            )
            completion()
        }
    }

    func skipMicrophonePermission(completion: @escaping () -> Void) {
        microphonePermissionResult = "skipped"
        AnalyticsService.shared.trackEvent("Onboarding Microphone Skipped", properties: nil)
        completion()
    }

    func completeOnboarding() {
        guard canSubmitName else { return }

        persistSelectedPreferences()

        PaywallManager.shared.loginUser(name: userName)

        AnalyticsService.shared.identify(userId: userName)

        var properties: [String: Any] = [
            "user_name": userName,
            "total_questions": questions.count,
            "default_translation_language": settingsStore.defaultTranslationLanguage,
            "transcription_mode": settingsStore.transcriptionModeRawValue
        ]

        if let microphonePermissionResult {
            properties["microphone_permission"] = microphonePermissionResult
        }

        for (questionId, answer) in selectedAnswers {
            properties["answer_\(questionId)"] = answer
        }

        AnalyticsService.shared.trackEvent("Onboarding Completed", properties: properties)

        settingsStore.hasCompletedOnboarding = true

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = .completed
        }

        HapticsManager.shared.notification(.success)
    }

    func getOnboardingResponse() -> OnboardingResponse {
        OnboardingResponse(answers: selectedAnswers, userName: userName)
    }

    // MARK: - Preferences

    private func applyPreferenceDefaults() {
        if selectedAnswers["language_needs"] == nil {
            let defaultLanguage = Languages.preferredCodes().first ?? "en"
            selectedAnswers["language_needs"] = defaultLanguage
            persistPreferenceIfNeeded(questionId: "language_needs", answer: defaultLanguage)
        }
        if selectedAnswers["realtime_needs"] == nil {
            let defaultMode = TranscriptionMode.segments20s.rawValue
            selectedAnswers["realtime_needs"] = defaultMode
            persistPreferenceIfNeeded(questionId: "realtime_needs", answer: defaultMode)
        }
    }

    private func persistSelectedPreferences() {
        if let code = selectedAnswers["language_needs"] {
            persistPreferenceIfNeeded(questionId: "language_needs", answer: code)
        }
        if let raw = selectedAnswers["realtime_needs"] {
            persistPreferenceIfNeeded(questionId: "realtime_needs", answer: raw)
        }
    }

    private func persistPreferenceIfNeeded(questionId: String, answer: String) {
        switch questionId {
        case "language_needs":
            settingsStore.defaultTranslationLanguage = answer
        case "realtime_needs":
            if let mode = TranscriptionMode(rawValue: answer) {
                settingsStore.transcriptionMode = mode
            }
        default:
            break
        }
    }
}
