//
//  OnboardingCoordinatorView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 3/12/2025.
//

import SwiftUI

struct OnboardingCoordinatorView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject private var paywallManager: PaywallManager
    @State private var showPaywall = false
    
    var body: some View {
        ZStack {
            // Main onboarding flow
            Group {
                switch viewModel.currentStep {
                case .introduction:
                    IntroductionScreen {
                        viewModel.proceedToQuestions()
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                
                case .questions:
                    if let question = viewModel.currentQuestion {
                        OnboardingQuestionView(
                            question: question,
                            selectedAnswer: viewModel.selectedAnswers[question.id],
                            progress: viewModel.progress,
                            progressText: viewModel.progressText,
                            onAnswerSelected: { answer in
                                viewModel.selectAnswer(answer)
                            },
                            onNext: {
                                if viewModel.isLastQuestion {
                                    viewModel.proceedToNameEntry()
                                } else {
                                    viewModel.nextQuestion()
                                }
                            },
                            canProceed: viewModel.canProceedToNextQuestion
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                    }
                
                case .nameEntry:
                    NameEntryView(
                        userName: $viewModel.userName,
                        isValid: viewModel.canSubmitName,
                        onSubmit: {
                            viewModel.completeOnboarding()
                            // Show paywall after a brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                showPaywall = true
                            }
                        },
                        onUserNameChanged: { name in
                            viewModel.updateUserName(name)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                
                case .completed:
                    // This state is handled by showing paywall
                    Color.clear
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.currentStep)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.currentQuestionIndex)
            
            // Paywall overlay
            if showPaywall {
                PayWallView(displayCloseButton: false)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            HapticsManager.shared.prepare()
        }
    }
}

