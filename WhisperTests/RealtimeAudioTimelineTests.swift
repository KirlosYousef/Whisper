import XCTest
@testable import Revera_AI

final class RealtimeAudioTimelineTests: XCTestCase {
    private let bytesPerMs = RealtimeAudioTimeline.bytesPerMillisecond

    private func bytes(_ count: Int, value: UInt8 = 1) -> Data {
        Data(repeating: value, count: count)
    }

    func testOddChunkSizesProduceWholeMillisecondAppends() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        timeline.enqueue(bytes(100))
        timeline.enqueue(bytes(9_601))
        timeline.enqueue(bytes(47))

        let appends = timeline.takeAppends(maxBytes: nil, flushRemainder: false)

        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(appends[0].startMs, 0)
        XCTAssertEqual(appends[0].data.count % bytesPerMs, 0)
        XCTAssertEqual(appends[0].data.count, 9_744)
        XCTAssertEqual(timeline.bufferedByteCount, 4)
    }

    func testStartMsIsContinuousAcrossManyEnqueues() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 250)
        let sizes = [100, 9_601, 47, 960, 1, 9_600, 4_801, 48]
        var appends: [RealtimeAudioTimeline.Append] = []

        for index in 0..<60 {
            timeline.enqueue(bytes(sizes[index % sizes.count]))
            appends += timeline.takeAppends(maxBytes: 9_600, flushRemainder: false)
        }

        XCTAssertFalse(appends.isEmpty)
        XCTAssertEqual(appends.first?.startMs, 250)
        for (previous, next) in zip(appends, appends.dropFirst()) {
            XCTAssertEqual(previous.data.count % bytesPerMs, 0)
            XCTAssertEqual(next.startMs, previous.startMs + previous.data.count / bytesPerMs)
        }
    }

    func testMaxBytesSplitsIntoChunks() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        timeline.enqueue(bytes(9_600 * 2 + 48 * 3))

        let appends = timeline.takeAppends(maxBytes: 9_600, flushRemainder: false)

        XCTAssertEqual(appends.map { $0.data.count }, [9_600, 9_600, 144])
        XCTAssertEqual(appends.map { $0.startMs }, [0, 200, 400])
        XCTAssertEqual(timeline.bufferedByteCount, 0)
    }

    func testRemainderIsRetainedThenFlushedWithPadding() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        timeline.enqueue(bytes(40))

        XCTAssertEqual(timeline.takeAppends(maxBytes: 9_600, flushRemainder: false), [])
        XCTAssertEqual(timeline.bufferedByteCount, 40)

        let flushed = timeline.takeAppends(maxBytes: 9_600, flushRemainder: true)
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].startMs, 0)
        XCTAssertEqual(flushed[0].data.count, bytesPerMs)
        XCTAssertEqual(timeline.bufferedByteCount, 0)

        timeline.enqueue(bytes(bytesPerMs))
        let next = timeline.takeAppends(maxBytes: nil, flushRemainder: false)
        XCTAssertEqual(next.first?.startMs, 1)
    }

    func testDataBytesArePreservedInOrder() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        let first = bytes(bytesPerMs, value: 1)
        let second = bytes(bytesPerMs, value: 2)
        timeline.enqueue(first)
        timeline.enqueue(second)

        let appends = timeline.takeAppends(maxBytes: nil, flushRemainder: false)

        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(appends[0].data, first + second)
    }

    func testDropOldestDropsWholeMillisecondsAndAdvancesStream() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        timeline.enqueue(bytes(1_000))

        timeline.dropOldest(toFit: 500)

        // 500 bytes over the cap rounds up to 11 ms (528 bytes) to stay whole-millisecond aligned.
        XCTAssertEqual(timeline.bufferedByteCount, 472)
        let appends = timeline.takeAppends(maxBytes: nil, flushRemainder: false)
        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(appends[0].startMs, 11)
        XCTAssertEqual(appends[0].data.count, 432)
        XCTAssertEqual(timeline.bufferedByteCount, 40)
    }

    func testDropOldestIsNoOpUnderCap() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        timeline.enqueue(bytes(480))

        timeline.dropOldest(toFit: 480)

        XCTAssertEqual(timeline.bufferedByteCount, 480)
    }

    func testResetRestartsAtOffset() {
        var timeline = RealtimeAudioTimeline(startOffsetMs: 0)
        timeline.enqueue(bytes(500))

        timeline.reset(startOffsetMs: 10)

        XCTAssertEqual(timeline.bufferedByteCount, 0)
        timeline.enqueue(bytes(bytesPerMs))
        XCTAssertEqual(timeline.takeAppends(maxBytes: nil, flushRemainder: false).first?.startMs, 10)
    }
}
