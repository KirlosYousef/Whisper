import XCTest
@testable import Revera_AI

final class ForcedPaywallGateTests: XCTestCase {
    private func snapshot(state: String, remainingMs: Int?) throws -> UsageAccessSnapshot {
        var fields = ["\"state\":\"\(state)\"", "\"consumedMs\":0", "\"reservedMs\":0", "\"policyVersion\":1"]
        if let remainingMs { fields.append("\"remainingMs\":\(remainingMs)") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(UsageAccessSnapshot.self, from: Data(json.utf8))
    }

    func testNeverSubscribedShowsSubscribeOffer() {
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: false, snapshot: nil), .subscribe)
    }

    func testPremiumEntitlementLetsUserIn() {
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: true, snapshot: nil), .none)
    }

    func testTrialWithMinutesLeftLetsUserIn() throws {
        let trial = try snapshot(state: "trial", remainingMs: 600_000)
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: false, snapshot: trial), .none)
    }

    func testTrialUsedUpShowsUnlimitedOfferEvenWhenPremium() throws {
        let used = try snapshot(state: "trial", remainingMs: 0)
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: true, snapshot: used), .trialExhausted)
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: false, snapshot: used), .trialExhausted)
    }

    func testPaidSnapshotLetsUserIn() throws {
        let paid = try snapshot(state: "paid", remainingMs: nil)
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: false, snapshot: paid), .none)
    }

    func testExpiredOrNoSnapshotWithoutEntitlementShowsSubscribeOffer() throws {
        let expired = try snapshot(state: "expired", remainingMs: nil)
        XCTAssertEqual(ForcedPaywallReason.resolve(isPremium: false, snapshot: expired), .subscribe)
    }
}
