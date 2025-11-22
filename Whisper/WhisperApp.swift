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
    
    var sharedModelContainer: ModelContainer = {
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

    var body: some Scene {
        WindowGroup {
            let viewModel = RecordingViewModel(modelContext: sharedModelContainer.mainContext)
            ZStack {
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
                
//                if !paywallManager.isPremium {
//                    PayWallView()
//                }
            }
        }
        .modelContainer(sharedModelContainer)
        .environmentObject(paywallManager)
    }
}
