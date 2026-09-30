//
//  PaywallManager.swift
//  Whisper
//
//  Created by Kirlos Yousef on 15/11/2025.
//

import Foundation
import RevenueCat

enum ObservedTrialConversionAction: Equatable {
    case observeTrial
    case clearObservation
    case trackConversion
    case none
}

enum SubscriptionAttribution {
    static func periodTypeName(_ periodType: PeriodType) -> String {
        switch periodType {
        case .trial: "trial"
        case .intro: "intro"
        case .normal: "normal"
        case .prepaid: "prepaid"
        }
    }

    static func observedTrialAction(
        hasActiveTrial: Bool,
        hadObservedTrial: Bool,
        isPremium: Bool,
        hasNormalActiveEntitlement: Bool
    ) -> ObservedTrialConversionAction {
        if hasActiveTrial { return .observeTrial }
        guard hadObservedTrial else { return .none }
        guard isPremium else { return .clearObservation }
        return hasNormalActiveEntitlement ? .trackConversion : .none
    }
}

class PaywallManager: NSObject, ObservableObject {
    static var shared = PaywallManager()

    private static let cachedPremiumKey = "cachedIsPremium"
    private static let lastTrackedUnsubscribeKey = "lastTrackedUnsubscribeAt"
    private static let observedTrialKey = "observedRevenueCatTrialForAttribution"

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
        syncOnboardingExperimentAttributes()

        Task {
            _ = await isPremiumMember()
        }
    }

    /// Saves only the experiment assignment so RevenueCat exports can be segmented by variant.
    /// These are custom customer attributes, not reserved install-attribution fields.
    private func syncOnboardingExperimentAttributes() {
        guard let variant = OnboardingExperimentManager.shared.currentVariant else { return }
        Purchases.shared.attribution.setAttributes([
            "experiment_id": OnboardingExperimentManager.experimentID,
            "experiment_variant": variant.rawValue
        ])
    }

    /// Called from RevenueCat's purchase callback, where CustomerInfo reflects the completed
    /// transaction. A trial period here is a reliable signal that the purchase started a trial.
    func recordCompletedPaywallPurchase(customerInfo: CustomerInfo) {
        let activeEntitlements = customerInfo.entitlements.active.values
        guard activeEntitlements.contains(where: { $0.periodType == .trial }) else { return }

        UserDefaults.standard.set(true, forKey: Self.observedTrialKey)
        AnalyticsService.shared.trackEvent("Subscription Trial Started", properties: [
            "subscription_period_type": "trial"
        ])
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

        trackObservedTrialConversion(from: customerInfo, isPremiumNow: isPremiumMember)

        if wasPremium != isPremiumMember {
            AnalyticsService.shared.trackEvent("Premium Status Changed", properties: [
                "is_premium": isPremiumMember,
                "entitlement_count": customerInfo.entitlements.active.count
            ])
            if isPremiumMember {
                AnalyticsService.shared.trackEvent("Premium Activated", properties: [
                    "entitlement_count": customerInfo.entitlements.active.count
                ])
            }
            if wasPremium && !isPremiumMember {
                AnalyticsService.shared.trackEvent("Premium Expired", properties: [
                    "entitlement_count": customerInfo.entitlements.active.count
                ])
            }
        }

        trackCancellationIfNeeded(from: customerInfo, isPremiumNow: isPremiumMember)
    }

    /// RevenueCat CustomerInfo is refreshed after a renewal and when the app becomes active.
    /// A transition from a locally observed trial to a normal entitlement is useful evidence of
    /// trial conversion, but cannot capture conversions while the app remains unopened.
    private func trackObservedTrialConversion(from customerInfo: CustomerInfo, isPremiumNow: Bool) {
        let hasActiveTrial = customerInfo.entitlements.active.values.contains { $0.periodType == .trial }
        let hasNormalActiveEntitlement = customerInfo.entitlements.active.values.contains {
            $0.periodType == .normal
        }
        let action = SubscriptionAttribution.observedTrialAction(
            hasActiveTrial: hasActiveTrial,
            hadObservedTrial: UserDefaults.standard.bool(forKey: Self.observedTrialKey),
            isPremium: isPremiumNow,
            hasNormalActiveEntitlement: hasNormalActiveEntitlement
        )

        switch action {
        case .observeTrial:
            UserDefaults.standard.set(true, forKey: Self.observedTrialKey)
        case .clearObservation:
            // The observed trial ended without an active entitlement; do not carry it into a later purchase.
            UserDefaults.standard.removeObject(forKey: Self.observedTrialKey)
        case .trackConversion:
            UserDefaults.standard.removeObject(forKey: Self.observedTrialKey)
            AnalyticsService.shared.trackEvent("Subscription Trial Converted (Observed)", properties: [
                "subscription_period_type": "normal",
                "attribution_source": "client_observed_customer_info_transition"
            ])
        case .none:
            break
        }
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
