import XCTest
@testable import Revera_AI

final class TranscriptionErrorMappingTests: XCTestCase {
    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    func testSuccessStatusMapsToNil() {
        XCTAssertNil(TranscriptionService.responseError(forStatus: 200, body: json(#"{"text":"hi"}"#)))
    }

    func testSessionExpiredMapsToRetryableServerError() {
        let error = TranscriptionService.responseError(forStatus: 401, body: json(#"{"error":"expired","code":"session_expired"}"#))
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.serverError)
    }

    func testTrialExhaustedMapsToUsageError() {
        let error = TranscriptionService.responseError(forStatus: 402, body: json(#"{"error":"done","code":"trial_exhausted"}"#))
        XCTAssertEqual(error as? UsageAccessError, UsageAccessError.trialExhausted)
    }

    func testSubscriptionInactiveMapsToNoVerifiedSubscription() {
        let error = TranscriptionService.responseError(forStatus: 403, body: json(#"{"error":"inactive","code":"subscription_inactive"}"#))
        XCTAssertEqual(error as? UsageAccessError, UsageAccessError.noVerifiedSubscription)
    }

    func testOperationPendingIsRetryable() {
        let error = TranscriptionService.responseError(forStatus: 409, body: json(#"{"error":"pending","code":"operation_pending"}"#))
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.serverError)
    }

    func testDuplicateAudioIsAlreadyProcessed() {
        let error = TranscriptionService.responseError(forStatus: 409, body: json(#"{"error":"dup","code":"duplicate_audio"}"#))
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.alreadyProcessed)
    }

    func testUpdateRequiredMapsToUsageError() {
        let error = TranscriptionService.responseError(forStatus: 426, body: nil)
        XCTAssertEqual(error as? UsageAccessError, UsageAccessError.updateRequired)
    }

    func testRateLimitMapsToRateLimited() {
        let error = TranscriptionService.responseError(forStatus: 429, body: nil)
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.rateLimited)
    }

    func testServerErrorMapsToServerError() {
        let error = TranscriptionService.responseError(forStatus: 500, body: nil)
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.serverError)
    }

    func testTemporarilyUnavailableMapsToServerErrorNotVerification() {
        let error = TranscriptionService.responseError(forStatus: 503, body: json(#"{"error":"busy","code":"temporarily_unavailable"}"#))
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.serverError)
    }

    func testOtherClientErrorKeepsBodyMessage() {
        let error = TranscriptionService.responseError(forStatus: 400, body: json(#"{"error":"bad"}"#))
        XCTAssertEqual((error as? NSError)?.localizedDescription, "bad")
    }

    func testOtherClientErrorWithoutMessageIsInvalidResponse() {
        let error = TranscriptionService.responseError(forStatus: 400, body: nil)
        XCTAssertEqual(error as? TranscriptionError, TranscriptionError.invalidResponse)
    }
}
