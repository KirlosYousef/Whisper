import XCTest
@testable import Revera_AI

final class SubscriptionAccessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(state: String, remainingMs: Int?, active: Bool? = true, endsIn: TimeInterval? = 86_400) throws -> UsageAccessSnapshot {
        var fields = ["\"state\":\"\(state)\"", "\"consumedMs\":0", "\"reservedMs\":0", "\"policyVersion\":1"]
        if let active { fields.append("\"active\":\(active)") }
        if let remainingMs { fields.append("\"remainingMs\":\(remainingMs)") }
        if let endsIn { fields.append("\"expiresAt\":\((now.timeIntervalSince1970 + endsIn) * 1_000)") }
        return try JSONDecoder().decode(UsageAccessSnapshot.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func resolve(_ snapshot: UsageAccessSnapshot?, isPremium: Bool = false, resolved: Bool = true, scheduled: Date? = nil) -> AccessState {
        AccessResolver.resolve(snapshot: snapshot, isPremium: isPremium, hasResolvedPremium: resolved, scheduledUnlimitedStart: scheduled, now: now)
    }

    // MARK: AccessResolver

    func testTrialWithMinutesLeftIsTrial() throws {
        XCTAssertEqual(resolve(try snapshot(state: "trial", remainingMs: 600_000)), .trial(remainingMs: 600_000))
    }

    func testTrialWithNoMinutesLeftIsExhaustedEvenWhenTheAppStoreReportsPremium() throws {
        let used = try snapshot(state: "trial", remainingMs: 0)
        XCTAssertEqual(resolve(used, isPremium: true), .trialExhausted(unlimitedStartsAt: nil))
        XCTAssertEqual(resolve(used, isPremium: false), .trialExhausted(unlimitedStartsAt: nil))
    }

    func testExhaustedTrialCarriesTheScheduledUnlimitedStart() throws {
        let start = now.addingTimeInterval(3_600)
        XCTAssertEqual(resolve(try snapshot(state: "trial", remainingMs: 0), scheduled: start), .trialExhausted(unlimitedStartsAt: start))
    }

    func testUpgradeToUnlimitedOpensTheApp() throws {
        XCTAssertEqual(resolve(try snapshot(state: "paid", remainingMs: nil, endsIn: 365 * 86_400)), .paid)
    }

    /// After 3 days Apple renews the trial into a paid year; a trial snapshot from before that no longer applies.
    func testTrialSnapshotFromBeforeTheTrialEndedDoesNotKeepTheUserExhausted() throws {
        let stale = try snapshot(state: "trial", remainingMs: 0, endsIn: -60)
        XCTAssertEqual(resolve(stale, isPremium: true), .unverified)
        XCTAssertEqual(resolve(stale, isPremium: false), .noSubscription)
    }

    func testInactiveSnapshotFallsBackToTheAppStoreEntitlement() throws {
        let inactive = try snapshot(state: "inactive", remainingMs: nil, active: false, endsIn: -60)
        XCTAssertEqual(resolve(inactive, isPremium: true), .unverified)
        XCTAssertEqual(resolve(inactive, isPremium: false), .noSubscription)
    }

    func testNoSnapshot() {
        XCTAssertEqual(resolve(nil, isPremium: false, resolved: true), .noSubscription)
        XCTAssertEqual(resolve(nil, isPremium: false, resolved: false), .unknown)
        XCTAssertEqual(resolve(nil, isPremium: true), .unverified)
    }

    func testCanTranscribe() {
        XCTAssertTrue(AccessState.trial(remainingMs: 1).canTranscribe)
        XCTAssertTrue(AccessState.paid.canTranscribe)
        XCTAssertFalse(AccessState.trialExhausted(unlimitedStartsAt: nil).canTranscribe)
        XCTAssertFalse(AccessState.unverified.canTranscribe)
        XCTAssertFalse(AccessState.noSubscription.canTranscribe)
        XCTAssertFalse(AccessState.unknown.canTranscribe)
    }

    // MARK: AccessGate

    func testGate() {
        XCTAssertEqual(AccessGate.forState(.noSubscription), .subscribe)
        XCTAssertEqual(AccessGate.forState(.unknown), .subscribe)
        XCTAssertEqual(AccessGate.forState(.trialExhausted(unlimitedStartsAt: nil)), .upgrade)
        XCTAssertEqual(AccessGate.forState(.trial(remainingMs: 60_000)), .open)
        XCTAssertEqual(AccessGate.forState(.paid), .open)
        XCTAssertEqual(AccessGate.forState(.unverified), .open)
    }

    // MARK: RecordingStartPolicy

    private func decide(_ access: AccessState, _ mode: TranscriptionMode = .realtimeOpenAI, online: Bool = true, configured: Bool = true) -> RecordingStartDecision {
        RecordingStartPolicy.decide(access: access, requestedMode: mode, isOnline: online, realtimeConfigured: configured)
    }

    func testExhaustedTrialAsksForTheUpgradeBeforeAnythingElse() {
        XCTAssertEqual(decide(.trialExhausted(unlimitedStartsAt: nil)), .requireUpgrade)
        XCTAssertEqual(decide(.trialExhausted(unlimitedStartsAt: nil), .segments20s), .requireUpgrade)
    }

    func testNoSubscriptionAsksToSubscribe() {
        XCTAssertEqual(decide(.noSubscription), .requireSubscription)
        XCTAssertEqual(decide(.unknown), .requireSubscription)
    }

    func testTrialWithMinutesLeftStartsRealtimeWithoutAFallbackNotice() {
        XCTAssertEqual(decide(.trial(remainingMs: 60_000)), .start(.realtimeOpenAI, notice: nil))
        XCTAssertEqual(decide(.paid), .start(.realtimeOpenAI, notice: nil))
    }

    func testSegmentsModeNeverShowsANotice() {
        XCTAssertEqual(decide(.trial(remainingMs: 60_000), .segments20s), .start(.segments20s, notice: nil))
        XCTAssertEqual(decide(.paid, .segments20s, online: false), .start(.segments20s, notice: nil))
    }

    func testRealtimeOfflineFallsBackWithAnOfflineNotice() {
        XCTAssertEqual(decide(.paid, online: false), .start(.segments20s, notice: .offline))
    }

    func testRealtimeNotConfiguredFallsBack() {
        XCTAssertEqual(decide(.paid, configured: false), .start(.segments20s, notice: .realtimeUnavailable))
    }

    func testUnverifiedAccessRecordsSegmentsSoNothingIsLost() {
        XCTAssertEqual(decide(.unverified), .start(.segments20s, notice: .subscriptionUnverified))
        XCTAssertEqual(decide(.unverified, online: false), .start(.segments20s, notice: .offline))
        XCTAssertEqual(decide(.unverified, .segments20s), .start(.segments20s, notice: nil))
    }

    // MARK: RealtimeConnectionFailure

    func testRefusedUpgradeStatusesAreClassified() {
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 402, closeCode: nil), .usageExhausted)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 403, closeCode: nil), .subscriptionRequired)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 401, closeCode: nil), .sessionExpired)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 426, closeCode: nil), .updateRequired)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 502, closeCode: nil), .transient)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: nil, closeCode: nil), .transient)
    }

    func testWorkerCloseCodesWinOverTheUpgradeStatus() {
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 101, closeCode: 4409), .usageExhausted)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 101, closeCode: 4403), .subscriptionRequired)
        XCTAssertEqual(RealtimeConnectionFailure.classify(httpStatus: 101, closeCode: 1011), .transient)
    }

    func testOnlyAccessFailuresStopReconnecting() {
        XCTAssertTrue(RealtimeConnectionFailure.usageExhausted.isTerminal)
        XCTAssertTrue(RealtimeConnectionFailure.subscriptionRequired.isTerminal)
        XCTAssertTrue(RealtimeConnectionFailure.updateRequired.isTerminal)
        XCTAssertFalse(RealtimeConnectionFailure.sessionExpired.isTerminal)
        XCTAssertFalse(RealtimeConnectionFailure.transient.isTerminal)
    }

    func testTokenErrorsMapToConnectionFailures() {
        XCTAssertEqual(RealtimeConnectionFailure.classify(.trialExhausted), .usageExhausted)
        XCTAssertEqual(RealtimeConnectionFailure.classify(.noVerifiedSubscription), .subscriptionRequired)
        XCTAssertEqual(RealtimeConnectionFailure.classify(.updateRequired), .updateRequired)
        XCTAssertEqual(RealtimeConnectionFailure.classify(.verificationPending), .transient)
    }

    // MARK: UsageAccessError

    func testSessionStatusMapping() {
        XCTAssertEqual(UsageAccessError.forSessionStatus(402), .trialExhausted)
        XCTAssertEqual(UsageAccessError.forSessionStatus(403), .noVerifiedSubscription)
        XCTAssertEqual(UsageAccessError.forSessionStatus(426), .updateRequired)
        XCTAssertEqual(UsageAccessError.forSessionStatus(503), .verificationPending)
    }

    func testSnapshotDecodesThePaidShapeWithNullAllowance() throws {
        let json = #"{"state":"paid","active":true,"paid":true,"demo":false,"expiresAt":1900000000000,"allowanceMs":null,"consumedMs":5,"reservedMs":0,"remainingMs":null,"paidPeriodStartAt":null,"paidConsumedMs":5,"policyVersion":1}"#
        let decoded = try JSONDecoder().decode(UsageAccessSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.state, "paid")
        XCTAssertNil(decoded.remainingMs)
        XCTAssertEqual(decoded.periodEndsAt, Date(timeIntervalSince1970: 1_900_000_000))
    }
}
