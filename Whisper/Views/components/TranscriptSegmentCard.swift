//
//  TranscriptSegmentCard.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct TranscriptSegmentCard<TrailingMenu: View>: View {
    let isActive: Bool
    let timeRange: String
    let text: String
    let isPlaying: Bool
    let isDisabled: Bool
    let showDisabledWarningIcon: Bool
    let onPlayPause: () -> Void
    @ViewBuilder var trailingMenu: () -> TrailingMenu
    @Environment(\.colorScheme) private var colorScheme

    init(
        isActive: Bool,
        timeRange: String,
        text: String,
        isPlaying: Bool,
        isDisabled: Bool,
        showDisabledWarningIcon: Bool = true,
        onPlayPause: @escaping () -> Void,
        @ViewBuilder trailingMenu: @escaping () -> TrailingMenu
    ) {
        self.isActive = isActive
        self.timeRange = timeRange
        self.text = text
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
                    .fill(isActive
                          ? (Color(.label))
                          : (Color(.label).opacity(0.15)))
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
                Text(timeRange)
                    .font(.app(.medium, size: 14))
                    .foregroundColor(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            
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


