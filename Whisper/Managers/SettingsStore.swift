import Foundation
import SwiftUI

final class SettingsStore: ObservableObject {
    @AppStorage("transcriptionLanguage") var transcriptionLanguage: String = "auto"
    @AppStorage("defaultTranslationLanguage") var defaultTranslationLanguage: String = "en"
    
    let helpURL = URL(string: "https://example.com/help")!
    let privacyURL = URL(string: "https://example.com/privacy")!
    let supportEmail = "support@example.com"
}



