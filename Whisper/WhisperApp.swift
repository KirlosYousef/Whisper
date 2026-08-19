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
    @State private var showPaywallView = false
    @State private var selectedTab: Int = 0
    @StateObject private var viewModel: RecordingViewModel
    @StateObject private var settingsStore = SettingsStore()
    @State private var didFinishLaunch = false

    /// Debug-only: skip the blocking paywall so the main app can be tested after onboarding.
    /// Release builds always show the paywall until the user is premium.
    private var bypassForcedPaywall: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private var shouldShowMainApp: Bool {
        settingsStore.hasCompletedOnboarding
    }

    private var shouldShowForcedPaywall: Bool {
        guard !bypassForcedPaywall else { return false }
        guard didFinishLaunch else { return false }
        if !paywallManager.hasResolvedPremiumStatus {
            return !paywallManager.isPremium
        }
        return !paywallManager.isPremium
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
                            AnalyticsService.shared.trackEvent("Premium Activated", properties: nil)
                            HapticsManager.shared.notification(.success)
                        }
                    }
                    
                    if shouldShowForcedPaywall {
                        PayWallView()
                            .onAppear {
                                AnalyticsService.shared.trackEvent("Paywall Shown", properties: [
                                    "source": "main_app"
                                ])
                            }
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
                PaywallManager.shared.setup()
                AnalyticsService.shared.initialize()
                AnalyticsService.shared.trackEvent("App Launched", properties: [
                    "has_completed_onboarding": settingsStore.hasCompletedOnboarding
                ])
                didFinishLaunch = true
            }
        }
        .modelContainer(WhisperApp.sharedModelContainer)
        .environmentObject(paywallManager)
    }
}
