//
//  PaywallManager.swift
//  Whisper
//
//  Created by Kirlos Yousef on 15/11/2025.
//

import Foundation
import RevenueCat
import Security
import StoreKit

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
            "experiment_variant": variant.rawValue,
            "mixpanel_distinct_id": AnalyticsService.shared.attributionDistinctID()
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

enum UsageAccessError: LocalizedError {
    case noVerifiedSubscription
    case trialExhausted
    case updateRequired
    case verificationPending

    var errorDescription: String? {
        switch self {
        case .noVerifiedSubscription: "An active App Store subscription could not be verified. Reopen Revera while online and try again."
        case .trialExhausted: "You’ve used your 30 trial minutes. Start unlimited transcription now, or keep recording audio."
        case .updateRequired: "Update Revera to continue cloud transcription. Your saved recordings are still available."
        case .verificationPending: "Your purchase is still being verified. Keep your recording and try again shortly."
        }
    }
}

struct UsageAccessSnapshot: Decodable {
    let state: String
    let active: Bool?
    let paid: Bool?
    let demo: Bool?
    let expiresAt: Double?
    let allowanceMs: Int?
    let consumedMs: Int
    let reservedMs: Int
    let remainingMs: Int?
    let paidPeriodStartAt: Double?
    let paidConsumedMs: Int?
    let policyVersion: Int

    var remainingMinutes: Int? {
        guard let remainingMs else { return nil }
        return Int(ceil(Double(remainingMs) / 60_000))
    }
}

@MainActor
final class UsageAccessManager: ObservableObject {
    static let shared = UsageAccessManager()
    static let immediateUnlimitedPurchaseEnabled = true
    private static let trialProductID = "KirlosYousef.Whisper.AnnualThreeDayTrial"
    private static let unlimitedProductID = "KirlosYousef.Whisper.AnnualUnlimited"
    private static let demoKeychainAccount = "onboarding-demo-install-id"

    @Published private(set) var snapshot: UsageAccessSnapshot?
    @Published private(set) var isResolving = false
    @Published private(set) var shouldShowFiveMinuteWarning = false
    @Published private(set) var lastAccessError: UsageAccessError?
    /// Set while an unlimited plan change is queued to start when the current trial ends.
    @Published private(set) var scheduledUnlimitedStart: Date?

    private var appToken: String?
    private var appTokenExpiresAt = Date.distantPast
    private var demoToken: String?
    private var demoTokenExpiresAt = Date.distantPast
    private var sessionTask: Task<SessionResponse, Error>?

    private struct SessionResponse: Decodable {
        let token: String
        let usage: UsageAccessSnapshot
    }

    func authorizationHeader(forOnboardingDemo isDemo: Bool = false) async throws -> String {
        if isDemo {
            if let demoToken, demoTokenExpiresAt > Date().addingTimeInterval(30) {
                return "Bearer \(demoToken)"
            }
            let id = try onboardingDemoID()
            var request = URLRequest(url: URL(string: "\(OpenAIConfiguration.workerBaseURL)/usage/demo-session")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["demoID": id])
            let response = try await sendSessionRequest(request)
            demoToken = response.token
            demoTokenExpiresAt = Date().addingTimeInterval(240)
            updateSnapshot(response.usage)
            return "Bearer \(response.token)"
        }

        if let appToken, appTokenExpiresAt > Date().addingTimeInterval(30) {
            lastAccessError = nil
            return "Bearer \(appToken)"
        }
        let response: SessionResponse
        do {
            response = try await fetchAppSession()
        } catch let error as UsageAccessError {
            lastAccessError = error
            throw error
        }
        lastAccessError = nil
        appToken = response.token
        appTokenExpiresAt = Date().addingTimeInterval(270)
        updateSnapshot(response.usage)
        return "Bearer \(response.token)"
    }

    /// Concurrent callers (several segments asking for a token at once) share one session request.
    private func fetchAppSession() async throws -> SessionResponse {
        if let sessionTask {
            return try await sessionTask.value
        }
        let task = Task { try await self.createAppSession() }
        sessionTask = task
        defer { sessionTask = nil }
        return try await task.value
    }

    private func createAppSession() async throws -> SessionResponse {
        do {
            return try await requestAppSession()
        } catch UsageAccessError.noVerifiedSubscription {
            // RevenueCat may not have seen the purchase yet; sync once and retry.
            _ = try? await Purchases.shared.syncPurchases()
            return try await requestAppSession()
        }
    }

