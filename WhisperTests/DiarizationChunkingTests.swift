//
//  DiarizationChunkingTests.swift
//  WhisperTests
//

import XCTest
@testable import Revera_AI

final class DiarizationChunkingTests: XCTestCase {
    private func lengths(_ ranges: [DiarizationChunkRange]) -> [TimeInterval] {
        ranges.map(\.duration)
    }

    private func turn(_ key: String, _ start: TimeInterval, _ end: TimeInterval, _ text: String = "text") -> DiarizedTurn {
        DiarizedTurn(speakerKey: key, start: start, end: end, text: text)
    }

    // MARK: - Chunk planner

    func testShortRecordingIsOneChunk() {
        XCTAssertEqual(DiarizationChunkPlanner.plan(totalDuration: 30), [DiarizationChunkRange(start: 0, duration: 30)])
    }

    func testExactlyMaxDurationIsOneChunk() {
        XCTAssertEqual(DiarizationChunkPlanner.plan(totalDuration: 1200), [DiarizationChunkRange(start: 0, duration: 1200)])
    }

    func testSmallTailIsMergedIntoOneChunkWhenWithinCap() {
        let ranges = DiarizationChunkPlanner.plan(totalDuration: 1210)
        XCTAssertEqual(ranges, [DiarizationChunkRange(start: 0, duration: 1210)])
    }

    func testTailUnderMinimumMergesIntoPreviousChunk() {
        let ranges = DiarizationChunkPlanner.plan(totalDuration: 2430)
        XCTAssertEqual(ranges, [
            DiarizationChunkRange(start: 0, duration: 1200),
            DiarizationChunkRange(start: 1200, duration: 1230)
        ])
    }

    func testThreeFullChunks() {
        let ranges = DiarizationChunkPlanner.plan(totalDuration: 3600)
        XCTAssertEqual(lengths(ranges), [1200, 1200, 1200])
        XCTAssertEqual(ranges.map(\.start), [0, 1200, 2400])
    }

    func testTailAtOrAboveMinimumIsKeptAsOwnChunk() {
        let ranges = DiarizationChunkPlanner.plan(totalDuration: 2500)
        XCTAssertEqual(ranges, [
            DiarizationChunkRange(start: 0, duration: 1200),
            DiarizationChunkRange(start: 1200, duration: 1200),
            DiarizationChunkRange(start: 2400, duration: 100)
        ])
    }

