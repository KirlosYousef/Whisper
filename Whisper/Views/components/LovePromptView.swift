//
//  LovePromptView.swift
//  Whisper
//

import SwiftUI
import StoreKit
import UIKit

struct LovePromptView: View {
    @ObservedObject private var manager = LovePromptManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.requestReview) private var requestReview

    @State private var step: Step = .question
    @State private var appeared = false
    @State private var pulse = false
    @State private var feedback = ""
    @FocusState private var feedbackFocused: Bool

    private enum Step {
        case question
        case thanks
        case feedback
    }

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.46 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if step == .question {
                        manager.dismissWithoutCompleting()
                    }
                }

            card
                .padding(.horizontal, 24)
                .scaleEffect(appeared ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 28)
                .rotation3DEffect(.degrees(appeared ? 0 : 8), axis: (x: 1, y: 0, z: 0))
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                appeared = true
            }
            pulse = true
        }
    }

    private var card: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button {
                    manager.dismissWithoutCompleting()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }

            ZStack {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .stroke(Color.primary.opacity(pulse ? 0.16 : 0.05), lineWidth: 1)
                        .frame(width: 72 + CGFloat(ring) * 22, height: 72 + CGFloat(ring) * 22)
                        .scaleEffect(pulse && step == .question ? 1.1 : 0.96)
                        .opacity(step == .question ? 1 : 0.35)
                        .animation(
                            .easeInOut(duration: 1.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(ring) * 0.22),
                            value: pulse
                        )
                }

                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08))
                    .frame(width: 64, height: 64)
                    .scaleEffect(step == .thanks ? 1.08 : 1)

                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: step == .question)
                    .symbolEffect(.bounce, value: step)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 110)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: step)

            VStack(spacing: 8) {
                Text(title)
                    .font(.app(.bold, size: 22))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)

                Text(subtitle)
                    .font(.app(.regular, size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .animation(.easeInOut(duration: 0.28), value: step)

            if step == .feedback {
                TextField("What’s not working, or what you wish it did…", text: $feedback, axis: .vertical)
                    .font(.app(.regular, size: 16))
                    .lineLimit(3...6)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($feedbackFocused)
                    .submitLabel(.send)
                    .onSubmit(sendFeedback)
            }

            buttons
        }
        .padding(22)
        .background(AppTheme.background(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 28, y: 14)
    }

    @ViewBuilder
    private var buttons: some View {
        switch step {
        case .question:
            VStack(spacing: 10) {
                Button(action: loveApp) {
                    Text("Yes, I like it")
                        .font(.app(.semibold, size: 17))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: showFeedback) {
                    Text("Not really")
                        .font(.app(.medium, size: 16))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        case .thanks:
            EmptyView()
        case .feedback:
            Button(action: sendFeedback) {
                Text("Send feedback")
                    .font(.app(.semibold, size: 17))
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Color.primary.opacity(canSendFeedback ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSendFeedback)
        }
    }

    private var title: String {
        switch step {
        case .question: return "Enjoying Revera?"
        case .thanks: return "Thanks — that means a lot"
        case .feedback: return "How can we do better?"
        }
    }

    private var subtitle: String {
        switch step {
        case .question:
            return "A quick yes or no helps us a lot. If you like it, a rating on the App Store makes a real difference."
        case .thanks:
            return "If Apple shows a rating prompt, a tap there is the nicest way to support the app."
        case .feedback:
            return "Tell us what’s off. We’ll open an email so you can send it directly."
        }
    }

    private var iconName: String {
        switch step {
        case .question: return "heart.fill"
        case .thanks: return "checkmark.circle.fill"
        case .feedback: return "envelope.fill"
        }
    }

    private var canSendFeedback: Bool {
        !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loveApp() {
        HapticsManager.shared.notification(.success)
        AnalyticsService.shared.trackEvent("Love Prompt Liked", properties: [
            "trigger": manager.lastTrigger?.rawValue ?? "unknown"
        ])
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            step = .thanks
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            requestReview()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            manager.dismissCompleted()
        }
    }

    private func showFeedback() {
        HapticsManager.shared.selection()
        AnalyticsService.shared.trackEvent("Love Prompt Disliked", properties: [
            "trigger": manager.lastTrigger?.rawValue ?? "unknown"
        ])
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            step = .feedback
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            feedbackFocused = true
        }
    }

    private func sendFeedback() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        HapticsManager.shared.impact(.medium)
        AnalyticsService.shared.trackEvent("Love Prompt Feedback Sent", properties: [
            "trigger": manager.lastTrigger?.rawValue ?? "unknown",
            "length": text.count
        ])
        openFeedbackEmail(text)
        manager.dismissCompleted()
    }

    private func openFeedbackEmail(_ message: String) {
        let email = SettingsStore().supportEmail
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Revera feedback"),
            URLQueryItem(name: "body", value: message)
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

extension View {
    func lovePromptOnShare() -> some View {
        simultaneousGesture(TapGesture().onEnded {
            LovePromptManager.shared.noteShareOrExport(delay: 2.0)
        })
    }
}
