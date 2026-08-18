//
//  PaywallManager.swift
//  Whisper
//
//  Created by Kirlos Yousef on 15/11/2025.
//

import Foundation
import RevenueCat

class PaywallManager: NSObject, ObservableObject {
    static var shared = PaywallManager()
    
    @Published var isPremium: Bool = false
    private var didSetup = false
    
    override init() {
        super.init()
    }
    
    func setup() {
        guard !didSetup else { return }
        didSetup = true
        // #region agent log
        DebugSessionLog.write(hypothesisId: "H6", location: "PaywallManager.swift:setup", message: "PaywallManager setup start", data: [:])
        // #endregion
        // Purchases.logLevel = .debug
        guard let apiKey = loadRevenueCatAPIKey() else {
            // #region agent log
            DebugSessionLog.write(hypothesisId: "H6", location: "PaywallManager.swift:setup", message: "RevenueCat API key missing", data: [:])
            // #endregion
            assertionFailure("RevenueCat API key is missing. Set REVENUECAT_API_KEY env var or add it to Config.plist or Info.plist")
            return
        }
        Purchases.configure(withAPIKey: apiKey)
        Purchases.shared.delegate = self
        // #region agent log
        DebugSessionLog.write(hypothesisId: "H6", location: "PaywallManager.swift:setup", message: "RevenueCat configured", data: [:])
        // #endregion
        
        Task {
            _ = await isPremiumMember()
        }
    }
    
    private func loadRevenueCatAPIKey() -> String? {
        // 1) Environment variable (Xcode scheme or CI)
        if let envKey = ProcessInfo.processInfo.environment["REVENUECAT_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        // 2) Config.plist bundled with the app (not committed; developer local only)
        if let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let key = dict["RevenueCatAPIKey"] as? String,
           !key.isEmpty {
            return key
        }
        // 3) Info.plist (optional fallback via build settings or CI injection)
        if let key = Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String, !key.isEmpty {
            return key
        }
        return nil
    }
    
    func loginUser(name: String) {
        DispatchQueue.global(qos: .userInteractive).async {
            Purchases.shared.attribution.setDisplayName(name)
        }
    }
    
    @MainActor
    func isPremiumMember() async -> Bool {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            let isPremiumMember = !customerInfo.entitlements.active.isEmpty // user has access to some entitlement
            
            let wasPremium = self.isPremium
            self.isPremium = isPremiumMember
            
            // Track premium status change
            if wasPremium != isPremiumMember {
                if isPremiumMember {
                    AnalyticsService.shared.trackEvent("Premium Status Changed", properties: [
                        "is_premium": true,
                        "entitlement_count": customerInfo.entitlements.active.count
                    ])
                } else {
                    AnalyticsService.shared.trackEvent("Premium Status Changed", properties: [
                        "is_premium": false
                    ])
                }
            }
            
            return isPremiumMember
        } catch {
            // handle error
            print(error.localizedDescription)
            return false
        }
    }
}

extension PaywallManager: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task {
            _ = await isPremiumMember()
        }
    }
}
