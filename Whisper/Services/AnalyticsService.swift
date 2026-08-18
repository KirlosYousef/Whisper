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
        Mixpanel.mainInstance().loggingEnabled = true
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
    /// Properties can contain String, Int, Double, Bool, or arrays of these types
    func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        // Convert properties to MixpanelType-compatible dictionary
        let mixpanelProperties = properties?.compactMapValues { value -> MixpanelType? in
            // MixpanelType accepts: String, Int, Double, Bool, Date, URL, and arrays of these
            if let string = value as? String { return string }
            if let int = value as? Int { return int }
            if let double = value as? Double { return double }
            if let bool = value as? Bool { return bool }
            if let date = value as? Date { return date }
            if let url = value as? URL { return url }
            // Convert arrays
            if let array = value as? [String] { return array }
            if let array = value as? [Int] { return array }
            if let array = value as? [Double] { return array }
            if let array = value as? [Bool] { return array }
            // Fallback: convert to string
            return String(describing: value)
        }
        Mixpanel.mainInstance().track(event: name, properties: mixpanelProperties)
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

// #region agent log
enum DebugSessionLog {
    static func write(hypothesisId: String, location: String, message: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "sessionId": "31fa07",
            "runId": "post-fix",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        DispatchQueue.global(qos: .utility).async {
            guard JSONSerialization.isValidJSONObject(payload),
                  let json = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: json, encoding: .utf8) else { return }
            let dataLine = Data((line + "\n").utf8)
            let path = "/Users/kirlosyousef/Developer/Whisper/.cursor/debug-31fa07.log"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: dataLine)
                try? handle.close()
            }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:7427/ingest/72658f9a-0ae3-4ccd-8e18-2716ecbaf0b4")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("31fa07", forHTTPHeaderField: "X-Debug-Session-Id")
            request.timeoutInterval = 2
            request.httpBody = json
            URLSession.shared.dataTask(with: request).resume()
        }
    }
}
// #endregion
