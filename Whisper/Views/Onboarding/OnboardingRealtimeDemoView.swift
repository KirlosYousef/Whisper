import SwiftUI

struct OnboardingRealtimeDemoView: View {
    @StateObject private var viewModel: OnboardingDemoViewModel
    let onBack: () -> Void
    let onFinish: (OnboardingDemoOutcome) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSuccessCTA = false
    @State private var showAskAI = false

    init(
        userName: String,
        languageCode: String,
        translationLanguageCode: String,
        onBack: @escaping () -> Void,
        onFinish: @escaping (OnboardingDemoOutcome) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: OnboardingDemoViewModel(
            userName: userName,
            languageCode: languageCode,
            translationLanguageCode: translationLanguageCode
        ))
        self.onBack = onBack
        self.onFinish = onFinish
    }

    private var primaryColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(spacing: 18) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }

            bottomActions
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
                .background(
                    AppTheme.background(colorScheme)
                        .ignoresSafeArea(edges: .bottom)
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)
                }
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .sheet(isPresented: $showAskAI) {
            OnboardingAskAIView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            HapticsManager.shared.prepare()
        }
        .onChange(of: viewModel.phase) { _, phase in
            guard phase == .success else {
                showSuccessCTA = false
                return
            }
            if reduceMotion {
                showSuccessCTA = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    guard viewModel.phase == .success else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSuccessCTA = true
                    }
                }
            }
        }
        .onDisappear {
            viewModel.abandon()
        }
    }

    private var topBar: some View {
        HStack {
            if viewModel.phase == .ready {
                Button {
                    HapticsManager.shared.impact(.light)
                    viewModel.abandon()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer()

            if canSkip {
                Button("Skip") {
                    HapticsManager.shared.impact(.light)
                    viewModel.trackSkip()
                    onFinish(.skipped)
                }
                .font(.app(.medium, size: 15))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .introduction, .ready, .requestingPermission:
            readyContent
        case .connecting, .recording, .finishing:
            recordingContent
        case .success:
            successContent
        case .shortTranscript, .failure:
            failureContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 18) {
            introHeader
            promptCard

            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                Text("Private preview · Not saved")
            }
            .font(.app(.medium, size: 13))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    private var introHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Say something worth remembering")
                .font(.app(.bold, size: 29))
                .multilineTextAlignment(.center)
            Text("Introduce yourself and share one thing you want Revera to remember.")
                .font(.app(.regular, size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Try saying", systemImage: "quote.opening")
                .font(.app(.semibold, size: 13))
                .foregroundStyle(.secondary)
            Text(viewModel.examplePrompt)
                .font(.app(.medium, size: 19))
                .lineSpacing(5)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    private var recordingContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text(recordingTitle)
                    .font(.app(.bold, size: 25))
                Text(recordingSubtitle)
                    .font(.app(.regular, size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Keep the prompt visible so the user never feels stuck while speaking.
            promptCard

            LiveTranscriptView(
                words: viewModel.words,
                isConnected: viewModel.isRealtimeConnected,
                isRecording: viewModel.phase != .finishing,
                reportsBottomPosition: false
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private var successContent: some View {
        VStack(spacing: 16) {
            SuccessCelebration(reduceMotion: reduceMotion)

            VStack(spacing: 6) {
                Text("Your voice, captured")
                    .font(.app(.bold, size: 28))
                Text("This is how every Revera recording becomes something useful.")
                    .font(.app(.regular, size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            LiveTranscriptView(
                words: viewModel.words,
                isConnected: false,
                isRecording: false,
                reportsBottomPosition: false
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))

            resultActions

            Text("Your demo recording is not saved.")
                .font(.app(.medium, size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var resultActions: some View {
        VStack(spacing: 10) {
            Button {
                viewModel.generateSummary()
            } label: {
                resultActionLabel(
                    title: "Summarize",
                    subtitle: "Turn this transcript into key points",
                    icon: "text.badge.star",
                    isLoading: viewModel.isGeneratingSummary
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isGeneratingSummary)

            if !viewModel.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Summary")
                        .font(.app(.semibold, size: 14))
                    Text(viewModel.summary)
                        .font(.app(.regular, size: 15))
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.summaryTodos, id: \.self) { todo in
                        Label(todo, systemImage: "checkmark.circle")
                            .font(.app(.regular, size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                showAskAI = true
            } label: {
                resultActionLabel(
                    title: "Ask AI",
                    subtitle: "Ask a question or take action",
                    icon: "questionmark.bubble",
                    isLoading: false
                )
            }
            .buttonStyle(.plain)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: viewModel.summary)
    }

    private func resultActionLabel(title: String, subtitle: String, icon: String, isLoading: Bool) -> some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .frame(width: 26)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(.semibold, size: 16))
                Text(subtitle)
                    .font(.app(.regular, size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .contentShape(Rectangle())
    }

    private var failureContent: some View {
        VStack(spacing: 22) {
            Image(systemName: viewModel.phase == .shortTranscript ? "waveform.badge.magnifyingglass" : "mic.slash")
                .font(.system(size: 42, weight: .semibold))
                .frame(width: 84, height: 84)
                .background(Color.primary.opacity(0.07), in: Circle())

            VStack(spacing: 10) {
                Text(viewModel.phase == .shortTranscript ? "Almost there" : "Let’s try that again")
                    .font(.app(.bold, size: 28))
                Text(viewModel.failureMessage)
                    .font(.app(.regular, size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !viewModel.words.isEmpty {
                LiveTranscriptView(
                    words: viewModel.words,
                    isConnected: false,
                    isRecording: false,
                    reportsBottomPosition: false
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    @ViewBuilder
    private var bottomActions: some View {
        switch viewModel.phase {
        case .introduction, .ready:
            VStack(spacing: 6) {
                MicButton(isRecording: false, audioLevel: 0) {
                    if viewModel.isMicrophoneReady {
                        viewModel.startRecording()
                    } else {
                        viewModel.tryDemo()
                    }
                }
                Text(viewModel.isMicrophoneReady ? "Tap to start recording" : "Tap the microphone when you’re ready")
                    .font(.app(.medium, size: 13))
                    .foregroundStyle(.secondary)
            }
        case .requestingPermission:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Allow microphone access to continue")
                    .font(.app(.medium, size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 112)
        case .connecting:
            ProgressView("Preparing realtime…")
                .frame(height: 112)
        case .recording:
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: viewModel.progress)
                        .stroke(primaryColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    MicButton(isRecording: true, audioLevel: viewModel.audioLevel) {
                        viewModel.stopManually()
                    }
                    .opacity(viewModel.canStopManually ? 1 : 0.72)
                    .disabled(!viewModel.canStopManually)
                }
                .frame(width: 116, height: 116)
                .accessibilityValue("\(Int((1 - viewModel.progress) * viewModel.maximumDuration)) seconds remaining")
                Text(viewModel.canStopManually ? "Tap to finish" : "Keep speaking…")
                    .font(.app(.medium, size: 13))
                    .foregroundStyle(.secondary)
            }
        case .finishing:
            ProgressView("Finishing your transcript…")
                .frame(height: 112)
        case .success:
            primaryButton("Continue", icon: "arrow.right") {
                HapticsManager.shared.impact(.medium)
                viewModel.trackContinue(outcome: .success)
                onFinish(.success)
            }
            .opacity(showSuccessCTA ? 1 : 0)
            .offset(y: showSuccessCTA ? 0 : 10)
            .disabled(!showSuccessCTA)
        case .shortTranscript, .failure:
            VStack(spacing: 8) {
                if viewModel.failureOutcome != .permissionDenied {
                    primaryButton("Try again", icon: "arrow.clockwise") {
                        HapticsManager.shared.impact(.medium)
                        viewModel.retry()
                    }
                }
                Button("Continue without demo") {
                    HapticsManager.shared.impact(.light)
                    viewModel.trackContinue(outcome: viewModel.failureOutcome)
                    onFinish(viewModel.failureOutcome)
                }
                .font(.app(.medium, size: 16))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }

    private var recordingTitle: String {
        switch viewModel.phase {
        case .connecting: "Getting ready…"
        case .finishing: "Making it useful…"
        default: viewModel.isRealtimeConnected ? "I’m listening" : "Getting ready…"
        }
    }

    private var recordingSubtitle: String {
        if viewModel.phase == .finishing {
            return "Finishing your realtime transcript"
        }
        return viewModel.isRealtimeConnected
            ? "Speak naturally — your words will appear below"
            : "Connecting to realtime transcription…"
    }

    private var canSkip: Bool {
        switch viewModel.phase {
        case .introduction, .requestingPermission, .ready: true
        default: false
        }
    }

    private func primaryButton(_ title: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let icon { Image(systemName: icon) }
            }
            .font(.app(.semibold, size: 17))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(primaryColor, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingAskAIView: View {
    @ObservedObject var viewModel: OnboardingDemoViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isComposerFocused: Bool
    @State private var question = ""

    private let suggestions = [
        "What should I remember?",
        "What is the next action?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            askHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if viewModel.isAskingAI {
                        thinkingState
                    } else if !viewModel.askAIAnswer.isEmpty {
                        answerCard
                    } else {
                        emptyState
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }

            suggestionsSection
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(AppTheme.background(colorScheme))

            composer
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
    }

    private var askHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 42, height: 42)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Ask AI")
                    .font(.app(.bold, size: 20))
                Text("Ask questions or take action on this transcript")
                    .font(.app(.regular, size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .font(.app(.semibold, size: 15))
            .foregroundStyle(.primary)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(AppTheme.background(colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 82, height: 82)
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 30, weight: .medium))
            }
            Text("What would you like to know?")
                .font(.app(.semibold, size: 20))
            Text("Revera can answer questions and find the next action from your transcript.")
                .font(.app(.regular, size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var thinkingState: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text("Thinking…")
                    .font(.app(.semibold, size: 16))
                Text("Reading your transcript")
                    .font(.app(.regular, size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(actionCardBackground)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Answer")
                    .font(.app(.semibold, size: 14))
            }
            Text(viewModel.askAIAnswer)
                .font(.app(.regular, size: 17))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(actionCardBackground)
        .accessibilityElement(children: .combine)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking")
                .font(.app(.semibold, size: 13))
                .foregroundStyle(.secondary)

            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    viewModel.askAI(
                        question: suggestion,
                        source: index == 0 ? "shortcut_remember" : "shortcut_next_action"
                    )
                    question = ""
                    isComposerFocused = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: index == 0 ? "bookmark" : "checklist")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 24)
                        Text(suggestion)
                            .font(.app(.medium, size: 15))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(actionCardBackground)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isAskingAI)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask anything…", text: $question, axis: .vertical)
                .font(.app(.regular, size: 16))
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit { submitQuestion() }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                )

            Button {
                submitQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .frame(width: 44, height: 44)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.32)
            .accessibilityLabel("Ask AI")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(AppTheme.background(colorScheme).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var actionCardBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isAskingAI
    }

    private func submitQuestion() {
        guard canSubmit else { return }
        let submittedQuestion = question
        question = ""
        viewModel.askAI(question: submittedQuestion, source: "composer")
        isComposerFocused = false
    }
}

private struct SuccessCelebration: View {
    let reduceMotion: Bool
    @State private var animate = false

    private let sparkles: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (-46, -22, 12), (46, -26, 10), (-40, 30, 9), (44, 28, 13)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(sparkles.enumerated()), id: \.offset) { index, sparkle in
                Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                    .font(.system(size: sparkle.size, weight: .bold))
                    .offset(x: animate || reduceMotion ? sparkle.x : 0, y: animate || reduceMotion ? sparkle.y : 0)
                    .opacity(animate || reduceMotion ? 0.7 : 0)
                    .scaleEffect(animate || reduceMotion ? 1 : 0.2)
            }

            Circle()
                .fill(Color.green.opacity(0.14))
                .frame(width: 76, height: 76)
                .scaleEffect(animate || reduceMotion ? 1 : 0.5)
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: animate)
        }
        .frame(height: 102)
        .onAppear {
            if reduceMotion {
                animate = true
            } else {
                withAnimation(.spring(response: 0.62, dampingFraction: 0.7)) {
                    animate = true
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcription complete")
    }
}
