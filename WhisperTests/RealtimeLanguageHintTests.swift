import XCTest
@testable import Revera_AI

final class RealtimeLanguageHintTests: XCTestCase {
    func testAutoModeSendsNoHintSoTheModelDetectsEachLanguage() {
        XCTAssertEqual(Languages.realtimeHints(selected: "auto", stored: "auto"), [])
        XCTAssertEqual(Languages.realtimeHints(selected: "AUTO", stored: ""), [])
    }

    func testExplicitSelectionIsSentAsSingleHint() {
        XCTAssertEqual(Languages.realtimeHints(selected: "ar", stored: "auto"), ["ar"])
        XCTAssertEqual(Languages.realtimeHints(selected: " EN ", stored: "ar"), ["en"])
    }

    func testStoredLanguageUsedWhenSelectionIsAuto() {
        XCTAssertEqual(Languages.realtimeHints(selected: "auto", stored: "de"), ["de"])
    }
}
