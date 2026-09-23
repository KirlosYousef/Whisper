import SwiftUI

struct SessionStatusView: View {
    enum Kind: Equatable {
        case preparing
        case finishing
    }

    enum Style {
        case expanded
        case compact
    }

    let kind: Kind
    var style: Style = .expanded

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var messageIndex = 0

    var body: some View {
        Group {
            switch style {
            case .expanded:
                expandedLayout
            case .compact:
                compactLayout
            }
        }
        .onAppear { pulse = true }
        .task { await cycleMessages() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentMessage.title)
        .accessibilityValue(currentMessage.subtitle)
    }

    private var expandedLayout: some View {
        VStack(spacing: 22) {
            statusOrb(ringBase: 78, ringStep: 26, core: 72, iconSize: 26)
                .frame(height: 148)

            VStack(spacing: 8) {
                Text(currentMessage.title)
                    .font(.app(.semibold, size: 22))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id(messageIndex)

                Text(currentMessage.subtitle)
                    .font(.app(.regular, size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id("subtitle-\(messageIndex)")
            }
            .padding(.horizontal, 8)

            AudioActivityBars()
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(cardBackground)
    }

    private var compactLayout: some View {
        HStack(spacing: 14) {
            statusOrb(ringBase: 36, ringStep: 0, core: 44, iconSize: 16)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(currentMessage.title)
                    .font(.app(.semibold, size: 16))
                    .contentTransition(.opacity)
                    .id(messageIndex)
                Text(currentMessage.subtitle)
                    .font(.app(.regular, size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .id("subtitle-\(messageIndex)")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func statusOrb(ringBase: CGFloat, ringStep: CGFloat, core: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            if ringStep > 0 {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(Color.primary.opacity(pulse ? 0.16 : 0.06), lineWidth: 1.5)
                        .frame(width: ringBase + CGFloat(ring) * ringStep, height: ringBase + CGFloat(ring) * ringStep)
                        .scaleEffect(pulse ? 1.06 : 0.92)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 1.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(ring) * 0.18),
                            value: pulse
                        )
                }
            }

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                let angle = reduceMotion
                    ? 0.0
                    : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360

                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 3)
                        .frame(width: core + 14, height: core + 14)

                    Circle()
                        .trim(from: 0, to: reduceMotion ? 1 : 0.18)
                        .stroke(
                            Color.primary.opacity(0.75),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: core + 14, height: core + 14)
                        .rotationEffect(.degrees(angle))
                }
            }

            Circle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                .frame(width: core, height: core)
                .scaleEffect(pulse ? 1.04 : 0.96)

            Image(systemName: kind == .preparing ? "waveform" : "sparkles")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.primary)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
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

    private var currentMessage: (title: String, subtitle: String) {
        let items = messages
        return items[messageIndex % items.count]
    }

    private var messages: [(title: String, subtitle: String)] {
        switch kind {
        case .preparing:
            return [
                ("Getting ready to listen", "Live transcription is warming up first"),
                ("Connecting live captions", "Speak after the recording cue — not before"),
                ("Almost ready", "You’ll feel a tap the moment it’s time to talk")
            ]
        case .finishing:
            return [
                ("Catching your last words", "Holding for the final live updates"),
                ("Polishing the transcript", "Making sure nothing important is missed"),
                ("Putting it together", "Your recording is becoming something useful")
            ]
        }
    }

    private func cycleMessages() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.32)) {
                messageIndex = (messageIndex + 1) % messages.count
            }
        }
    }
}

struct AudioActivityBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0.7 : timeline.date.timeIntervalSinceReferenceDate
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
