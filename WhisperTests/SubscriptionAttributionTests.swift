import RevenueCat
import Testing
@testable import Revera_AI

struct SubscriptionAttributionTests {
    @Test func normalEntitlementAfterObservedTrialIsConversionCandidate() {
        #expect(SubscriptionAttribution.observedTrialAction(
            hasActiveTrial: false,
            hadObservedTrial: true,
            isPremium: true,
            hasNormalActiveEntitlement: true
        ) == .trackConversion)
    }

    @Test func trialRemainsObservedWithoutReportingConversion() {
        #expect(SubscriptionAttribution.observedTrialAction(
            hasActiveTrial: true,
            hadObservedTrial: true,
            isPremium: true,
            hasNormalActiveEntitlement: false
        ) == .observeTrial)
    }

    @Test func expiredTrialClearsObservation() {
        #expect(SubscriptionAttribution.observedTrialAction(
            hasActiveTrial: false,
            hadObservedTrial: true,
            isPremium: false,
            hasNormalActiveEntitlement: false
        ) == .clearObservation)
    }

    @Test func normalEntitlementWithoutObservedTrialIsNotCalledConversion() {
        #expect(SubscriptionAttribution.observedTrialAction(
            hasActiveTrial: false,
            hadObservedTrial: false,
            isPremium: true,
            hasNormalActiveEntitlement: true
        ) == .none)
    }

    @Test func revenueCatPeriodTypesHaveStableAnalyticsNames() {
        #expect(SubscriptionAttribution.periodTypeName(.trial) == "trial")
        #expect(SubscriptionAttribution.periodTypeName(.intro) == "intro")
        #expect(SubscriptionAttribution.periodTypeName(.normal) == "normal")
        #expect(SubscriptionAttribution.periodTypeName(.prepaid) == "prepaid")
    }
}
