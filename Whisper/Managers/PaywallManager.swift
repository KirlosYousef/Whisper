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
    /// The active entitlements last seen, so usage is re-verified only when the plan actually changes.
    private var lastEntitlementFingerprint: String?

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

        // A purchase, an upgrade, or the trial renewing into Unlimited: ask the Worker for the new usage state.
        let fingerprint = Self.entitlementFingerprint(customerInfo)
        if fingerprint != lastEntitlementFingerprint {
            lastEntitlementFingerprint = fingerprint
            Task { await UsageAccessManager.shared.refresh(force: true) }
        }

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

    static func entitlementFingerprint(_ customerInfo: CustomerInfo) -> String {
        customerInfo.entitlements.active.values
            .map { entitlement in
                let expiration = entitlement.expirationDate?.timeIntervalSince1970 ?? 0
                return "\(entitlement.identifier)|\(entitlement.productIdentifier)|\(SubscriptionAttribution.periodTypeName(entitlement.periodType))|\(expiration)"
            }
            .sorted()
            .joined(separator: ",")
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

enum PurchaseConfirmation: Equatable {
    /// The Worker confirms access (a new trial, or Unlimited).
    case active
    /// The App Store scheduled the Unlimited plan to start when the trial ends.
    case scheduled(Date)
    /// The purchase has not reached the Worker yet. Access updates on its own once it does.
    case pending
}

/// Owns the Worker access token and the usage snapshot. Every cloud request asks it for a token,
/// and the UI reads `accessState` to decide which paywall, if any, to show.
@MainActor
final class UsageAccessManager: ObservableObject {
    static let shared = UsageAccessManager()
    static let trialProductID = "KirlosYousef.Whisper.AnnualThreeDayTrial"
    static let unlimitedProductID = "KirlosYousef.Whisper.AnnualUnlimited"
    /// The RevenueCat offering that sells the Unlimited plan to users whose trial minutes are used.
    static let unlimitedOfferingID = "annualUnlimited"
    private static let demoKeychainAccount = "onboarding-demo-install-id"
    private static let fiveMinuteWarningKey = "trialFiveMinuteWarningPresented"
    private static let requestTimeout: TimeInterval = 15

    @Published private(set) var snapshot: UsageAccessSnapshot?
    @Published private(set) var shouldShowFiveMinuteWarning = false
    @Published private(set) var lastAccessError: UsageAccessError?
    /// The Worker's own explanation of the last failed verification, shown so a stuck state is diagnosable.
    @Published private(set) var lastAccessDetail: String?
    /// Set while an Unlimited plan change is queued to start when the current trial ends.
    @Published private(set) var scheduledUnlimitedStart: Date?
    @Published private(set) var isConfirmingPurchase = false
    /// The result of the last purchase confirmation; `.pending` keeps the paywall from looking like nothing happened.
    @Published private(set) var purchaseConfirmation: PurchaseConfirmation?

    private var appToken: String?
    private var appTokenExpiresAt = Date.distantPast
    private var demoToken: String?
    private var demoTokenExpiresAt = Date.distantPast
    private var sessionTask: Task<SessionResponse, Error>?
    /// Bumped whenever the cached token is thrown away, so a session request that started earlier cannot restore it.
    private var sessionGeneration = 0
    private var refreshTask: Task<Void, Never>?
    /// Failed verifications back off 15s, 30s, 60s, then every 2 minutes, so a broken server isn't hammered.
    private var verificationFailures = 0
    private var nextVerificationRetry = Date.distantPast

    private struct SessionResponse: Decodable {
        let token: String
        let usage: UsageAccessSnapshot
    }

    var accessState: AccessState {
        AccessResolver.resolve(
            snapshot: snapshot,
            isPremium: PaywallManager.shared.isPremium,
            hasResolvedPremium: PaywallManager.shared.hasResolvedPremiumStatus,
            scheduledUnlimitedStart: scheduledUnlimitedStart
        )
    }

    // MARK: Tokens

    func authorizationHeader(forOnboardingDemo isDemo: Bool = false) async throws -> String {
        if isDemo {
            return "Bearer \(try await demoSessionToken())"
        }
        if let appToken, appTokenExpiresAt > Date().addingTimeInterval(30) {
            return "Bearer \(appToken)"
        }
        return "Bearer \(try await fetchAppSession().token)"
    }

    /// Throws away the cached token so the next request verifies the subscription again.
    func invalidateSession() {
        sessionGeneration += 1
        appToken = nil
        appTokenExpiresAt = .distantPast
        sessionTask = nil
    }

    /// The onboarding demo has its own short allowance and never changes the app's usage snapshot.
    private func demoSessionToken() async throws -> String {
        if let demoToken, demoTokenExpiresAt > Date().addingTimeInterval(30) {
            return demoToken
        }
        let id = try onboardingDemoID()
        var request = URLRequest(url: URL(string: "\(OpenAIConfiguration.workerBaseURL)/usage/demo-session")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["demoID": id])
        let response = try await sendSessionRequest(request)
        demoToken = response.token
        demoTokenExpiresAt = Date().addingTimeInterval(240)
        return response.token
    }

    /// Concurrent callers (several segments asking for a token at once) share one session request.
    private func fetchAppSession() async throws -> SessionResponse {
        if let sessionTask {
            return try await sessionTask.value
        }
        let generation = sessionGeneration
        let task = Task { try await self.createAppSession() }
        sessionTask = task
        do {
            let response = try await task.value
            if generation == sessionGeneration {
                sessionTask = nil
                appToken = response.token
                appTokenExpiresAt = Date().addingTimeInterval(270)
                lastAccessError = nil
                updateSnapshot(response.usage)
            }
            return response
        } catch {
            if generation == sessionGeneration {
                sessionTask = nil
                if let accessError = error as? UsageAccessError {
                    lastAccessError = accessError
                    if accessError == .verificationPending {
                        verificationFailures += 1
                        nextVerificationRetry = Date().addingTimeInterval(min(120, 15 * pow(2, Double(verificationFailures - 1))))
                    }
                    // Only a definitive answer clears the snapshot; transient failures keep the last known state.
                    if accessError == .noVerifiedSubscription || accessError == .updateRequired {
                        snapshot = nil
                    }
                }
            }
            throw error
        }
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
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "appUserID": Purchases.shared.appUserID,
            "signedTransactions": signedTransactions
        ])
        return try await sendSessionRequest(request)
    }

    private func sendSessionRequest(_ request: URLRequest) async throws -> SessionResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageAccessError.verificationPending }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            lastAccessDetail = "\(http.statusCode)\(message.map { ": \($0)" } ?? "")"
            throw UsageAccessError.forSessionStatus(http.statusCode)
        }
        lastAccessDetail = nil
        verificationFailures = 0
        nextVerificationRetry = .distantPast
        return try JSONDecoder().decode(SessionResponse.self, from: data)
    }

    // MARK: Refresh

    /// Brings the snapshot up to date. Concurrent calls share one refresh; `force` verifies the subscription again.
    func refresh(force: Bool = false) async {
        if force {
            invalidateSession()
        } else if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        if refreshTask == task {
            refreshTask = nil
        }
    }

    private func performRefresh() async {
        do {
            if appToken != nil, appTokenExpiresAt > Date().addingTimeInterval(30) {
                try await fetchUsageState()
            } else {
                _ = try await fetchAppSession()
            }
        } catch {
            print("Usage access refresh: \(error.localizedDescription)")
        }
        await updateScheduledUnlimitedStart()
    }

    /// Step 1 of starting a recording: the freshest access answer available without blocking an offline user.
    func accessForRecording(isOnline: Bool) async -> AccessState {
        if isOnline {
            await refresh()
        }
        return accessState
    }

    /// Re-reads usage with the cached token; used while the Record screen is open.
    func refreshUsageSnapshot() async {
        guard snapshot != nil else {
            // Never verified, or verification failed: try again on the backoff schedule so it recovers by itself.
            if lastAccessError == .verificationPending, Date() >= nextVerificationRetry {
                await refresh()
            }
            return
        }
        do {
            try await fetchUsageState()
        } catch {
            print("Usage snapshot refresh: \(error.localizedDescription)")
        }
    }

    private func fetchUsageState() async throws {
        var request = URLRequest(url: URL(string: "\(OpenAIConfiguration.workerBaseURL)/usage/state")!)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(try await authorizationHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            updateSnapshot(try JSONDecoder().decode(UsageAccessSnapshot.self, from: data))
        case 401, 403:
            // The token expired or the period ended (a trial renewing into Unlimited lands here): verify again.
            invalidateSession()
            _ = try await fetchAppSession()
        default:
            break
        }
    }

    /// Called after a purchase. RevenueCat and StoreKit propagate it with a delay, so poll the Worker for about 30 seconds.
    /// Buying Unlimited is confirmed only by `paid`; buying the trial plan by any usable access.
    func confirmPurchase(productID: String?) async -> PurchaseConfirmation {
        let expectsUnlimited = productID == Self.unlimitedProductID
        isConfirmingPurchase = true
        defer { isConfirmingPurchase = false }
        for delay in [0, 1, 2, 3, 5, 8, 13] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            await refresh(force: true)
            let state = accessState
            if state == .paid || (!expectsUnlimited && state.canTranscribe) {
                purchaseConfirmation = .active
                return .active
            }
            if expectsUnlimited, let scheduledUnlimitedStart {
                purchaseConfirmation = .scheduled(scheduledUnlimitedStart)
                return .scheduled(scheduledUnlimitedStart)
            }
        }
        purchaseConfirmation = .pending
        return .pending
    }

    /// An Unlimited plan bought during a trial is deferred by the App Store when it is ranked below the trial plan.
    func updateScheduledUnlimitedStart() async {
        guard snapshot?.state == "trial" else {
            scheduledUnlimitedStart = nil
            return
        }
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

    // MARK: Trial warning

    func markFiveMinuteWarningPresented() {
        UserDefaults.standard.set(true, forKey: Self.fiveMinuteWarningKey)
        shouldShowFiveMinuteWarning = false
    }

    private func updateSnapshot(_ value: UsageAccessSnapshot) {
        if snapshot != value {
            snapshot = value
        }
        if value.state == "paid" {
            purchaseConfirmation = nil
        }
        if value.state == "trial",
           let remainingMs = value.remainingMs,
           remainingMs > 0,
           remainingMs <= 5 * 60_000,
           !UserDefaults.standard.bool(forKey: Self.fiveMinuteWarningKey) {
            shouldShowFiveMinuteWarning = true
        }
    }

    // MARK: StoreKit

    private func signedActiveSubscriptionTransactions() async -> [String] {
        var transactions: [String] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded,
                  transaction.expirationDate.map({ $0 > Date() }) == true,
                  transaction.productID == Self.trialProductID || transaction.productID == Self.unlimitedProductID else { continue }
            transactions.append(result.jwsRepresentation)
        }
        return transactions
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
