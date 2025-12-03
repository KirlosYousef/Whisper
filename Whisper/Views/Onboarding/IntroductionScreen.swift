//
//  IntroductionScreen.swift
//  Whisper
//
//  Created by Kirlos Yousef on 3/12/2025.
//

import SwiftUI

struct IntroductionScreen: View {
    let onContinue: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var visibleFeatures: Set<Int> = []
    
    private var primaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    
    private let features: [(icon: String, title: String, description: String)] = [
        (
            icon: "mic.fill",
            title: "Recording",
            description: "Record audio with high-quality capture"
        ),
        (
            icon: "globe",
            title: "Transcription & Translation",
            description: "Get transcriptions directly in your selected language"
        ),
        (
            icon: "doc.text",
            title: "Summaries",
            description: "Automatic summaries of your recordings"
        ),
        (
            icon: "sparkles",
            title: "Personal AI Assistant",
            description: "Your AI assistant tailored for each transcript"
        )
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // App name
            Text("Revera AI")
                .font(.app(.bold, size: 36))
                .foregroundColor(.primary)
                .padding(.bottom, 48)
            
            // Feature cards
            VStack(spacing: 16) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    FeatureCard(
                        icon: feature.icon,
                        title: feature.title,
                        description: feature.description,
                        primaryColor: primaryColor,
                        colorScheme: colorScheme,
                        isVisible: visibleFeatures.contains(index)
                    )
                    .padding(.horizontal)
                    .opacity(visibleFeatures.contains(index) ? 1 : 0)
                    .offset(y: visibleFeatures.contains(index) ? 0 : 30)
                }
            }
            .padding(.bottom, 48)
            
            Spacer()
            
            // Continue button
            Button(action: {
                HapticsManager.shared.impact(.medium)
                onContinue()
            }) {
                Text("Get Started")
                    .font(.app(.semibold, size: 17))
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(primaryColor)
                    .cornerRadius(AppTheme.cornerRadius)
            }
            .padding(.horizontal)
            .padding(.bottom, 48)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .onAppear {
            animateFeatures()
        }
    }
    
    private func animateFeatures() {
        for index in 0..<features.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    _ = visibleFeatures.insert(index)
                }
            }
        }
    }
}

// MARK: - Feature Card

private struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let primaryColor: Color
    let colorScheme: ColorScheme
    let isVisible: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                    .frame(width: 56, height: 56)
                
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(primaryColor)
            }
            
            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.app(.semibold, size: 18))
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.app(.regular, size: 15))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(
            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        )
        .cornerRadius(AppTheme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

