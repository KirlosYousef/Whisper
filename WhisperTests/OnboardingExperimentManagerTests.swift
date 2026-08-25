import Foundation
import Testing
@testable import Revera_AI

struct OnboardingExperimentManagerTests {
    @Test func assignsAndPersistsTreatmentVariant() throws {
        let defaults = try temporaryDefaults()
        let assignedAt = Date(timeIntervalSince1970: 1234)
        let manager = OnboardingExperimentManager(
            defaults: defaults,
            arguments: [],
            now: { assignedAt },
            chooseTreatment: { true }
        )

        #expect(manager.assignIfNeeded(hasCompletedOnboarding: false) == .realtimeDemo)
        #expect(manager.currentVariant == .realtimeDemo)
        #expect(manager.assignedAt == assignedAt)

        let relaunched = OnboardingExperimentManager(
            defaults: defaults,
            arguments: [],
            chooseTreatment: { false }
        )
        #expect(relaunched.assignIfNeeded(hasCompletedOnboarding: false) == .realtimeDemo)
    }

    @Test func doesNotAssignCompletedOnboarding() throws {
        let manager = OnboardingExperimentManager(
            defaults: try temporaryDefaults(),
            arguments: [],
            chooseTreatment: { true }
        )

        #expect(manager.assignIfNeeded(hasCompletedOnboarding: true) == nil)
        #expect(manager.currentVariant == nil)
    }

    @Test func combinedLaunchArgumentForcesControlVariant() throws {
        let manager = OnboardingExperimentManager(
            defaults: try temporaryDefaults(),
            arguments: ["Revera AI", "--onboarding-experiment-variant=control"],
            chooseTreatment: { true }
        )

        #expect(manager.assignIfNeeded(hasCompletedOnboarding: false) == .control)
    }

    @Test func splitLaunchArgumentForcesRealtimeVariant() throws {
        let manager = OnboardingExperimentManager(
            defaults: try temporaryDefaults(),
            arguments: ["Revera AI", "-onboardingExperimentVariant", "realtime_demo"],
            chooseTreatment: { false }
        )

        #expect(manager.assignIfNeeded(hasCompletedOnboarding: false) == .realtimeDemo)
    }

    @Test func forcedVariantOverridesPersistedAssignmentForUITests() throws {
        let defaults = try temporaryDefaults()
        let initiallyAssigned = OnboardingExperimentManager(
            defaults: defaults,
            arguments: [],
            chooseTreatment: { false }
        )
        #expect(initiallyAssigned.assignIfNeeded(hasCompletedOnboarding: false) == .control)

        let forced = OnboardingExperimentManager(
            defaults: defaults,
            arguments: ["Revera AI", "--onboarding-experiment-variant=realtime_demo"]
        )
        #expect(forced.assignIfNeeded(hasCompletedOnboarding: false) == .realtimeDemo)
        #expect(forced.currentVariant == .realtimeDemo)
    }

    @Test func debugDefaultCanForceRealtimeWithoutOverridingLaunchArguments() throws {
        let defaults = try temporaryDefaults()
        let debugDefault = OnboardingExperimentManager(
            defaults: defaults,
            arguments: [],
            defaultForcedVariant: .realtimeDemo,
            chooseTreatment: { false }
        )
        #expect(debugDefault.assignIfNeeded(hasCompletedOnboarding: false) == .realtimeDemo)

        let explicitControl = OnboardingExperimentManager(
            defaults: defaults,
            arguments: ["Revera AI", "--onboarding-experiment-variant=control"],
            defaultForcedVariant: .realtimeDemo
        )
        #expect(explicitControl.assignIfNeeded(hasCompletedOnboarding: false) == .control)
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suite = "OnboardingExperimentManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
