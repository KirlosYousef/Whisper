//
//  SettingsView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 18/11/2025.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @ObservedObject var viewModel: RecordingViewModel
    @StateObject private var store = SettingsStore()
    @State private var showClearAll = false
    @State private var showCleanCacheAlert = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                
                sectionLabel("GENERAL")
                VStack(spacing: 0) {
                    languageMenuRow(
                        title: "Default Translation",
                        current: store.defaultTranslationLanguage
                    ) { newValue in
                        AnalyticsService.shared.trackEvent("Default Translation Language Changed", properties: [
                            "old_language": store.defaultTranslationLanguage,
                            "new_language": newValue
                        ])
                        store.defaultTranslationLanguage = newValue
                        HapticsManager.shared.selection()
                    }
                    Divider().padding(.leading, 64)
                    Button {
                        let newValue = !store.hapticsEnabled
                        AnalyticsService.shared.trackEvent("Haptics Toggled", properties: [
                            "enabled": newValue
                        ])
                        store.hapticsEnabled.toggle()
                        HapticsManager.shared.selection()
                    } label: {
                        SettingsRow(
                            iconName: "iphone.radiowaves.left.and.right",
                            title: "Haptics",
                            trailingView: Toggle("", isOn: $store.hapticsEnabled),
                            hasChevron: false)
                    }
                    .buttonStyle(.plain)
                }
                .card()
                
                sectionLabel("STORAGE MANAGEMENT")
                VStack(spacing: 0) {
                    SettingsRow(
                        iconName: "trash",
                        title: "Clean Cache",
                        subtitle: "Clears temporary files",
                        hasChevron: false
                    ) {
                        showCleanCacheAlert = true
                    }
                    Divider().padding(.leading, 64)
                    SettingsRow(
                        iconName: "trash.slash",
                        title: "Clean All Transcripts",
                        subtitle: "Permanently delete all",
                        hasChevron: false
                    ) {
                        showClearAll = true
                    }
                }
                .card()
                
                sectionLabel("SUPPORT")
                VStack(spacing: 0) {
                    Button {
                        AnalyticsService.shared.trackEvent("Help & FAQ Opened", properties: nil)
                        UIApplication.shared.open(store.helpURL)
                    } label: {
                        SettingsRow(
                            iconName: "questionmark.circle.fill",
                            title: "Help & FAQ",
                            trailingText: nil
                        )
                    }
                    Divider().padding(.leading, 64)
                    Button {
                        AnalyticsService.shared.trackEvent("Support Contacted", properties: nil)
                        if let url = URL(string: "mailto:\(store.supportEmail)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        SettingsRow(
                            iconName: "headphones",
                            title: "Contact Support",
                            trailingText: nil
                        )
                    }
                    Divider().padding(.leading, 64)
                    Button {
                        AnalyticsService.shared.trackEvent("Privacy Policy Viewed", properties: nil)
                        UIApplication.shared.open(store.privacyURL)
                    } label: {
                        SettingsRow(
                            iconName: "lock.shield",
                            title: "Privacy Policy"
                        )
                    }
                }
                .card()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .navigationTitle("Settings")
        .onAppear {
            AnalyticsService.shared.trackEvent("Settings Viewed", properties: [
                "is_premium": PaywallManager.shared.isPremium
            ])
        }
        .alert("Clear Cache?", isPresented: $showCleanCacheAlert) {
            Button("Delete Cache", role: .destructive) {
                AnalyticsService.shared.trackEvent("Clear Cache Initiated", properties: nil)
                viewModel.cleanupProcessedAudioFiles()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears temporary audio files used for processing. Your recordings and transcripts will not be deleted.")
        }
        .alert("Clear All Recordings?", isPresented: $showClearAll) {
            Button("Delete All", role: .destructive) {
                AnalyticsService.shared.trackEvent("Clear All Recordings Initiated", properties: [
                    "recording_count": viewModel.recordings.count
                ])
                viewModel.clearAllRecordings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all recordings and their transcriptions. This action cannot be undone.")
        }
    }
    
    @ViewBuilder
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(AppTheme.primary)
                    )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Premium")
                            .font(.app(.bold, size: 20))
                        
                        Spacer()
                    }
                    Text("Your plan is active")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .card()
    }
    
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(.semibold, size: 13))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
    
    private func languageMenuRow(title: String, current: String, onChange: @escaping (String) -> Void) -> some View {
        Menu {
            Picker(title, selection: Binding(
                get: { current },
                set: { onChange($0) }
            )) {
                Text(Languages.autoDisplay).tag(Languages.autoCode)
                Divider()
                ForEach(Languages.supported) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
        } label: {
            SettingsRow(
                iconName: title.contains("Transcription") ? "mic.fill" : "character.bubble",
                title: title,
                trailingText: Languages.displayName(for: current)
            )
        }
        .buttonStyle(.plain)
    }
    
}