    private func requestAppSession() async throws -> SessionResponse {
        let signedTransactions = await signedActiveSubscriptionTransactions()
        guard !signedTransactions.isEmpty else { throw UsageAccessError.noVerifiedSubscription }
        var request = URLRequest(url: URL(string: "\(OpenAIConfiguration.workerBaseURL)/usage/session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "appUserID": Purchases.shared.appUserID,
            "signedTransactions": signedTransactions
        ])
        return try await sendSessionRequest(request)
    }

    func refresh(force: Bool = false) async {
        isResolving = true
        defer { isResolving = false }
        if force {
            appToken = nil
            appTokenExpiresAt = .distantPast
        }
        do {
            _ = try await authorizationHeader()
            if snapshot?.state == "trial" {
                await updateScheduledUnlimitedStart()
            } else if snapshot?.state == "paid" {
                scheduledUnlimitedStart = nil
            }
        } catch let error as UsageAccessError {
            // Only a definitive answer clears the snapshot; transient and trial errors keep the last known state.
            switch error {
            case .noVerifiedSubscription, .updateRequired:
                snapshot = nil
            case .trialExhausted, .verificationPending:
                break
            }
            print("Usage access refresh: \(error.localizedDescription)")
        } catch {
            // Network failures keep the last snapshot.
            print("Usage access refresh: \(error.localizedDescription)")
        }
    }

    /// RevenueCat and StoreKit propagate a purchase with a delay, so poll the Worker for a few seconds.
    /// Returns true once the Worker reports paid usage.
    func refreshAfterPurchase() async -> Bool {
        invalidateSession()
        for delay in [0, 1, 2, 4, 8] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            await refresh(force: true)
            if snapshot?.state == "paid" { return true }
        }
        await updateScheduledUnlimitedStart()
        return false
    }

    /// An unlimited plan purchased during a trial may be scheduled to start when the trial ends.
    func updateScheduledUnlimitedStart() async {
        var scheduled: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.trialProductID,
                  let status = await transaction.subscriptionStatus,
                  case .verified(let renewal) = status.renewalInfo,
                  renewal.autoRenewPreference == Self.unlimitedProductID else { continue }
            scheduled = transaction.expirationDate
        }
        scheduledUnlimitedStart = scheduled
    }

    func invalidateSession() {
        appToken = nil
        appTokenExpiresAt = .distantPast
    }

    func refreshUsageSnapshot() async {
        do {
            var request = URLRequest(url: URL(string: "\(OpenAIConfiguration.workerBaseURL)/usage/state")!)
            request.httpMethod = "GET"
            request.setValue(try await authorizationHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            updateSnapshot(try JSONDecoder().decode(UsageAccessSnapshot.self, from: data))
        } catch {
            print("Usage snapshot refresh: \(error.localizedDescription)")
        }
    }

    func markFiveMinuteWarningPresented() {
        UserDefaults.standard.set(true, forKey: "trialFiveMinuteWarningPresented")
        shouldShowFiveMinuteWarning = false
    }

    private func signedActiveSubscriptionTransactions() async -> [String] {
        var transactions: [String] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) == true,
                  transaction.productID == Self.trialProductID || transaction.productID == Self.unlimitedProductID else { continue }
            transactions.append(result.jwsRepresentation)
        }
        return transactions
    }

    private func sendSessionRequest(_ request: URLRequest) async throws -> SessionResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageAccessError.verificationPending }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 402 { throw UsageAccessError.trialExhausted }
            if http.statusCode == 403 { throw UsageAccessError.noVerifiedSubscription }
            if http.statusCode == 426 { throw UsageAccessError.updateRequired }
            throw UsageAccessError.verificationPending
        }
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
        return decoded
    }

    private func updateSnapshot(_ value: UsageAccessSnapshot) {
        snapshot = value
        if value.state == "trial",
           let remainingMs = value.remainingMs,
           remainingMs > 0,
           remainingMs <= 5 * 60_000,
           !UserDefaults.standard.bool(forKey: "trialFiveMinuteWarningPresented") {
            shouldShowFiveMinuteWarning = true
        }
    }

    private func onboardingDemoID() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "Revera",
            kSecAttrAccount as String: Self.demoKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) { return value }
        let value = UUID().uuidString.lowercased()
        var item = query
        item.removeValue(forKey: kSecReturnData as String)
        item.removeValue(forKey: kSecMatchLimit as String)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UsageAccessError.verificationPending }
        return value
    }
}
