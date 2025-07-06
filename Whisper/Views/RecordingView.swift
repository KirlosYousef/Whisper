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
                // Record Button (no shadow)
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
                        Circle()
                            .fill(viewModel.isRecording ? Color.red : Color.green)
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
                .alert(isPresented: $viewModel.showPermissionAlert) {
                    Alert(title: Text("Microphone Access Denied"), message: Text("Please enable microphone access in Settings to record audio."), dismissButton: .default(Text("OK")))
                }
                
                // Error Message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Recordings List with Transcription Segments
                List {
                    ForEach(groupedRecordings.keys.sorted(by: >), id: \.self) { date in
                        Section(header: Text(sectionHeader(for: date))) {
                            ForEach(groupedRecordings[date] ?? []) { recording in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(recording.createdAt, style: .time)
                                        Spacer()
                                        Text(durationString(recording.duration))
                                            .foregroundColor(.secondary)
                                    }
                                    // Show transcription segments for this recording
                                    if let segments = fetchSegments(for: recording), !segments.isEmpty {
                                        ForEach(segments, id: \.id) { segment in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text(segmentLabel(segment))
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                                if segment.status == "completed" {
                                                    Text(segment.text)
                                                        .font(.caption)
                                                } else if segment.status == "pending" {
                                                    ProgressView()
                                                        .scaleEffect(0.7)
                                                } else if segment.status == "failed" {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .foregroundColor(.red)
                                                        .font(.caption)
                                                    Text("Failed")
                                                        .font(.caption)
                                                        .foregroundColor(.red)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                Spacer()
            }
            .navigationTitle("Whisper Recorder")
        }
        .onAppear {
            viewModel.fetchRecordings()
        }
    }
    
    private var groupedRecordings: [Date: [Recording]] {
        Dictionary(grouping: viewModel.recordings) { rec in
            Calendar.current.startOfDay(for: rec.createdAt)
        }
    }
    
    private func fetchSegments(for recording: Recording) -> [TranscriptionSegment]? {
        // Workaround: fetch all segments and filter in-memory by recording.id
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

