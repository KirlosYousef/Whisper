import Foundation

enum OnboardingExperimentVariant: String, CaseIterable {
    case control
    case realtimeDemo = "realtime_demo"
}

final class OnboardingExperimentManager {
    static let shared: OnboardingExperimentManager = {
        #if DEBUG
        OnboardingExperimentManager(defaultForcedVariant: .realtimeDemo)
        #else
        OnboardingExperimentManager()
        #endif
    }()

    static let experimentID = "onboarding_realtime_demo_v1"

    private enum Key {
        static let variant = "onboardingExperiment.v1.variant"
        static let assignedAt = "onboardingExperiment.v1.assignedAt"
        static let assignmentTracked = "onboardingExperiment.v1.assignmentTracked"
    }

    private let defaults: UserDefaults
    private let arguments: [String]
    private let defaultForcedVariant: OnboardingExperimentVariant?
    private let now: () -> Date
    private let chooseTreatment: () -> Bool

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaultForcedVariant: OnboardingExperimentVariant? = nil,
        now: @escaping () -> Date = Date.init,
        chooseTreatment: @escaping () -> Bool = Bool.random
    ) {
        self.defaults = defaults
        self.arguments = arguments
        self.defaultForcedVariant = defaultForcedVariant
        self.now = now
        self.chooseTreatment = chooseTreatment
    }

    var currentVariant: OnboardingExperimentVariant? {
        guard let rawValue = defaults.string(forKey: Key.variant) else { return nil }
        return OnboardingExperimentVariant(rawValue: rawValue)
    }

    var assignedAt: Date? {
        defaults.object(forKey: Key.assignedAt) as? Date
    }

    @discardableResult
    func assignIfNeeded(hasCompletedOnboarding: Bool) -> OnboardingExperimentVariant? {
        if !hasCompletedOnboarding, let forcedVariant {
            if currentVariant != forcedVariant {
                defaults.set(forcedVariant.rawValue, forKey: Key.variant)
                defaults.set(now(), forKey: Key.assignedAt)
                defaults.set(false, forKey: Key.assignmentTracked)
            }
            return forcedVariant
        }

        if let currentVariant {
            return currentVariant
        }
        guard !hasCompletedOnboarding else { return nil }

        let variant: OnboardingExperimentVariant = chooseTreatment() ? .realtimeDemo : .control
        defaults.set(variant.rawValue, forKey: Key.variant)
        defaults.set(now(), forKey: Key.assignedAt)
        defaults.set(false, forKey: Key.assignmentTracked)
        return variant
    }

    func registerWithAnalyticsIfAssigned() {
        guard let variant = currentVariant else { return }
        let properties = analyticsProperties(for: variant)
        AnalyticsService.shared.registerSuperProperties(properties)

        guard !defaults.bool(forKey: Key.assignmentTracked) else { return }
        AnalyticsService.shared.trackEvent("Onboarding Experiment Assigned", properties: properties)
        defaults.set(true, forKey: Key.assignmentTracked)
    }

    func analyticsProperties(for variant: OnboardingExperimentVariant? = nil) -> [String: Any] {
        guard let variant = variant ?? currentVariant else { return [:] }
        var properties: [String: Any] = [
            "experiment_id": Self.experimentID,
            "experiment_variant": variant.rawValue
        ]
        if let assignedAt {
            properties["experiment_assigned_at"] = assignedAt
        }
        return properties
    }

    private var forcedVariant: OnboardingExperimentVariant? {
        if let combined = arguments.first(where: { $0.hasPrefix("--onboarding-experiment-variant=") }),
           let rawValue = combined.split(separator: "=", maxSplits: 1).last {
            return OnboardingExperimentVariant(rawValue: String(rawValue))
        }

        if let flagIndex = arguments.firstIndex(of: "-onboardingExperimentVariant"),
           arguments.indices.contains(flagIndex + 1),
           let variant = OnboardingExperimentVariant(rawValue: arguments[flagIndex + 1]) {
            return variant
        }

        return defaultForcedVariant
    }
}
