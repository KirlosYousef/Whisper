//
//  RecordingView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import SwiftUI
import SwiftData
import UIKit

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: RecordingViewModel
    @State private var qaRecording: Recording? = nil
    @State private var qaQuestion: String = ""
    @State private var qaAnswer: String? = nil
    @State private var qaLoading: Bool = false
    @State private var showCleanupConfirmation: Bool = false
    @State private var showCopyAlert: Bool = false
    @State private var copyAlertMessage: String = ""
    @State private var extractingRecordingId: UUID? = nil
    
    init(viewModel: RecordingViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                recordButton
                errorMessageView
                interruptionView
                networkStatusView
                recordingsListView
            }
            .navigationTitle("Whisper Recorder")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            Text("Auto-detect").tag("auto")
                            Divider()
                            Text("Arabic").tag("ar")
                            Text("English").tag("en")
                            Text("French").tag("fr")
                            Text("Spanish").tag("es")
                            Text("German").tag("de")
                            Text("Chinese").tag("zh")
                            Text("Japanese").tag("ja")
                            Text("Korean").tag("ko")
                            Text("Russian").tag("ru")
                            Text("Portuguese").tag("pt")
                            Text("Italian").tag("it")
                            Text("Dutch").tag("nl")
                            Text("Turkish").tag("tr")
                            Text("Hindi").tag("hi")
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        viewModel.showClearConfirmation = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCleanupConfirmation = true
                    } label: {
                        Label("Free Space", systemImage: "externaldrive.badge.minus")
                    }
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "Search transcriptions...")
            .ignoresSafeArea(.container, edges: .bottom)
            .alert("Clear All Recordings?", isPresented: $viewModel.showClearConfirmation) {
                Button("Delete All", role: .destructive) {
                    viewModel.clearAllRecordings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all recordings and their transcriptions. This action cannot be undone.")
            }
            .alert("Remove Processed Audio?", isPresented: $showCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    viewModel.cleanupProcessedAudioFiles()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove stored per-segment audio files for completed transcripts to free up space. Transcripts will remain.")
            }
            .alert(copyAlertMessage, isPresented: $showCopyAlert) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $qaRecording) { rec in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ask a Question")
                        .font(.headline)
                    TextField("Type your question…", text: $qaQuestion)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    if qaLoading {
                        HStack {
                            ProgressView()
                            Text("Answering…")
                                .foregroundColor(.secondary)
                        }
                    } else if let answer = qaAnswer, !answer.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Answer")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(answer)
                                .font(.body)
                        }
                    }
                    HStack {
                        Button("Cancel") {
                            qaRecording = nil
                            qaQuestion = ""
                            qaAnswer = nil
                            qaLoading = false
                        }
                        Spacer()
                        Button("Ask") {
                            guard !qaQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            qaLoading = true
                            qaAnswer = nil
                            Task {
                                let answer = await viewModel.answerQuestion(for: rec, question: qaQuestion)
                                qaAnswer = answer
                                qaLoading = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .modifier(PresentationDetentsIfAvailable())
            }
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
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
    
    // MARK: - Recording Row
    private func recordingRow(recording: Recording, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(recording.title?.isEmpty == false ? recording.title! : "Record \(index + 1)")
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
                        Task {
                            extractingRecordingId = recording.id
                            let newKeywords = await viewModel.extractKeywords(for: recording)
                            extractingRecordingId = nil
                            if newKeywords.isEmpty {
                                copyAlertMessage = "No keywords found (or API not configured)"
                                showCopyAlert = true
                            } else {
                                copyAlertMessage = "Keywords extracted"
                                showCopyAlert = true
                            }
                        }
                    }) {
                        Label("Extract Keywords", systemImage: "tag")
                    }
                    
                    Button(action: {
                        qaRecording = recording
                        qaQuestion = ""
                        qaAnswer = nil
                        qaLoading = false
                    }) {
                        Label("Ask a Question", systemImage: "questionmark.bubble")
                    }
                    
                    Button(action: {
                        SummaryService.shareRecording(recording)
                    }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    
                    Menu("Export") {
                        Button {
                            let md = SummaryService.exportString(for: recording, format: .markdown)
                            UIPasteboard.general.string = md
                            copyAlertMessage = "Markdown copied to clipboard"
                            showCopyAlert = true
                        } label: {
                            Label("Copy Markdown", systemImage: "doc.on.doc")
                        }
                        Button {
                            SummaryService.shareRecording(recording, format: .markdown)
                        } label: {
                            Label("Share Markdown", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            SummaryService.shareRecording(recording, format: .text)
                        } label: {
                            Label("Share Text", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            if let keywords = recording.keywords, !keywords.isEmpty {
                                let hashtags = keywords.map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")
                                UIPasteboard.general.string = hashtags
                                copyAlertMessage = "Hashtags copied to clipboard"
                                showCopyAlert = true
                            } else {
                                copyAlertMessage = "No keywords available to export"
                                showCopyAlert = true
                            }
                        } label: {
                            Label("Copy Hashtags", systemImage: "number")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 8)
                
                Text(durationString(recording.duration))
                    .foregroundColor(.secondary)
                
                if extractingRecordingId == recording.id {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.leading, 4)
                }
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
            
            if let keywords = recording.keywords, !keywords.isEmpty {
                HStack {
                    Spacer()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(keywords, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .frame(height: 28)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
            }
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
                        Button(action: {
                            viewModel.play(segment: segment)
                        }) {
                            Text("\(segmentLabel(segment))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .underline()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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

// MARK: - WrapHStack
struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: () -> Content
    
    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }
    
    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            _Wrap(content: content(), availableWidth: availableWidth, spacing: spacing, lineSpacing: lineSpacing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - iOS 16+ presentation detents compatibility
private struct PresentationDetentsIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium])
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct _Wrap<Content: View>: View {
    let content: Content
    let availableWidth: CGFloat
    let spacing: CGFloat
    let lineSpacing: CGFloat
    
    var body: some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        
        return ZStack(alignment: .topLeading) {
            content
                .fixedSize()
                .alignmentGuide(.leading) { d in
                    if (abs(width - d.width) > availableWidth) {
                        width = 0
                        height -= d.height + lineSpacing
                    }
                    let result = width
                    if content is EmptyView == false {
                        width -= d.width + spacing
                    }
                    return result
                }
                .alignmentGuide(.top) { _ in
                    let result = height
                    return result
                }
        }
    }
}

#Preview {
    let container = try! ModelContainer(for: Recording.self)
    let context = ModelContext(container)
    let vm = RecordingViewModel(modelContext: context)
    return RecordingView(viewModel: vm)
}
