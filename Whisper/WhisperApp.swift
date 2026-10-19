//
//  WhisperApp.swift
//  Whisper
//
//  Created by Kirlos Yousef on 06/07/2025.
//

import SwiftUI
import SwiftData
import RevenueCatUI

@main
struct WhisperApp: App {
    @StateObject private var paywallManager = PaywallManager.shared
    @ObservedObject private var usageAccess = UsageAccessManager.shared
    @ObservedObject private var paywallCoordinator = PaywallCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPaywallView = false
    @State private var selectedTab: Int = 0
    @StateObject private var viewModel: RecordingViewModel
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var lovePromptManager = LovePromptManager.shared
    @State private var didFinishLaunch = false

    /// Debug-only escape hatch for UI work: launch with `-bypassPaywall` to skip the paywall.
    /// Every other build, including Debug runs from Xcode, blocks the main app until the user is subscribed.
    private var bypassForcedPaywall: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-bypassPaywall")
        #else
        false
        #endif
    }

    private var shouldShowMainApp: Bool {
        settingsStore.hasCompletedOnboarding
    }

    private var accessGate: AccessGate {
        AccessGate.forState(usageAccess.accessState)
    }

    /// Without a trial or subscription the app is hard-gated. Used-up trial minutes get a closable offer instead,
    /// so existing transcripts stay readable.
    private var shouldShowForcedPaywall: Bool {
        guard !bypassForcedPaywall else { return false }
        guard didFinishLaunch else { return false }
        return accessGate == .subscribe
    }

    private var isRecordingBusy: Bool {
        viewModel.isRecording || viewModel.isStartingRecording || viewModel.isFinishingRealtime
    }

    /// Runs on every access change: shows or hides the offers, and resumes saved audio once transcription is allowed.
    /// On the first call `old == state`.
    private func handleAccessChange(from old: AccessState, to state: AccessState) {
        guard shouldShowMainApp, !bypassForcedPaywall else { return }
        let isFirstCall = old == state
        switch AccessGate.forState(state) {
        case .upgrade:
            // Never cover a recording in progress; the offer appears when it stops.
            let becameExhausted = isFirstCall || AccessGate.forState(old) != .upgrade
            if becameExhausted, !isRecordingBusy, paywallCoordinator.sheet == nil {
                paywallCoordinator.present(.upgrade)
            }
        case .subscribe:
            paywallCoordinator.dismiss()
        case .open:
            if paywallCoordinator.sheet != nil, !usageAccess.isConfirmingPurchase {
                paywallCoordinator.dismiss()
            }
        }
        if state.canTranscribe, isFirstCall || !old.canTranscribe {
            Task {
                await viewModel.retryUsageLockedTranscriptionsWhenAccessIsAvailable(refreshFirst: false)
                viewModel.processPendingSpeakerIdentifications()
            }
        }
    }

    private var paywallSource: PaywallSource {
        PaywallSource(rawValue: settingsStore.pendingPaywallSource) ?? .mainApp
    }
    
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Recording.self,
            TranscriptionSegment.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        _viewModel = StateObject(wrappedValue: RecordingViewModel(modelContext: WhisperApp.sharedModelContainer.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if shouldShowMainApp {
                    // Main app
                    TabView(selection: $selectedTab) {
                        NavigationStack {
                            TranscriptsListView(viewModel: viewModel, tabSelection: $selectedTab)
                        }
                        .tabItem {
                            Image(systemName: "text.justify.left")
                            Text("Transcripts")
                        }
                        .tag(0)
                        
                        NavigationStack {
                            RecordScreen(viewModel: viewModel)
                        }
                        .tabItem {
                            Image(systemName: "mic.fill")
                            Text("Record")
                        }
                        .tag(1)
                        
                        NavigationStack {
                            SettingsView(viewModel: viewModel)
                        }
                        .tabItem {
                            Image(systemName: "gearshape")
                            Text("Settings")
                        }
                        .tag(2)
                    }
                    .tint(.primary)
                    .onAppear {
                        viewModel.syncSessionDefaultsFromSettings()
                        HapticsManager.shared.prepare()
                    }
                    .onChange(of: selectedTab) { oldValue, newValue in
                        let tabNames = ["Transcripts", "Record", "Settings"]
                        if newValue < tabNames.count {
                            AnalyticsService.shared.trackEvent("Tab Switched", properties: [
                                "from_tab": oldValue < tabNames.count ? tabNames[oldValue] : "unknown",
                                "to_tab": tabNames[newValue]
                            ])
                        }
                    }
                    .onChange(of: paywallManager.isPremium) { _, isPremium in
                        if isPremium {
                            HapticsManager.shared.notification(.success)
                        }
                    }
                    .onChange(of: usageAccess.accessState, initial: true) { old, state in
                        handleAccessChange(from: old, to: state)
                    }
                    .onChange(of: isRecordingBusy) { _, busy in
                        if !busy, accessGate == .upgrade, paywallCoordinator.sheet == nil {
                            paywallCoordinator.present(.upgrade)
                        }
                    }
                    .sheet(item: $paywallCoordinator.sheet, onDismiss: {
                        Task { await usageAccess.refresh() }
                    }) { sheet in
                        switch sheet {
                        case .upgrade:
                            UpgradePaywallSheet()
                        }
                    }
                    
                    if shouldShowForcedPaywall {
                        PayWallView(
                            displayCloseButton: false,
                            source: paywallSource,
                            demoOutcome: settingsStore.onboardingDemoOutcome,
                            onImpressionTracked: {
                                settingsStore.pendingPaywallSource = ""
                            }
                        )
                    }

                    if lovePromptManager.isPresented
                        && !viewModel.isRecording
                        && !viewModel.isStartingRecording
                        && !viewModel.isFinishingRealtime
                        && viewModel.identifyingSpeakerRecordingIds.isEmpty
                        && !shouldShowForcedPaywall
                        && paywallCoordinator.sheet == nil {
                        LovePromptView()
                            .zIndex(20)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                } else {
                    // Onboarding flow
                    OnboardingCoordinatorView()
                        .environmentObject(paywallManager)
                        .onAppear {
                            HapticsManager.shared.prepare()
                        }
                }
            }
            .onAppear {
                AnalyticsService.shared.initialize()
                _ = OnboardingExperimentManager.shared.assignIfNeeded(
                    hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
                )
                OnboardingExperimentManager.shared.registerWithAnalyticsIfAssigned()
                PaywallManager.shared.setup()
                AnalyticsService.shared.trackEvent("App Launched", properties: [
                    "has_completed_onboarding": settingsStore.hasCompletedOnboarding
                ])
                didFinishLaunch = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The trial may have renewed into Unlimited, or a purchase finished, while the app was away.
            guard phase == .active, didFinishLaunch else { return }
            Task {
                _ = await paywallManager.isPremiumMember()
                await usageAccess.refresh()
            }
        }
        .modelContainer(WhisperApp.sharedModelContainer)
        .environmentObject(paywallManager)
    }
}
