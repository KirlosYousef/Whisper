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

    private static let cachedPremiumKey = "cachedIsPremium"
    private static let lastTrackedUnsubscribeKey = "lastTrackedUnsubscribeAt"

    @Published var isPremium: Bool
    @Published var hasResolvedPremiumStatus = false
    private var didSetup = false

    override init() {
        isPremium = UserDefaults.standard.bool(forKey: Self.cachedPremiumKey)
        super.init()
    }

    func setup() {
        guard !didSetup else { return }
        didSetup = true
        guard let apiKey = loadRevenueCatAPIKey() else {
            assertionFailure("RevenueCat API key is missing. Set REVENUECAT_API_KEY env var or add it to Config.plist or Info.plist")
            hasResolvedPremiumStatus = true
            return
        }
        Purchases.configure(withAPIKey: apiKey)
        Purchases.shared.delegate = self

        Task {
            _ = await isPremiumMember()
        }
    }

    private func loadRevenueCatAPIKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["REVENUECAT_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        if let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let key = dict["RevenueCatAPIKey"] as? String,
           !key.isEmpty {
            return key
        }
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
            apply(customerInfo)
            return isPremium
        } catch {
            hasResolvedPremiumStatus = true
            print(error.localizedDescription)
            return isPremium
        }
    }

    @MainActor
    private func apply(_ customerInfo: CustomerInfo) {
        let isPremiumMember = !customerInfo.entitlements.active.isEmpty
        let wasPremium = isPremium
        isPremium = isPremiumMember
        hasResolvedPremiumStatus = true
        UserDefaults.standard.set(isPremiumMember, forKey: Self.cachedPremiumKey)

        if wasPremium != isPremiumMember {
            AnalyticsService.shared.trackEvent("Premium Status Changed", properties: [
                "is_premium": isPremiumMember,
                "entitlement_count": customerInfo.entitlements.active.count
            ])
            if wasPremium && !isPremiumMember {
                AnalyticsService.shared.trackEvent("Premium Expired", properties: [
                    "entitlement_count": customerInfo.entitlements.active.count
                ])
            }
        }

        trackCancellationIfNeeded(from: customerInfo, isPremiumNow: isPremiumMember)
    }

    private func trackCancellationIfNeeded(from customerInfo: CustomerInfo, isPremiumNow: Bool) {
        let latestUnsubscribe = customerInfo.entitlements.all.values
            .compactMap(\.unsubscribeDetectedAt)
            .max()
        guard let latestUnsubscribe else { return }

        let lastTracked = UserDefaults.standard.object(forKey: Self.lastTrackedUnsubscribeKey) as? Date
        guard lastTracked == nil || latestUnsubscribe > lastTracked! else { return }

        UserDefaults.standard.set(latestUnsubscribe, forKey: Self.lastTrackedUnsubscribeKey)
        AnalyticsService.shared.trackEvent("Subscription Cancelled", properties: [
            "still_premium": isPremiumNow,
            "cancelled_at": latestUnsubscribe
        ])
    }
}

extension PaywallManager: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            apply(customerInfo)
        }
    }
}
