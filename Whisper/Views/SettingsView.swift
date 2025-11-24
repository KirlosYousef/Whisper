import SwiftUI
import SwiftData

struct SettingsView: View {
    @ObservedObject var viewModel: RecordingViewModel
    @StateObject private var store = SettingsStore()
    @State private var showClearAll = false
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
                        store.defaultTranslationLanguage = newValue
                        HapticsManager.shared.selection()
                    }
                    Divider().padding(.leading, 64)
                    Toggle("Haptics", isOn: $store.hapticsEnabled)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                }
                .card()
                
                sectionLabel("STORAGE MANAGEMENT")
                VStack(spacing: 0) {
                    SettingsRow(
                        iconName: "trash",
                        title: "Clean Cache",
                        subtitle: "Clears temporary files",
                        trailingText: nil,
                        isDestructive: false
                    ) {
                        viewModel.cleanupProcessedAudioFiles()
                    }
                    Divider().padding(.leading, 64)
                    SettingsRow(
                        iconName: "trash.slash",
                        title: "Clean All Transcripts",
                        subtitle: "Permanently delete all",
                        trailingText: nil,
                        isDestructive: true
                    ) {
                        showClearAll = true
                    }
                }
                .card()
                
                sectionLabel("SUPPORT")
                VStack(spacing: 0) {
                    Button {
                        UIApplication.shared.open(store.helpURL)
                    } label: {
                        SettingsRow(
                            iconName: "questionmark.circle.fill",
                            title: "Help & FAQ",
                            subtitle: nil,
                            trailingText: nil
                        )
                    }
                    Divider().padding(.leading, 64)
                    Button {
                        if let url = URL(string: "mailto:\(store.supportEmail)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        SettingsRow(
                            iconName: "headphones",
                            title: "Contact Support",
                            subtitle: nil,
                            trailingText: nil
                        )
                    }
                    Divider().padding(.leading, 64)
                    Button {
                        UIApplication.shared.open(store.privacyURL)
                    } label: {
                        SettingsRow(
                            iconName: "lock.shield",
                            title: "Privacy Policy",
                            subtitle: nil,
                            trailingText: nil
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
        .alert("Clear All Recordings?", isPresented: $showClearAll) {
            Button("Delete All", role: .destructive) {
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
                subtitle: nil,
                trailingText: Languages.displayName(for: current)
            )
        }
        .buttonStyle(.plain)
    }
    
}


