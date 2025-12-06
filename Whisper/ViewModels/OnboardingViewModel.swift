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

struct OnboardingQuestion {
    let id: String
    let title: String
    let options: [String]
}

struct OnboardingResponse {
    var answers: [String: String] = [:]
    var userName: String = ""
}

enum OnboardingStep {
    case introduction
    case questions
    case nameEntry
    case completed
}

// MARK: - ViewModel

final class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .introduction
    @Published var currentQuestionIndex: Int = 0
    @Published var selectedAnswers: [String: String] = [:]
    @Published var userName: String = ""
    @Published var isNameValid: Bool = false
    
    private let settingsStore = SettingsStore()
    
    // MARK: - Questions
    
    let questions: [OnboardingQuestion] = [
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
            id: "language_needs",
            title: "What languages do you work with?",
            options: [
                "English only",
                "Multiple languages",
                "Need translation features",
                "Both native and translation"
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
            id: "realtime_needs",
            title: "Do you need real-time transcription?",
            options: [
                "Yes, always",
                "Sometimes",
                "No, post-processing is fine"
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
        )
    ]
    
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
        HapticsManager.shared.selection()
    }
    
    func nextQuestion() {
        guard canProceedToNextQuestion, !isLastQuestion else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentQuestionIndex += 1
        }
        HapticsManager.shared.impact(.light)
    }
    
    func updateUserName(_ name: String) {
        userName = name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isNameValid = !trimmedName.isEmpty && trimmedName.count <= 50
    }
    
    func proceedToQuestions() {
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
    
    func completeOnboarding() {
        guard canSubmitName else { return }
        
        // Save user name to PaywallManager
        PaywallManager.shared.loginUser(name: userName)
        
        AnalyticsService.shared.identify(userId: userName)
        AnalyticsService.shared.trackEvent("Onboarding finished")
        
        // Mark onboarding as completed
        settingsStore.hasCompletedOnboarding = true
        
        // Move to completed state
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = .completed
        }
        
        HapticsManager.shared.notification(.success)
    }
    
    func getOnboardingResponse() -> OnboardingResponse {
        OnboardingResponse(answers: selectedAnswers, userName: userName)
    }
}

