import SwiftUI
import UIKit

struct AskAIConversationView: View {
    @StateObject private var viewModel: AskAIConversationViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isComposerFocused: Bool
    @State private var question = ""

    init(transcript: String, context: AskAIConversationContext) {
        _viewModel = StateObject(wrappedValue: AskAIConversationViewModel(
            transcript: transcript,
            context: context
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            suggestions
            composer
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .task {
            await viewModel.loadSuggestionsIfNeeded()
        }
    }

    private var header: some View {
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
                Text("Chat with your transcript")
                    .font(.app(.regular, size: 12))
                    .foregroundStyle(.secondary)
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

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.messages.isEmpty && !viewModel.isResponding {
                        emptyState
                    }

                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if viewModel.isResponding {
                        thinkingBubble
                            .id("thinking")
                    }

                    if let error = viewModel.errorMessage {
                        errorBubble(error)
                            .id("error")
                    }
                }
                .padding(20)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: viewModel.isResponding) { _, _ in
                scrollToLatest(proxy)
            }
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
            Text("Ask a question, find an insight, or turn your transcript into something useful.")
                .font(.app(.regular, size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func messageBubble(_ message: AskAIConversationViewModel.Message) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 46)
                Text(message.content)
                    .font(.app(.regular, size: 16))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                    Text("Revera")
                        .font(.app(.semibold, size: 13))
                }
                .foregroundStyle(.secondary)

                Text(message.content)
                    .font(.app(.regular, size: 16))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    Button {
                        UIPasteboard.general.string = message.content
                        HapticsManager.shared.notification(.success)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    ShareLink(item: message.content) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        LovePromptManager.shared.noteShareOrExport(delay: 2)
                    })
                }
                .font(.app(.medium, size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text("Thinking…")
                    .font(.app(.semibold, size: 15))
                Text("Reading your transcript and our conversation")
                    .font(.app(.regular, size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(cardBackground)
    }

    private func errorBubble(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
                .font(.app(.regular, size: 14))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .background(cardBackground)
    }

    @ViewBuilder
    private var suggestions: some View {
        if viewModel.isGeneratingSuggestions || !viewModel.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(viewModel.messages.isEmpty ? "Try asking" : "Continue with")
                        .font(.app(.semibold, size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isGeneratingSuggestions {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                ForEach(Array(viewModel.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    Button {
                        HapticsManager.shared.selection()
                        question = ""
                        isComposerFocused = false
                        viewModel.send(suggestion, source: "ai_suggestion_\(index + 1)")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 20)
                            Text(suggestion)
                                .font(.app(.medium, size: 14))
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .background(cardBackground)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isResponding)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 8)
            .background(AppTheme.background(colorScheme))
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.canSend
    }

    private func submitQuestion() {
        guard canSubmit else { return }
        let submitted = question
        question = ""
        isComposerFocused = false
        HapticsManager.shared.impact(.light)
        viewModel.send(submitted, source: "composer")
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if viewModel.isResponding {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("thinking", anchor: .bottom)
                }
            } else if let last = viewModel.messages.last {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
