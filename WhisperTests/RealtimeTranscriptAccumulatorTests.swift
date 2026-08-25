import Testing
@testable import Revera_AI

struct RealtimeTranscriptAccumulatorTests {
    @Test func combinesCumulativeAndIncrementalRealtimeUpdates() {
        var accumulator = RealtimeTranscriptAccumulator()

        accumulator.mergeDelta(itemID: "first", text: "Hello")
        accumulator.mergeDelta(itemID: "first", text: "Hello there")
        accumulator.mergeDelta(itemID: "first", text: ", Kirlos")

        #expect(accumulator.transcript == "Hello there, Kirlos")
        #expect(accumulator.words == ["Hello", "there,", "Kirlos"])
    }

    @Test func finalItemsKeepTheirRealtimeOrder() {
        var accumulator = RealtimeTranscriptAccumulator()

        accumulator.mergeDelta(itemID: "first", text: "The first thought")
        accumulator.mergeDelta(itemID: "second", text: "and the second")
        accumulator.finalize(itemID: "first", transcript: "The refined first thought")

        #expect(accumulator.transcript == "The refined first thought and the second")
    }

    @Test func replacingWithPostProcessedTextBecomesTheSingleSourceOfTruth() {
        var accumulator = RealtimeTranscriptAccumulator()
        accumulator.mergeDelta(itemID: "live", text: "Original live text")

        accumulator.replace(with: "Final translated text")

        #expect(accumulator.transcript == "Final translated text")
        #expect(accumulator.words == ["Final", "translated", "text"])
    }
}
