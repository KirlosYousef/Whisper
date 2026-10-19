import Foundation

/// The Worker's view of the subscription and its usage. The Worker is the source of truth for trial minutes.
struct UsageAccessSnapshot: Decodable, Equatable {
    let state: String
    let active: Bool?
    let paid: Bool?
    let demo: Bool?
    /// When the current App Store period ends, in milliseconds since 1970. For a trial this is the end of the 3 days.
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

    var periodEndsAt: Date? {
        expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

enum UsageAccessError: LocalizedError, Equatable {
    case noVerifiedSubscription
    case trialExhausted
    case updateRequired
    case verificationPending

    var errorDescription: String? {
        switch self {
        case .noVerifiedSubscription: "An active App Store subscription could not be verified. Reopen Revera while online and try again."
        case .trialExhausted: "You’ve used your 30 trial minutes. Upgrade to Unlimited to keep transcribing."
        case .updateRequired: "Update Revera to continue cloud transcription. Your saved recordings are still available."
        case .verificationPending: "Your subscription is still being verified. Your audio is saved and will transcribe shortly."
        }
    }

    /// Maps a Worker status code from `/usage/session` to the error it means.
    static func forSessionStatus(_ statusCode: Int) -> UsageAccessError {
        switch statusCode {
        case 402: .trialExhausted
        case 403: .noVerifiedSubscription
        case 426: .updateRequired
        default: .verificationPending
        }
    }
}

/// What the user can do right now.
enum AccessState: Equatable {
    /// RevenueCat has not answered yet and nothing is cached.
    case unknown
    /// No active trial or subscription.
    case noSubscription
    /// The App Store reports a subscription, but the Worker has not confirmed its usage yet (offline, or still verifying).
    case unverified
    /// In the 3-day trial with minutes left.
    case trial(remainingMs: Int)
    /// All 30 trial minutes are used. `unlimitedStartsAt` is set when an Unlimited plan change waits for the trial to end.
    case trialExhausted(unlimitedStartsAt: Date?)
    /// Unlimited (the Unlimited plan, or the trial plan after Apple renewed it).
    case paid

    var canTranscribe: Bool {
        switch self {
        case .trial, .paid: true
        default: false
        }
    }

    var isTrialExhausted: Bool {
        if case .trialExhausted = self { return true }
        return false
    }
}

enum AccessResolver {
    static func resolve(
        snapshot: UsageAccessSnapshot?,
        isPremium: Bool,
        hasResolvedPremium: Bool,
        scheduledUnlimitedStart: Date? = nil,
        now: Date = Date()
    ) -> AccessState {
        if let snapshot, snapshot.active != false {
            switch snapshot.state {
            case "paid":
                return .paid
            case "trial":
                // Once the 3 days are over Apple has renewed (paid) or ended the plan; this snapshot no longer applies.
                let trialEnded = snapshot.periodEndsAt.map { $0 <= now } ?? false
                if !trialEnded, let remaining = snapshot.remainingMs {
                    return remaining > 0 ? .trial(remainingMs: remaining) : .trialExhausted(unlimitedStartsAt: scheduledUnlimitedStart)
                }
            default:
                break
            }
        }
        if isPremium { return .unverified }
        return hasResolvedPremium ? .noSubscription : .unknown
    }
}

/// Which paywall the app shows over itself.
enum AccessGate: Equatable {
    case open
    /// Hard gate: no trial or subscription.
    case subscribe
    /// The trial minutes are used: offer Unlimited. The user can close it to read existing transcripts.
    case upgrade

    static func forState(_ state: AccessState) -> AccessGate {
        switch state {
        case .unknown, .noSubscription: .subscribe
        case .trialExhausted: .upgrade
        case .unverified, .trial, .paid: .open
        }
    }
}

/// Why a recording runs without live captions.
enum RecordingStartNotice: Equatable {
    case offline
    case realtimeUnavailable

    var message: String {
        switch self {
        case .offline: "You’re offline. Recording in 20-second segments; they transcribe when you’re back online."
        case .realtimeUnavailable: "Live captions are unavailable right now. Recording in 20-second segments instead."
        }
    }
}

enum RecordingStartDecision: Equatable {
    case start(TranscriptionMode, notice: RecordingStartNotice?)
    case requireUpgrade
    case requireSubscription
}

/// Step 1 of starting a recording: decide from access alone, before any permission prompt or network connection.
enum RecordingStartPolicy {
    static func decide(
        access: AccessState,
        requestedMode: TranscriptionMode,
        isOnline: Bool,
        realtimeConfigured: Bool
    ) -> RecordingStartDecision {
        switch access {
        case .trialExhausted:
            return .requireUpgrade
        case .unknown, .noSubscription:
            return .requireSubscription
        case .unverified:
            // Usage can't be confirmed, so a live stream would be refused. Saved segments transcribe once it is.
            return .start(.segments20s, notice: notice(for: requestedMode, isOnline: isOnline))
        case .trial, .paid:
            guard requestedMode == .realtimeOpenAI else { return .start(.segments20s, notice: nil) }
            guard isOnline, realtimeConfigured else {
                return .start(.segments20s, notice: isOnline ? .realtimeUnavailable : .offline)
            }
            return .start(.realtimeOpenAI, notice: nil)
        }
    }

    private static func notice(for requestedMode: TranscriptionMode, isOnline: Bool) -> RecordingStartNotice? {
        guard requestedMode == .realtimeOpenAI else { return nil }
        return isOnline ? .realtimeUnavailable : .offline
    }
}

/// Why the realtime connection was refused or dropped.
enum RealtimeConnectionFailure: Equatable {
    case usageExhausted
    case subscriptionRequired
    /// The short-lived Worker token expired; fetch a new one and reconnect.
    case sessionExpired
    case updateRequired
    case transient

    var isTerminal: Bool {
        switch self {
        case .usageExhausted, .subscriptionRequired, .updateRequired: true
        case .sessionExpired, .transient: false
        }
    }

    /// Classifies a refused WebSocket upgrade (HTTP status) or a Worker close code.
    static func classify(httpStatus: Int?, closeCode: Int?) -> RealtimeConnectionFailure {
        switch closeCode {
        case 4409: return .usageExhausted
        case 4403: return .subscriptionRequired
        default: break
        }
        switch httpStatus {
        case 401: return .sessionExpired
        case 402: return .usageExhausted
        case 403: return .subscriptionRequired
        case 426: return .updateRequired
        default: return .transient
        }
    }

    static func classify(_ error: UsageAccessError) -> RealtimeConnectionFailure {
        switch error {
        case .trialExhausted: .usageExhausted
        case .noVerifiedSubscription: .subscriptionRequired
        case .updateRequired: .updateRequired
        case .verificationPending: .transient
        }
    }
}

/// How a tap on the record button ended.
enum RecordingStartOutcome: Equatable {
    case started
    case needsUpgrade
    case needsSubscription
    case permissionDenied
    case cancelled
    case failed
}

/// The first answer to a realtime connect made while starting a recording.
enum RealtimeConnectResult: Equatable {
    case connected
    case usageExhausted
    case subscriptionRequired
    case unavailable(String)
}
