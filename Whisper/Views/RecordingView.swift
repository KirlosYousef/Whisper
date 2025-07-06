import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: RecordingViewModel
    @State private var ringPulse = false
    
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
                        // Continuously animated pulsing ring when recording
                        if viewModel.isRecording {
                            Circle()
                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 8)
                                .frame(width: 110, height: 110)
                                .scaleEffect(ringPulse ? 1.18 : 0.95)
                                .opacity(ringPulse ? 0.7 : 0.3)
                                .animation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: ringPulse)
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
                .onAppear {
                    if viewModel.isRecording { ringPulse = true }
                }
                .onChange(of: viewModel.isRecording) { isRec in
                    if isRec {
                        ringPulse = true
                    } else {
                        ringPulse = false
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
                            ForEach(Array((groupedRecordings[date] ?? []).enumerated()), id: \.element.id) { idx, recording in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Record \(idx + 1)")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text(durationString(recording.duration))
                                            .foregroundColor(.secondary)
                                    }
                                    Divider()
                                    // Show transcription segments for this recording
                                    if let segments = fetchSegments(for: recording), !segments.isEmpty {
                                        ForEach(segments, id: \.id) { segment in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("[\(segmentLabel(segment))]")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                if segment.status == "completed" {
                                                    Text(segment.text)
                                                        .font(.caption)
                                                        .foregroundColor(.primary)
                                                } else if segment.status == "pending" || segment.status == "processing" {
                                                    ProgressView()
                                                        .scaleEffect(0.7)
                                                    Text("Processing…")
                                                        .font(.caption2)
                                                        .foregroundColor(.accentColor)
                                                } else if segment.status == "failed" {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .foregroundColor(.red)
                                                        .font(.caption)
                                                    Text("Failed")
                                                        .font(.caption2)
                                                        .foregroundColor(.red)
                                                } else if segment.status == "queued" {
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

