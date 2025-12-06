//
//  AnalyticsService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 6/12/2025.
//

import Foundation
import Mixpanel

final class AnalyticsService {
    static let shared = AnalyticsService()
    
    private init() {}
    
    /// Call this once on app launch
    func initialize() {
        // Load Mixpanel token from Config.plist
        guard let token = loadMixpanelToken() else {
            assertionFailure("Mixpanel project token is missing. Please add MixpanelProjectToken to Config.plist")
            return
        }
        
        Mixpanel.initialize(token: token, trackAutomaticEvents: false)
        Mixpanel.mainInstance().serverURL = "https://api-eu.mixpanel.com"
    }
    
    private func loadMixpanelToken() -> String? {
        // Load from Config.plist bundled with the app
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let config = NSDictionary(contentsOfFile: path),
           let token = config["MixpanelProjectToken"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }
    
    /// Track a discrete event
    func trackEvent(_ name: String, properties: [String: MixpanelType]? = nil) {
        Mixpanel.mainInstance().track(event: name, properties: properties)
    }
    
    /// Identify the user (e.g., after login)
    func identify(userId: String) {
        Mixpanel.mainInstance().identify(distinctId: userId)
    }
    
    /// Reset on logout to prevent data bleeding between users
    func reset() {
        Mixpanel.mainInstance().reset()
    }
}