    func testRangesAreContiguousCoverTheRecordingAndAreDeterministic() {
        for total in [1.0, 59.5, 1199.9, 1200.5, 1500, 2431.25, 4000, 7203] {
            let ranges = DiarizationChunkPlanner.plan(totalDuration: total)
            XCTAssertFalse(ranges.isEmpty, "total \(total)")
            XCTAssertEqual(ranges.first?.start, 0)
            XCTAssertEqual(ranges.last?.end ?? -1, total, accuracy: 0.0001)
            for pair in zip(ranges, ranges.dropFirst()) {
                XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 0.0001)
            }
            for range in ranges {
                XCTAssertLessThanOrEqual(range.duration, DiarizationChunkPlanner.maxMergedChunkDuration)
            }
            XCTAssertEqual(ranges, DiarizationChunkPlanner.plan(totalDuration: total))
        }
    }

    func testEmptyDurationProducesNoChunks() {
        XCTAssertTrue(DiarizationChunkPlanner.plan(totalDuration: 0).isEmpty)
    }

    // MARK: - Merger

    func testRemapKeepsFirstChunkLabels() {
        let turns = [turn("A", 0, 2), turn("B", 2, 4)]
        XCTAssertEqual(DiarizationChunkMerger.remap(turns: turns, chunkIndex: 0), turns)
    }

    func testRemapMapsKnownLabelsBackAndNamespacesNewLabels() {
        let turns = [
            turn("known_A", 0, 2),
            turn("C", 2, 4),
            turn("C", 4, 6),
            turn("known_B", 6, 8)
        ]
        let remapped = DiarizationChunkMerger.remap(turns: turns, chunkIndex: 2).map(\.speakerKey)
        XCTAssertEqual(remapped, ["A", "C-2", "C-2", "B"])
    }

    func testMergeShiftsOffsetsJoinsTextAndSetsDuration() {
        let first = DiarizationResult(duration: 1200, text: "Hello there.", turns: [turn("A", 0, 3, "Hello there.")])
        let second = DiarizationResult(duration: 60, text: " General Kenobi. ", turns: [turn("B", 5, 9, "General Kenobi.")])

        let merged = DiarizationChunkMerger.merge(chunks: [(offset: 0, result: first), (offset: 1200, result: second)])

        XCTAssertEqual(merged.duration, 1260)
        XCTAssertEqual(merged.text, "Hello there. General Kenobi.")
        XCTAssertEqual(merged.turns, [
            turn("A", 0, 3, "Hello there."),
            turn("B", 1205, 1209, "General Kenobi.")
        ])
    }

    func testMergeJoinsSameSpeakerTurnsAcrossBoundary() {
        let first = DiarizationResult(duration: 1200, text: "We should ship", turns: [turn("A", 1196, 1200, "We should ship")])
        let second = DiarizationResult(duration: 100, text: "it today.", turns: [turn("A", 0.2, 2, "it today.")])

        let merged = DiarizationChunkMerger.merge(chunks: [(offset: 0, result: first), (offset: 1200, result: second)])

        XCTAssertEqual(merged.turns.count, 1)
        XCTAssertEqual(merged.turns[0].speakerKey, "A")
        XCTAssertEqual(merged.turns[0].start, 1196)
        XCTAssertEqual(merged.turns[0].end, 1202, accuracy: 0.0001)
        XCTAssertEqual(merged.turns[0].text, "We should ship it today.")
    }

    func testMergeSortsTurnsByStart() {
        let first = DiarizationResult(duration: 1200, text: "", turns: [turn("A", 10, 12), turn("B", 1, 2)])
        let second = DiarizationResult(duration: 30, text: "", turns: [turn("C", 0, 1)])

        let merged = DiarizationChunkMerger.merge(chunks: [(offset: 0, result: first), (offset: 1200, result: second)])

        XCTAssertEqual(merged.turns.map(\.speakerKey), ["B", "A", "C"])
    }

    // MARK: - Reference selection

    func testPicksLongestTurnAtLeastTwoSecondsPerSpeaker() {
        let turns = [
            turn("A", 0, 1.5),
            turn("A", 10, 13),
            turn("A", 20, 26),
            turn("B", 30, 33)
        ]
        let refs = DiarizationReferenceSelector.select(from: turns)
        // Ordered by total talk time: A is 10.5 s, B is 3 s.
        XCTAssertEqual(refs, [
            DiarizationSpeakerReference(speakerKey: "A", start: 20, duration: 6),
            DiarizationSpeakerReference(speakerKey: "B", start: 30, duration: 3)
        ])
    }

    func testClipIsCappedAtTenSeconds() {
        let refs = DiarizationReferenceSelector.select(from: [turn("A", 100, 130)])
        XCTAssertEqual(refs, [DiarizationSpeakerReference(speakerKey: "A", start: 100, duration: 10)])
    }

    func testSkipsSpeakersWithoutAQualifyingTurn() {
        let refs = DiarizationReferenceSelector.select(from: [turn("A", 0, 1), turn("A", 1, 1.9)])
        XCTAssertTrue(refs.isEmpty)
    }

    func testKeepsAtMostFourSpeakersByTotalTalkTime() {
        var turns: [DiarizedTurn] = []
        // Speaker E talks the least, so only its single long turn could qualify; it must be dropped.
        let talkTimes: [(String, TimeInterval)] = [("A", 50), ("B", 40), ("C", 30), ("D", 20), ("E", 10)]
        for (index, entry) in talkTimes.enumerated() {
            let start = TimeInterval(index * 100)
            turns.append(turn(entry.0, start, start + entry.1))
        }

        let refs = DiarizationReferenceSelector.select(from: turns)

        XCTAssertEqual(refs.map(\.speakerKey), ["A", "B", "C", "D"])
    }

    func testTalkTimeRankingUsesAllTurnsNotOnlyQualifyingOnes() {
        // B has many short turns (total 12 s) but its longest is 1 s, so it is skipped.
        // A and C qualify. The four-speaker cap is not reached, so only A and C appear.
        var turns: [DiarizedTurn] = [turn("A", 0, 5), turn("C", 10, 14)]
        for index in 0..<12 {
            let start = TimeInterval(100 + index * 2)
            turns.append(turn("B", start, start + 1))
        }

        let refs = DiarizationReferenceSelector.select(from: turns)

        XCTAssertEqual(refs.map(\.speakerKey), ["A", "C"])
    }
}
