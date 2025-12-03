//
//  SettingsStore.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import Foundation
import SwiftUI

final class SettingsStore: ObservableObject {
    @AppStorage("transcriptionLanguage") var transcriptionLanguage: String = "auto"
    @AppStorage("defaultTranslationLanguage") var defaultTranslationLanguage: String = "en"
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    
    let helpURL = URL(string: "https://www.revera.kirlosyousef.com/contact")!
    let privacyURL = URL(string: "https://www.revera.kirlosyousef.com/privacy")!
    let supportEmail = "hello@kirlosyousef.com"
}



