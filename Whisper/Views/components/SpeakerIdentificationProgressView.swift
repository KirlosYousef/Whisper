//
//  SpeakerIdentificationProgressView.swift
//  Whisper
//

import SwiftUI

struct SpeakerIdentificationProgressView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false
    @State private var phase = 0

    private let messages = [
        "Building the full transcript",
        "Identifying everyone who spoke",
        "Labeling each turn"
    ]

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(Color.primary.opacity(pulse ? 0.16 : 0.06), lineWidth: 1.5)
                        .frame(width: 78 + CGFloat(ring) * 26, height: 78 + CGFloat(ring) * 26)
                        .scaleEffect(pulse ? 1.06 : 0.92)
                        .animation(
                            .easeInOut(duration: 1.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(ring) * 0.18),
                            value: pulse
                        )
                }

                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulse ? 1.04 : 0.96)

                Image(systemName: "person.3.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
            }
            .frame(height: 130)

            VStack(spacing: 8) {
                Text(messages[phase % messages.count])
                    .font(.app(.semibold, size: 20))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id(phase)

                Text("Any number of speakers. You can rename them after.")
                    .font(.app(.regular, size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)

            AnimatedEqualizerBars()
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .onAppear { pulse = true }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    phase = (phase + 1) % messages.count
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Building the full transcript and identifying everyone who spoke")
    }
}

private struct AnimatedEqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<7, id: \.self) { index in
                    let height = 8 + abs(sin(t * 2.6 + Double(index) * 0.55)) * 22
                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 4, height: height)
                }
            }
            .frame(height: 32)
        }
        .accessibilityHidden(true)
    }
}
