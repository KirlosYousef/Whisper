import XCTest
import SwiftData
@testable import Whisper

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
    
    func testFilteredRecordingsWithEmptySearch() throws {
        // Given
        let recording1 = Recording(createdAt: Date(), duration: 60.0, filePath: "/path1")
        let recording2 = Recording(createdAt: Date().addingTimeInterval(-3600), duration: 120.0, filePath: "/path2")
        
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
        
        let segment1 = TranscriptionSegment(text: "Hello world", status: "completed", timestamp: 0.0)
        segment1.recording = recording1
        
        let segment2 = TranscriptionSegment(text: "Goodbye", status: "completed", timestamp: 0.0)
        segment2.recording = recording2
        
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
        
        // When
        viewModel.audioService(viewModel.audioService, didUpdateAudioLevel: expectedLevel)
        
        // Then
        XCTAssertEqual(viewModel.audioLevel, expectedLevel)
    }
    
    func testInterruptionHandling() throws {
        // Given
        let interruptionReason = "Phone call"
        
        // When
        viewModel.audioService(viewModel.audioService, didInterruptRecording: interruptionReason)
        
        // Then
        XCTAssertTrue(viewModel.isInterrupted)
        XCTAssertEqual(viewModel.interruptionMessage, interruptionReason)
    }
    
    func testResumeRecording() throws {
        // Given
        viewModel.isInterrupted = true
        viewModel.interruptionMessage = "Test interruption"
        
        // When
        viewModel.audioService(viewModel.audioService, didResumeRecording: true)
        
        // Then
        XCTAssertFalse(viewModel.isInterrupted)
        XCTAssertNil(viewModel.interruptionMessage)
    }
    
    func testRefreshRecordings() throws {
        // Given
        let recording = Recording(createdAt: Date(), duration: 60.0, filePath: "/test/path")
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