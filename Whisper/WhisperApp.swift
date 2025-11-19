//
//  WhisperApp.swift
//  Whisper
//
//  Created by Kirlos Yousef on 06/07/2025.
//

import SwiftUI
import SwiftData

@main
struct WhisperApp: App {
    @StateObject private var paywallManager = PaywallManager.shared
    @State private var showPaywallView = false
    
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
            ZStack {
                let viewModel = RecordingViewModel(modelContext: sharedModelContainer.mainContext)
                RecordingView(viewModel: viewModel)
                
                if !paywallManager.isPremium {
                    PayWallView()
                }
            }
        }
        .modelContainer(sharedModelContainer)
        .environmentObject(paywallManager)
    }
}
