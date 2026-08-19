//
//  SpeakerTurnCard.swift
//  Whisper
//

import SwiftUI

struct SpeakerTurnCard<TrailingMenu: View>: View {
    let speakerKey: String
    let displayName: String
    let timeRange: String
    let text: String
    let isActive: Bool
    let isPlaying: Bool
    let isDisabled: Bool
    let showDisabledWarningIcon: Bool
    let onPlayPause: () -> Void
    @ViewBuilder var trailingMenu: () -> TrailingMenu
    @Environment(\.colorScheme) private var colorScheme

    init(
        speakerKey: String,
        displayName: String,
        timeRange: String,
        text: String,
        isActive: Bool,
        isPlaying: Bool,
        isDisabled: Bool,
        showDisabledWarningIcon: Bool = true,
        onPlayPause: @escaping () -> Void,
        @ViewBuilder trailingMenu: @escaping () -> TrailingMenu
    ) {
        self.speakerKey = speakerKey
        self.displayName = displayName
        self.timeRange = timeRange
        self.text = text
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.isDisabled = isDisabled
        self.showDisabledWarningIcon = showDisabledWarningIcon
        self.onPlayPause = onPlayPause
        self.trailingMenu = trailingMenu
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: {
                HapticsManager.shared.selection()
                onPlayPause()
            }) {
                RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                    .fill(isActive ? Color(.label) : Color(.label).opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: iconName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(iconColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1.0)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(SpeakerStyle.color(for: speakerKey))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text(SpeakerStyle.initial(for: displayName))
                                .font(.app(.semibold, size: 11))
                                .foregroundColor(.white)
                        )
                    Text(displayName)
                        .font(.app(.medium, size: 15))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                    Text(timeRange)
                        .font(.app(.medium, size: 13))
                        .foregroundColor(.secondary)
                }
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            trailingMenu()
        }
        .padding(12)
        .background(isActive
                    ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .stroke(isActive
                        ? (colorScheme == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.15))
                        : AppTheme.cardStroke,
                        lineWidth: 1)
        )
        .background(.clear)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private var iconName: String {
        if isDisabled && showDisabledWarningIcon {
            return "exclamationmark.triangle.fill"
        }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private var iconColor: Color {
        if isDisabled && showDisabledWarningIcon {
            return .orange
        }
        return isActive ? Color(.systemBackground) : .black
    }
}

private struct SpeakerTurnAppearModifier: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                let delay = Double(min(index, 12)) * 0.065
                withAnimation(.spring(response: 0.52, dampingFraction: 0.84).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func speakerTurnAppear(index: Int) -> some View {
        modifier(SpeakerTurnAppearModifier(index: index))
    }
}
