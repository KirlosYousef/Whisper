//
//  PayWallView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 15/11/2025.
//


import SwiftUI
import RevenueCat
import RevenueCatUI

enum PaywallSource: String {
    case onboardingControl = "onboarding_control"
    case onboardingRealtimeDemo = "onboarding_realtime_demo"
    case mainApp = "main_app"
    case trialExhausted = "trial_exhausted"
}

struct PayWallView: View {
    var displayCloseButton: Bool = false
    var onImpressionTracked: () -> Void = {}

    @State private var presentationID = UUID().uuidString
    @State private var didTrackImpression = false
    @State private var activePackageProperties: [String: Any] = [:]
    @State private var analyticsSource: PaywallSource
    @State private var analyticsDemoOutcome: String
    @State private var offeringIdentifier: String?
    @State private var selectedOffering: Offering?

    init(
        displayCloseButton: Bool = false,
        source: PaywallSource = .mainApp,
        demoOutcome: String = "not_applicable",
        offeringIdentifier: String? = nil,
        onImpressionTracked: @escaping () -> Void = {}
    ) {
        self.displayCloseButton = displayCloseButton
        self.onImpressionTracked = onImpressionTracked
        _analyticsSource = State(initialValue: source)
        _analyticsDemoOutcome = State(initialValue: demoOutcome)
        _offeringIdentifier = State(initialValue: offeringIdentifier)
    }
    
    var body: some View {
        Group {
            if let selectedOffering {
                RevenueCatUI.PaywallView(offering: selectedOffering, displayCloseButton: displayCloseButton)
            } else if offeringIdentifier != nil {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading unlimited subscription…")
                        .font(.app(.medium, size: 16))
                    Button("Try again") {
                        Task { await loadSelectedOffering() }
                    }
                }
                .task { await loadSelectedOffering() }
            } else {
                RevenueCatUI.PaywallView(displayCloseButton: displayCloseButton)
            }
        }
            .onPurchaseStarted { package in
                activePackageProperties = packageProperties(package)
                track("Paywall Purchase Started", properties: activePackageProperties)
            }
            .onPurchaseCompleted { transaction, customerInfo in
                var properties = activePackageProperties
                properties["entitlement_count"] = customerInfo.entitlements.active.count
                if customerInfo.entitlements.active.count == 1,
                   let periodType = customerInfo.entitlements.active.values.first?.periodType {
                    properties["subscription_period_type"] = SubscriptionAttribution.periodTypeName(periodType)
                }
                if let transaction {
                    properties["transaction_product_identifier"] = transaction.productIdentifier
                }
                track("Paywall Purchase Completed", properties: properties)
                PaywallManager.shared.recordCompletedPaywallPurchase(customerInfo: customerInfo)
                UsageAccessManager.shared.invalidateSession()
                Task { await UsageAccessManager.shared.refresh(force: true) }
            }
            .onPurchaseCancelled {
                track("Paywall Purchase Cancelled", properties: activePackageProperties)
            }
            .onPurchaseFailure { error in
                var properties = activePackageProperties
                properties["error_code"] = error.code
                properties["error_domain"] = error.domain
                track("Paywall Purchase Failed", properties: properties)
            }
            .onRestoreStarted {
                track("Paywall Restore Started")
            }
            .onRestoreCompleted { customerInfo in
                track("Paywall Restore Completed", properties: [
                    "entitlement_count": customerInfo.entitlements.active.count
                ])
            }
            .onRestoreFailure { error in
                track("Paywall Restore Failed", properties: [
                    "error_code": error.code,
                    "error_domain": error.domain
                ])
            }
            .onAppear {
                guard !didTrackImpression else { return }
                didTrackImpression = true
                HapticsManager.shared.impact(.light)
                track("Paywall Shown", properties: ["display_close_button": displayCloseButton])
                onImpressionTracked()
            }
            .task(id: offeringIdentifier) { await loadSelectedOffering() }
    }

    @MainActor
    private func loadSelectedOffering() async {
        guard let offeringIdentifier else { return }
        do {
            let offerings = try await Purchases.shared.offerings()
            selectedOffering = offerings.all[offeringIdentifier]
        } catch {
            selectedOffering = nil
        }
    }

    private func packageProperties(_ package: Package) -> [String: Any] {
        [
            "package_identifier": package.identifier,
            "package_type": String(describing: package.packageType),
            "product_identifier": package.storeProduct.productIdentifier,
            "price": NSDecimalNumber(decimal: package.storeProduct.price).doubleValue,
            "currency": package.storeProduct.currencyCode ?? "unknown",
            "has_intro_offer": package.storeProduct.introductoryDiscount != nil
        ]
    }

    private func track(_ event: String, properties: [String: Any] = [:]) {
        var merged = properties
        merged["source"] = analyticsSource.rawValue
        merged["demo_outcome"] = analyticsDemoOutcome
        merged["paywall_presentation_id"] = presentationID
        AnalyticsService.shared.trackEvent(event, properties: merged)
    }
}

struct PayWallViewModifier: ViewModifier {
    @Binding var showPaywallView: Bool
    @State private var showCloseButton = false
    
    @AppStorage("showPaywall") private var showPaywall = true
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showPaywall) {
                ZStack {
                    PayWallView(displayCloseButton: false, source: .mainApp)
                    
                    if showCloseButton {
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    AnalyticsService.shared.trackEvent("Paywall Dismissed", properties: [
                                        "source": "close_button"
                                    ])
                                    showPaywall = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                        .padding()
                                        .shadow(radius: 2)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .onAppear {
                    // Show close button after a few seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation {
                            showCloseButton = true
                        }
                    }
                }
                .onDisappear {
                    showCloseButton = false
                    showPaywall = false
                }
            }
    }
}

extension View {
    func paywall() -> some View {
        modifier(PayWallViewModifier(showPaywallView: .constant(true)))
    }
}
