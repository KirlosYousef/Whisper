import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: RecordingViewModel
    
    init() {
        let context = try! ModelContext(
            ModelContainer(for: Recording.self)
        )
        _viewModel = StateObject(wrappedValue: RecordingViewModel(modelContext: context))
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()
                recordButton
                errorMessageView
                interruptionView
                networkStatusView
                recordingsListView
            }
            .navigationTitle("Whisper Recorder")
            .searchable(text: $viewModel.searchText, prompt: "Search transcriptions...")
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear {
            viewModel.fetchRecordings()
            viewModel.checkNetworkStatus()
        }
    }
    
    // MARK: - Record Button
    private var recordButton: some View {
                        Button(action: {
                    if viewModel.isRecording {
                        viewModel.stopRecording()
                    } else {
                        viewModel.requestPermission()
                        if !viewModel.permissionDenied {
                            viewModel.startRecording()
                        }
                    }
                }) {
            ZStack {
                // Audio level responsive ring when recording
                if viewModel.isRecording {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 8)
                        .frame(width: 110, height: 110)
                        .scaleEffect(CGFloat(1.0 + (viewModel.audioLevel * 0.3)))
                        .opacity(Double(0.3 + (viewModel.audioLevel * 0.7)))
                        .animation(.easeOut(duration: 0.1), value: viewModel.audioLevel)
                }
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 80, height: 80)
                    .scaleEffect(viewModel.isRecording ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
                Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 36, weight: .bold))
                    .scaleEffect(viewModel.isRecording ? 1.2 : 1.0)
                    .animation(.spring(), value: viewModel.isRecording)
            }
        }
        .padding()
        .accessibilityLabel(viewModel.isRecording ? "Stop Recording" : "Start Recording")
        .accessibilityHint(viewModel.isRecording ? "Double tap to stop recording" : "Double tap to start recording")
        .accessibilityValue(viewModel.isRecording ? "Recording in progress" : "Ready to record")
        .alert(isPresented: $viewModel.showPermissionAlert) {
            Alert(
                title: Text("Microphone Access Denied"),
                message: Text("Please enable microphone access in Settings to record audio."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    // MARK: - Error Message
    private var errorMessageView: some View {
        Group {
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Interruption View
    private var interruptionView: some View {
        Group {
            if viewModel.isInterrupted {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Recording Interrupted")
                            .font(.headline)
                            .foregroundColor(.orange)
                    }
                    
                    if let message = viewModel.interruptionMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    Text("Recording will resume automatically when possible")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Network Status View
    private var networkStatusView: some View {
        Group {
            if !viewModel.isOnline {
                HStack {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.orange)
                    Text("Offline Mode")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    Spacer()
                    Text("Transcriptions will be queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Recordings List
    private var recordingsListView: some View {
        List {
            ForEach(groupedRecordings.keys.sorted(by: >), id: \.self) { date in
                Section(header: Text(sectionHeader(for: date))) {
                    ForEach(Array((groupedRecordings[date] ?? []).enumerated()), id: \.element.id) { idx, recording in
                        recordingRow(recording: recording, index: idx)
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .refreshable {
            viewModel.refreshRecordings()
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
    
    // MARK: - Recording Row
    private func recordingRow(recording: Recording, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Record \(index + 1)")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                
                Menu {
                    Button(action: {
                        Task {
                            let (summary, todos) = await SummaryService.generateSummary(for: recording.fullTranscript)
                            recording.summary = summary
                            recording.todoList = todos
                            try? modelContext.save()
                        }
                    }) {
                        Label("Generate Summary", systemImage: "text.badge.star")
                    }
                    
                    Button(action: {
                        SummaryService.shareRecording(recording)
                    }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 8)
                
                Text(durationString(recording.duration))
                    .foregroundColor(.secondary)
            }
            
            if let summary = recording.summary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            if let todos = recording.todoList, !todos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action Items")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    ForEach(todos, id: \.self) { todo in
                        HStack(alignment: .top) {
                            Text("•")
                            Text(todo)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            
            Divider()
            transcriptionSegmentsView(for: recording)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, 8)
    }
    
    // MARK: - Transcription Segments
    private func transcriptionSegmentsView(for recording: Recording) -> some View {
        Group {
            if let segments = fetchSegments(for: recording), !segments.isEmpty {
                ForEach(segments, id: \.id) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(segmentLabel(segment))]")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        segmentStatusView(segment: segment)
                    }
                }
            }
        }
    }
    
    // MARK: - Segment Status
    private func segmentStatusView(segment: TranscriptionSegment) -> some View {
        Group {
            if segment.status == "completed" {
                Text(segment.text)
                    .font(.caption)
                    .foregroundColor(.primary)
            } else if segment.status == "pending" || segment.status == "processing" {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Processing…")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            } else if segment.status == "failed" {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text("Failed")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            } else if segment.status == "queued" {
                HStack {
                    Image(systemName: "icloud.slash")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Queued (offline)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private var groupedRecordings: [Date: [Recording]] {
        Dictionary(grouping: viewModel.filteredRecordings) { rec in
            Calendar.current.startOfDay(for: rec.createdAt)
        }
    }
    
    private func fetchSegments(for recording: Recording) -> [TranscriptionSegment]? {
        guard let allSegments = try? modelContext.fetch(FetchDescriptor<TranscriptionSegment>()) else { return nil }
        return allSegments.filter { $0.recording?.id == recording.id }
    }
    
    private func sectionHeader(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }
    
    private func durationString(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    private func segmentLabel(_ segment: TranscriptionSegment) -> String {
        let mins = Int(segment.timestamp) / 60
        let secs = Int(segment.timestamp) % 60
        return String(format: "[%02d:%02d]", mins, secs)
    }
}

#Preview {
    RecordingView()
}
