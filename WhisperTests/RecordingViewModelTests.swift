//
//  RecordingViewModelTests.swift
//  WhisperTests
//
//  Created by Kirlos Yousef on 06/07/2025.
//

import XCTest
import SwiftData
@testable import Revera_AI

final class RecordingViewModelTests: XCTestCase {
    var viewModel: RecordingViewModel!
    var modelContext: ModelContext!
    
    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Recording.self, TranscriptionSegment.self, configurations: config)
        modelContext = ModelContext(container)
        viewModel = RecordingViewModel(modelContext: modelContext)
    }
    
    override func tearDownWithError() throws {
        viewModel = nil
        modelContext = nil
    }
    
    func testInitialState() throws {
        XCTAssertFalse(viewModel.isRecording)
        XCTAssertFalse(viewModel.isStartingRecording)
        XCTAssertFalse(viewModel.isPreparingRealtime)
        XCTAssertFalse(viewModel.isFinishingRealtime)
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertTrue(viewModel.recordings.isEmpty)
        XCTAssertFalse(viewModel.permissionDenied)
        XCTAssertFalse(viewModel.showPermissionAlert)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.audioLevel, 0.0)
        XCTAssertTrue(viewModel.isOnline)
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertTrue(viewModel.searchText.isEmpty)
    }
    
    func testUsageLockedSegmentMakesHasUsageLockedTranscriptionsTrue() throws {
        let recording = Recording(createdAt: Date(), duration: 60.0, filePath: "/locked")
        let segment = TranscriptionSegment(text: "", status: "locked", timestamp: 0, filePath: "/locked/a.wav", recording: recording)
        modelContext.insert(recording)
        modelContext.insert(segment)
        try modelContext.save()

        viewModel.fetchRecordings()

        XCTAssertTrue(viewModel.hasUsageLockedTranscriptions)
    }

    func testCompletedSegmentDoesNotMakeHasUsageLockedTranscriptionsTrue() throws {
        let recording = Recording(createdAt: Date(), duration: 60.0, filePath: "/completed")
        let segment = TranscriptionSegment(text: "Done", status: "completed", timestamp: 0, filePath: "/completed/a.wav", recording: recording)
        modelContext.insert(recording)
        modelContext.insert(segment)
        try modelContext.save()

        viewModel.fetchRecordings()

        XCTAssertFalse(viewModel.hasUsageLockedTranscriptions)
    }

    /// iOS moves the app's data folder on reinstall, so a saved absolute path can point at the old folder.
    func testRepairFindsSavedAudioAfterTheAppFolderMoved() throws {
        let docs = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let dir = docs.appendingPathComponent("Segments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).wav"
        let actual = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: 2048).write(to: actual)
        defer { try? FileManager.default.removeItem(at: actual) }
        let stalePath = "/var/mobile/Containers/Data/Application/OLD-CONTAINER/Documents/Segments/\(name)"

        let recording = Recording(createdAt: Date(), duration: 20, filePath: stalePath)
        let segment = TranscriptionSegment(text: "", status: "locked", timestamp: 0, filePath: stalePath, recording: recording)
        modelContext.insert(recording)
        modelContext.insert(segment)
        try modelContext.save()

        viewModel.repairStoredAudioPaths()

        XCTAssertEqual(segment.filePath, actual.path)
        XCTAssertEqual(recording.filePath, actual.path)
        XCTAssertEqual(segment.status, "locked")
        XCTAssertTrue(viewModel.hasUsageLockedTranscriptions)
    }

    func testRepairReleasesWaitingSegmentsWhoseAudioIsGone() throws {
        let missing = "/nowhere/\(UUID().uuidString).wav"
        let recording = Recording(createdAt: Date(), duration: 40, filePath: missing)
        let empty = TranscriptionSegment(text: "", status: "locked", timestamp: 0, filePath: missing, recording: recording)
        let withText = TranscriptionSegment(text: "Kept", status: "locked", timestamp: 20, filePath: "/nowhere/b.wav", recording: recording)
        modelContext.insert(recording)
        modelContext.insert(empty)
        modelContext.insert(withText)
        try modelContext.save()

        viewModel.repairStoredAudioPaths()

        XCTAssertEqual(empty.status, "failed")
        XCTAssertEqual(withText.status, "completed")
        XCTAssertFalse(viewModel.hasUsageLockedTranscriptions)
    }

    func testFilteredRecordingsWithEmptySearch() throws {
        // Given
        let recording1 = Recording(createdAt: Date(), duration: 60.0, filePath: "/path1")
        let recording2 = Recording(createdAt: Date().addingTimeInterval(-3600), duration: 120.0, filePath: "/path2")
        modelContext.insert(recording1)
        modelContext.insert(recording2)
        try modelContext.save()
        
        // When
        viewModel.fetchRecordings()
        
        // Then
        XCTAssertEqual(viewModel.filteredRecordings.count, 2)
    }
    
    func testFilteredRecordingsWithSearch() throws {
        // Given
        let recording1 = Recording(createdAt: Date(), duration: 60.0, filePath: "/path1")
        let recording2 = Recording(createdAt: Date().addingTimeInterval(-3600), duration: 120.0, filePath: "/path2")
        modelContext.insert(recording1)
        modelContext.insert(recording2)
        
        let segment1 = TranscriptionSegment(text: "Hello world", status: "completed", timestamp: 0.0)
        segment1.recording = recording1
        modelContext.insert(segment1)
        
        let segment2 = TranscriptionSegment(text: "Goodbye", status: "completed", timestamp: 0.0)
        segment2.recording = recording2
        modelContext.insert(segment2)
        
        try modelContext.save()
        
        // When
        viewModel.searchText = "Hello"
        viewModel.fetchRecordings()
        
        // Then
        XCTAssertEqual(viewModel.filteredRecordings.count, 1)
        XCTAssertEqual(viewModel.filteredRecordings.first?.id, recording1.id)
    }
    
    func testAudioLevelUpdate() throws {
        // Given
        let expectedLevel: Float = 0.75
        let exp = expectation(description: "audio level")
        
        // When
        viewModel.audioService(viewModel.audioService, didUpdateAudioLevel: expectedLevel)
        
        // Then
        DispatchQueue.main.async {
            XCTAssertEqual(self.viewModel.audioLevel, expectedLevel)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testInterruptionHandling() throws {
        // Given
        let interruptionReason = "Phone call"
        let exp = expectation(description: "interrupt")
        
        // When
        viewModel.audioService(viewModel.audioService, didInterruptRecording: interruptionReason)
        
        // Then
        DispatchQueue.main.async {
            XCTAssertTrue(self.viewModel.isInterrupted)
            XCTAssertEqual(self.viewModel.interruptionMessage, interruptionReason)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testResumeRecording() throws {
        // Given
        viewModel.isInterrupted = true
        viewModel.interruptionMessage = "Test interruption"
        let exp = expectation(description: "resume")
        
        // When
        viewModel.audioService(viewModel.audioService, didResumeRecording: true)
        
        // Then
        DispatchQueue.main.async {
            XCTAssertFalse(self.viewModel.isInterrupted)
            XCTAssertNil(self.viewModel.interruptionMessage)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testRefreshRecordings() throws {
        // Given
        let recording = Recording(createdAt: Date(), duration: 60.0, filePath: "/test/path")
        modelContext.insert(recording)
        try modelContext.save()
        
        // When
        viewModel.refreshRecordings()
        
        // Then
        XCTAssertTrue(viewModel.isRefreshing)
        
        // Wait for refresh to complete
        let expectation = XCTestExpectation(description: "Refresh completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            XCTAssertFalse(self.viewModel.isRefreshing)
            XCTAssertEqual(self.viewModel.recordings.count, 1)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
    
    func testNetworkStatusCheck() throws {
        // When
        viewModel.checkNetworkStatus()
        
        // Then
        // Note: This is a placeholder implementation, so we just verify it doesn't crash
        XCTAssertTrue(viewModel.isOnline)
    }
    
    func testErrorHandling() throws {
        // Given
        let errorMessage = "Test error message"
        
        // When
        viewModel.errorMessage = errorMessage
        
        // Then
        XCTAssertEqual(viewModel.errorMessage, errorMessage)
        
        // When clearing error
        viewModel.errorMessage = nil
        
        // Then
        XCTAssertNil(viewModel.errorMessage)
    }
    
    func testPermissionHandling() throws {
        // Given
        viewModel.permissionDenied = false
        viewModel.showPermissionAlert = false
        
        // When
        viewModel.permissionDenied = true
        viewModel.showPermissionAlert = true
        
        // Then
        XCTAssertTrue(viewModel.permissionDenied)
        XCTAssertTrue(viewModel.showPermissionAlert)
    }
} 
