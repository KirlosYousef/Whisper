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
    let onBack: () -> Void
    let canProceed: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedOption: String? = nil
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    private var primaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var filteredOptions: [OnboardingOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.isSearchable, !query.isEmpty else {
            return question.options
        }
        return question.options.filter { option in
            option.title.localizedCaseInsensitiveContains(query)
                || option.id.localizedCaseInsensitiveContains(query)
        }
    }

    init(
        question: OnboardingQuestion,
        selectedAnswer: String?,
        progress: Double,
        progressText: String,
        onAnswerSelected: @escaping (String) -> Void,
        onNext: @escaping () -> Void,
        onBack: @escaping () -> Void,
        canProceed: Bool
    ) {
        self.question = question
        self.selectedAnswer = selectedAnswer
        self.progress = progress
        self.progressText = progressText
        self.onAnswerSelected = onAnswerSelected
        self.onNext = onNext
        self.onBack = onBack
        self.canProceed = canProceed
        self._selectedOption = State(initialValue: selectedAnswer)
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: primaryColor))
                    .frame(maxWidth: .infinity)
                    .frame(height: 4)

                Text(progressText)
                    .font(.app(.medium, size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                Text(question.title)
                    .font(.app(.semibold, size: 24))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                if let caption = question.caption {
                    Text(caption)
                        .font(.app(.regular, size: 15))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            if question.isSearchable {
                searchField
                    .padding(.horizontal)
            }

            ScrollView(showsIndicators: true) {
                LazyVStack(spacing: 12) {
                    if filteredOptions.isEmpty {
                        Text("No languages match")
                            .font(.app(.regular, size: 15))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(filteredOptions) { option in
                            OptionButton(
                                title: option.title,
                                subtitle: option.subtitle,
                                isSelected: selectedOption == option.id,
                                primaryColor: primaryColor,
                                colorScheme: colorScheme
                            ) {
                                selectedOption = option.id
                                isSearchFocused = false
                                onAnswerSelected(option.id)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button {
                    isSearchFocused = false
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                                .stroke(AppTheme.cardStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous question")

                Spacer()

                Button {
                    isSearchFocused = false
                    onNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(canProceed ? (colorScheme == .dark ? .black : .white) : .secondary)
                        .frame(width: 56, height: 56)
                        .background(canProceed ? primaryColor : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canProceed)
                .accessibilityLabel("Next question")
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .onChange(of: selectedAnswer) { _, newValue in
            selectedOption = newValue
        }
        .onChange(of: question.id) { _, _ in
            selectedOption = selectedAnswer
            searchText = ""
            isSearchFocused = false
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)

            TextField("Search languages", text: $searchText)
                .font(.app(.regular, size: 17))
                .foregroundColor(.primary)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit {
                    isSearchFocused = false
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        )
        .cornerRadius(AppTheme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .stroke(
                    isSearchFocused ? primaryColor : AppTheme.cardStroke,
                    lineWidth: isSearchFocused ? 2 : 1
                )
        )
    }
}

// MARK: - Option Button

private struct OptionButton: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let primaryColor: Color
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticsManager.shared.selection()
            action()
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.app(.medium, size: 17))
                        .foregroundColor(
                            isSelected
                                ? (colorScheme == .dark ? .black : .white)
                                : .primary
                        )
                        .multilineTextAlignment(.leading)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.app(.regular, size: 15))
                            .foregroundColor(
                                isSelected
                                    ? (colorScheme == .dark ? Color.black.opacity(0.7) : Color.white.opacity(0.8))
                                    : .secondary
                            )
                            .multilineTextAlignment(.leading)
                    }
                }

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
        }
        .buttonStyle(OptionPressStyle())
    }
}

private struct OptionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
