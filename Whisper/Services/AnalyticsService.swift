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
    private static let analyticsUserIdKey = "analyticsUserId"

    private init() {}

    /// Call this once on app launch
    func initialize() {
        guard let token = loadMixpanelToken() else {
            assertionFailure("Mixpanel project token is missing. Please add MixpanelProjectToken to Config.plist")
            return
        }

        Mixpanel.initialize(token: token, trackAutomaticEvents: false)
        #if DEBUG
        Mixpanel.mainInstance().loggingEnabled = true
        #else
        Mixpanel.mainInstance().loggingEnabled = false
        #endif
        Mixpanel.mainInstance().serverURL = "https://api-eu.mixpanel.com"
        registerSuperProperties([
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ])
        identifyCurrentUser()
    }

    func registerSuperProperties(_ properties: [String: Any]) {
        let converted = properties.compactMapValues(Self.mixpanelValue)
        guard !converted.isEmpty else { return }
        Mixpanel.mainInstance().registerSuperProperties(converted)
    }

    private func loadMixpanelToken() -> String? {
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let config = NSDictionary(contentsOfFile: path),
           let token = config["MixpanelProjectToken"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    /// Track a discrete event
    /// Properties can contain String, Int, Double, Bool, or arrays of these types
    func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        let mixpanelProperties = properties?.compactMapValues(Self.mixpanelValue)
        Mixpanel.mainInstance().track(event: name, properties: mixpanelProperties)
    }

    private static func mixpanelValue(_ value: Any) -> MixpanelType? {
        if let string = value as? String { return string }
        if let int = value as? Int { return int }
        if let double = value as? Double { return double }
        if let bool = value as? Bool { return bool }
        if let date = value as? Date { return date }
        if let url = value as? URL { return url }
        if let array = value as? [String] { return array }
        if let array = value as? [Int] { return array }
        if let array = value as? [Double] { return array }
        if let array = value as? [Bool] { return array }
        return String(describing: value)
    }

    /// Stable anonymous identity. Optional display name is a people property, never the distinct ID.
    func identifyCurrentUser(displayName: String? = nil) {
        Mixpanel.mainInstance().identify(distinctId: analyticsUserId())
        guard let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        Mixpanel.mainInstance().people.set(properties: [
            "$name": displayName,
            "display_name": displayName
        ])
    }

    func identify(userId: String) {
        identifyCurrentUser(displayName: userId)
    }

    /// Stable pseudonymous Mixpanel identifier used to join server-side subscription events
    /// to this device's existing analytics history. Never use a display name or email here.
    func attributionDistinctID() -> String {
        analyticsUserId()
    }

    func reset() {
        Mixpanel.mainInstance().reset()
        UserDefaults.standard.removeObject(forKey: Self.analyticsUserIdKey)
    }

    private func analyticsUserId() -> String {
        if let existing = UserDefaults.standard.string(forKey: Self.analyticsUserIdKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.analyticsUserIdKey)
        return id
    }
}
