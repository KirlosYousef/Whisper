//
//  SpeakerDiarizationTests.swift
//  WhisperTests
//

import XCTest
import SwiftData
@testable import Revera_AI

final class SpeakerDiarizationTests: XCTestCase {
    var modelContext: ModelContext!
    var viewModel: RecordingViewModel!
    private var originalIdentifySpeakers: Bool?

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Recording.self, TranscriptionSegment.self, configurations: config)
        modelContext = ModelContext(container)
        originalIdentifySpeakers = UserDefaults.standard.object(forKey: "identifySpeakers") as? Bool
        UserDefaults.standard.set(true, forKey: "identifySpeakers")
        viewModel = RecordingViewModel(modelContext: modelContext)
    }

    override func tearDownWithError() throws {
        if let originalIdentifySpeakers {
            UserDefaults.standard.set(originalIdentifySpeakers, forKey: "identifySpeakers")
        } else {
            UserDefaults.standard.removeObject(forKey: "identifySpeakers")
        }
        viewModel = nil
        modelContext = nil
    }

    func testLegacyFullTranscriptJoinsWithSpaces() throws {
        let recording = insertRecording()
        let first = TranscriptionSegment(text: "Hello there", status: "completed", timestamp: 0, recording: recording)
        let second = TranscriptionSegment(text: "How are you", status: "completed", timestamp: 4, recording: recording)
        modelContext.insert(first)
        modelContext.insert(second)
        try modelContext.save()

        XCTAssertEqual(recording.fullTranscript, "Hello there How are you")
        XCTAssertFalse(recording.hasSpeakerLabels)
    }

    func testAttributedTranscriptWhenSpeakerKeysExist() throws {
        let recording = insertRecording()
        attachTurn(to: recording, key: "A", start: 0, end: 4, text: "Let’s ship speakers after the recording.")
        attachTurn(to: recording, key: "B", start: 4.2, end: 8, text: "Agreed.")
        try modelContext.save()

        XCTAssertTrue(recording.hasSpeakerLabels)
        XCTAssertEqual(
            recording.fullTranscript,
            "Speaker 1: Let’s ship speakers after the recording.\n\nSpeaker 2: Agreed."
        )
    }

    func testDisplayNameMappingAndEmptyRevert() throws {
        let recording = insertRecording()
        attachTurn(to: recording, key: "A", start: 0, end: 2, text: "Hi")
        attachTurn(to: recording, key: "B", start: 2, end: 4, text: "Hello")
        try modelContext.save()

        XCTAssertEqual(recording.displayName(for: "A"), "Speaker 1")
        XCTAssertEqual(recording.displayName(for: "B"), "Speaker 2")

        recording.setDisplayName("Kirlos", for: "A")
        recording.setDisplayName("Sara", for: "B")
        recording.speakerStatus = .completed
        recording.speakerCount = 2
        XCTAssertEqual(recording.displayName(for: "A"), "Kirlos")
        XCTAssertEqual(recording.displayName(for: "B"), "Sara")
        XCTAssertEqual(recording.speakerListSubtitle, "Kirlos, Sara")

        recording.setDisplayName("   ", for: "A")
        XCTAssertEqual(recording.displayName(for: "A"), "Speaker 1")
        XCTAssertEqual(recording.displayName(for: "B"), "Sara")
    }

    func testAnyNumberOfSpeakersGetsGenericLabels() throws {
        let recording = insertRecording()
        attachTurn(to: recording, key: "A", start: 0, end: 1, text: "One")
        attachTurn(to: recording, key: "B", start: 1, end: 2, text: "Two")
        attachTurn(to: recording, key: "C", start: 2, end: 3, text: "Three")
        attachTurn(to: recording, key: "D", start: 3, end: 4, text: "Four")
        recording.speakerStatus = .completed
        recording.speakerCount = 4
        try modelContext.save()

        XCTAssertEqual(recording.displayName(for: "A"), "Speaker 1")
        XCTAssertEqual(recording.displayName(for: "B"), "Speaker 2")
        XCTAssertEqual(recording.displayName(for: "C"), "Speaker 3")
        XCTAssertEqual(recording.displayName(for: "D"), "Speaker 4")
        XCTAssertEqual(recording.speakerListSubtitle, "4 speakers")
        XCTAssertTrue(recording.fullTranscript.contains("Speaker 3: Three"))
        XCTAssertTrue(recording.fullTranscript.contains("Speaker 4: Four"))
    }

    func testBuildingSpeakerTranscriptWhilePendingOrProcessing() throws {
        let recording = insertRecording()
        recording.speakerStatus = .pending
        let unlabeled = TranscriptionSegment(text: "Unlabeled placeholder", status: "completed", timestamp: 0, recording: recording)
        modelContext.insert(unlabeled)
        try modelContext.save()

        XCTAssertTrue(viewModel.isBuildingSpeakerTranscript(for: recording))
        XCTAssertFalse(viewModel.usesSpeakerTurnDisplay(for: recording))

        recording.speakerStatus = .processing
        XCTAssertTrue(viewModel.isBuildingSpeakerTranscript(for: recording))

        attachTurn(to: recording, key: "A", start: 0, end: 1, text: "One")
        attachTurn(to: recording, key: "B", start: 1, end: 2, text: "Two")
        attachTurn(to: recording, key: "C", start: 2, end: 3, text: "Three")
        recording.speakerStatus = .completed
        recording.speakerCount = 3
        try modelContext.save()

        XCTAssertFalse(viewModel.isBuildingSpeakerTranscript(for: recording))
        XCTAssertTrue(viewModel.usesSpeakerTurnDisplay(for: recording))
    }

    func testMergeAdjacentSameSpeakerTurns() {
        let turns = [
            DiarizedTurn(speakerKey: "A", start: 0, end: 1.0, text: "Hello"),
            DiarizedTurn(speakerKey: "A", start: 1.2, end: 2.0, text: "there"),
            DiarizedTurn(speakerKey: "B", start: 2.5, end: 3.5, text: "Hi"),
            DiarizedTurn(speakerKey: "A", start: 3.6, end: 4.5, text: "Again")
        ]
        let merged = TranscriptionService.mergeAdjacentTurns(turns, gap: 0.4)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].text, "Hello there")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 2.0)
        XCTAssertEqual(merged[1].speakerKey, "B")
        XCTAssertEqual(merged[2].text, "Again")
    }

    func testDoesNotMergeDifferentSpeakers() {
        let turns = [
            DiarizedTurn(speakerKey: "A", start: 0, end: 1.0, text: "Hello"),
            DiarizedTurn(speakerKey: "B", start: 1.1, end: 2.0, text: "Hi")
        ]
        let merged = TranscriptionService.mergeAdjacentTurns(turns, gap: 0.4)
        XCTAssertEqual(merged.count, 2)
    }

    func testParseDiarizedJSONFixture() throws {
        let data = Self.fixtureJSON.data(using: .utf8)!
        let parsed = try TranscriptionService.parseDiarizedJSON(data)
        XCTAssertEqual(parsed.duration, 8)
        XCTAssertEqual(parsed.turns.count, 3)
        XCTAssertEqual(parsed.turns[0].speakerKey, "A")
        XCTAssertEqual(parsed.turns[1].speakerKey, "B")
        XCTAssertEqual(parsed.turns[2].speakerKey, "A")
        XCTAssertEqual(parsed.turns[0].text, "Let’s ship speakers after the recording.")

        let merged = TranscriptionService.mergeAdjacentTurns(parsed.turns)
        XCTAssertEqual(merged.count, 3)
    }

    func testIdentifySpeakersOffSkipsWithoutNetwork() throws {
        UserDefaults.standard.set(false, forKey: "identifySpeakers")
        let recording = insertRecording()
        recording.speakerStatus = .pending
        let segment = TranscriptionSegment(text: "Existing transcript", status: "completed", timestamp: 0, recording: recording)
        modelContext.insert(segment)
        try modelContext.save()

        viewModel.identifySpeakersIfNeeded(for: recording)

        XCTAssertEqual(recording.speakerStatus, .skipped)
        XCTAssertEqual(recording.fullTranscript, "Existing transcript")
    }

    func testExportMarkdownIncludesSpeakerNames() throws {
        let recording = insertRecording()
        recording.title = "Standup"
        attachTurn(to: recording, key: "A", start: 0, end: 12, text: "Let’s ship speakers after the recording.")
        attachTurn(to: recording, key: "B", start: 12, end: 20, text: "Agreed.")
        recording.setDisplayName("Kirlos", for: "A")
        recording.setDisplayName("Sara", for: "B")
        try modelContext.save()

        let markdown = SummaryService.exportString(for: recording, format: .markdown)
        XCTAssertTrue(markdown.contains("**Kirlos** (0:00–0:12)"))
        XCTAssertTrue(markdown.contains("Let’s ship speakers after the recording."))
        XCTAssertTrue(markdown.contains("**Sara** (0:12–0:20)"))
        XCTAssertTrue(markdown.contains("Agreed."))
    }

    func testSearchMatchesSpeakerDisplayNames() throws {
        let recording = insertRecording()
        attachTurn(to: recording, key: "A", start: 0, end: 2, text: "Hello")
        recording.setDisplayName("Kirlos", for: "A")
        try modelContext.save()
        viewModel.fetchRecordings()
        viewModel.searchText = "Kirlos"
        XCTAssertEqual(viewModel.filteredRecordings.count, 1)
        XCTAssertEqual(viewModel.filteredRecordings.first?.id, recording.id)
    }

    private func insertRecording() -> Recording {
        let recording = Recording(duration: 20, filePath: "/tmp/missing.wav")
        modelContext.insert(recording)
        return recording
    }

    private func attachTurn(to recording: Recording, key: String, start: TimeInterval, end: TimeInterval, text: String) {
        let segment = TranscriptionSegment(
            text: text,
            status: "completed",
            timestamp: start,
            filePath: recording.filePath,
            speakerKey: key,
            startTime: start,
            endTime: end,
            sessionFilePath: recording.filePath,
            recording: recording
        )
        modelContext.insert(segment)
    }

    private static let fixtureJSON = """
    {
      "duration": 8.0,
      "text": "Let’s ship speakers after the recording. Agreed. One more thing.",
      "segments": [
        { "id": "1", "speaker": "A", "start": 0.0, "end": 4.2, "text": "Let’s ship speakers after the recording." },
        { "id": "2", "speaker": "B", "start": 4.2, "end": 6.0, "text": "Agreed." },
        { "id": "3", "speaker": "A", "start": 6.1, "end": 8.0, "text": "One more thing." },
        { "id": "4", "speaker": "A", "start": 8.0, "end": 8.2, "text": "   " }
      ]
    }
    """
}
