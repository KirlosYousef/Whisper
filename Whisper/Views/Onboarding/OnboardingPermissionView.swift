//
//  OnboardingPermissionView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 18/08/2026.
//

import SwiftUI

struct OnboardingPermissionView: View {
    let isRequesting: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var primaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    var body: some View {
        VStack(spacing: 32) {
            HStack {
                Button(action: {
                    HapticsManager.shared.impact(.light)
                    onBack()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)

                Spacer()
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                        .frame(width: 56, height: 56)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(primaryColor)
                }

                VStack(spacing: 12) {
                    Text("Enable your microphone")
                        .font(.app(.semibold, size: 28))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)

                    Text("Revera AI needs the mic to record and transcribe.")
                        .font(.app(.regular, size: 16))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 16) {
                Button(action: {
                    guard !isRequesting else { return }
                    HapticsManager.shared.impact(.medium)
                    onAllow()
                }) {
                    Text(isRequesting ? "Requesting…" : "Allow Microphone")
                        .font(.app(.semibold, size: 17))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(primaryColor)
                        .cornerRadius(AppTheme.cornerRadius)
                }
                .disabled(isRequesting)

                Button(action: {
                    guard !isRequesting else { return }
                    HapticsManager.shared.impact(.light)
                    onSkip()
                }) {
                    Text("Not now")
                        .font(.app(.medium, size: 17))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(isRequesting)
            }
            .padding(.horizontal)
            .padding(.bottom, 48)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
    }
}
