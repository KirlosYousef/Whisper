//
//  OnboardingQuestionView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 3/12/2025.
//

import SwiftUI

struct OnboardingQuestionView: View {
    let question: OnboardingQuestion
    let selectedAnswer: String?
    let progress: Double
    let progressText: String
    let onAnswerSelected: (String) -> Void
    let onNext: () -> Void
    let canProceed: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedOption: String? = nil
    
    private var primaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    
    init(
        question: OnboardingQuestion,
        selectedAnswer: String?,
        progress: Double,
        progressText: String,
        onAnswerSelected: @escaping (String) -> Void,
        onNext: @escaping () -> Void,
        canProceed: Bool
    ) {
        self.question = question
        self.selectedAnswer = selectedAnswer
        self.progress = progress
        self.progressText = progressText
        self.onAnswerSelected = onAnswerSelected
        self.onNext = onNext
        self.canProceed = canProceed
        self._selectedOption = State(initialValue: selectedAnswer)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Progress indicator
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: primaryColor))
                    .frame(height: 4)
                
                Text(progressText)
                    .font(.app(.medium, size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Question title
            Text(question.title)
                .font(.app(.semibold, size: 24))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
            
            // Answer options
            VStack(spacing: 12) {
                ForEach(question.options, id: \.self) { option in
                    OptionButton(
                        text: option,
                        isSelected: selectedOption == option,
                        primaryColor: primaryColor,
                        colorScheme: colorScheme
                    ) {
                        selectedOption = option
                        onAnswerSelected(option)
                    }
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Next button
            Button(action: {
                HapticsManager.shared.impact(.medium)
                onNext()
            }) {
                Text("Next")
                    .font(.app(.semibold, size: 17))
                    .foregroundColor(canProceed ? (colorScheme == .dark ? .black : .white) : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        canProceed ? primaryColor : Color.gray.opacity(0.3)
                    )
                    .cornerRadius(AppTheme.cornerRadius)
            }
            .disabled(!canProceed)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .onChange(of: selectedAnswer) { _, newValue in
            selectedOption = newValue
        }
    }
}

// MARK: - Option Button

private struct OptionButton: View {
    let text: String
    let isSelected: Bool
    let primaryColor: Color
    let colorScheme: ColorScheme
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            HapticsManager.shared.selection()
            action()
        }) {
            HStack {
                Text(text)
                    .font(.app(.medium, size: 17))
                    .foregroundColor(
                        isSelected 
                            ? (colorScheme == .dark ? .black : .white)
                            : .primary
                    )
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .font(.system(size: 20))
                }
            }
            .padding()
            .background(
                isSelected ? primaryColor : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            )
            .cornerRadius(AppTheme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(
                        isSelected ? primaryColor : AppTheme.cardStroke,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
    }
}

