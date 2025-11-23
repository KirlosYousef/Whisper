import SwiftUI
import SwiftData

struct TranscriptDetailView: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
    @StateObject var viewModel: RecordingViewModel
    let recording: Recording
    @State private var showCopyAlert = false
    @State private var copyAlertMessage = ""
    @State private var qaRecording: Recording? = nil
    @State private var qaQuestion: String = ""
    @State private var qaAnswer: String? = nil
    @State private var qaLoading: Bool = false
	@State private var playingSegmentId: UUID? = nil
	@State private var showSummaryToast: Bool = false
    @State private var keywordsLoading: Bool = false
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                RecordingHeaderCard(title: titleText, duration: recording.duration) {
                    Menu {
                        Button {
                            Task {
                                await viewModel.generateFullSummary(for: recording)
                            }
                        } label: { Label("Generate Summary", systemImage: "text.badge.star") }
                        
                        Button {
                            Task {
                                keywordsLoading = true
                                _ = await viewModel.extractKeywords(for: recording)
                                keywordsLoading = false
                                try? modelContext.save()
                            }
                        } label: { Label("Extract Keywords", systemImage: "tag") }
                        
                        Button {
                            SummaryService.shareRecording(recording)
                        } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        
                        Button {
                            qaRecording = recording
                            qaQuestion = ""
                            qaAnswer = nil
                            qaLoading = false
                        } label: { Label("Ask a Question", systemImage: "questionmark.bubble") }
                        
                        Menu("Export") {
                            Button {
                                SummaryService.shareRecording(recording, format: .markdown)
                            } label: { Label("Share Markdown", systemImage: "square.and.arrow.up") }
                            
                            Button {
                                SummaryService.shareRecording(recording, format: .text)
                            } label: { Label("Share Text", systemImage: "square.and.arrow.up") }
                            
                            if let keywords = recording.keywords, !keywords.isEmpty {
                                let hashtags = keywords.map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")
                                ShareLink(item: hashtags) {
                                    Label("Share Hashtags", systemImage: "number")
                                }
                            } else {
                                Button {
                                    copyAlertMessage = "No keywords available to share"
                                    showCopyAlert = true
                                } label: { Label("Share Hashtags", systemImage: "number") }
                            }
                            
                            if let keywords = recording.keywords, !keywords.isEmpty {
                                ShareLink(item: keywords.joined(separator: ", ")) {
                                    Label("Share Keywords", systemImage: "textformat")
                                }
                            } else {
                                Button {
                                    copyAlertMessage = "No keywords available to share"
                                    showCopyAlert = true
                                } label: { Label("Share Keywords", systemImage: "textformat") }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                            .rotationEffect(.degrees(90))
                            .frame(width: 32, height: 32)
                    }
                }
                
                // Summary with direct share
                VStack(alignment: .leading, spacing: 6) {
                    let summaryText = (recording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let isGenerating = viewModel.isSummaryGenerating(for: recording)
                    HStack {
                        Text("Summary").font(.subheadline).fontWeight(.medium)
                        Spacer()
                        if isGenerating {
                            ProgressView().scaleEffect(0.8)
                        } else if !summaryText.isEmpty {
                            ShareLink(item: summaryText) {
                                Image(systemName: "arrowshape.turn.up.forward.fill")
                                    .foregroundColor(.primary)
                                    .frame(width: 32, height: 32)
                            }
                        }
                    }
                    if !summaryText.isEmpty {
                        Text(summaryText).font(.caption).foregroundColor(.secondary)
                    } else if !isGenerating {
                        Text("No summary yet").font(.caption).foregroundColor(.secondary)
                    }
                }
                .card(color: Color(.label.withAlphaComponent(0.04)))
                
                // Keywords with direct share
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Keywords").font(.subheadline).fontWeight(.medium)
                        Spacer()
                        if keywordsLoading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8)
                            }
                        } else if let keywords = recording.keywords, !keywords.isEmpty {
                            Menu {
                                let hashtags = keywords.map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")
                                ShareLink(item: hashtags) {
                                    Label("Share Hashtags", systemImage: "number")
                                }
                                ShareLink(item: keywords.joined(separator: ", ")) {
                                    Label("Share Keywords", systemImage: "square.and.arrow.up")
                                }
                            } label: {
                                Image(systemName: "arrowshape.turn.up.forward.fill")
                                    .foregroundColor(.primary)
                                    .frame(width: 32, height: 32)
                            }
                        } else {
                            Button("Extract") {
                                keywordsLoading = true
                                Task {
                                    _ = await viewModel.extractKeywords(for: recording)
                                    try? modelContext.save()
                                    keywordsLoading = false
                                }
                            }
                            .font(.caption)
                        }
                    }
                    if let keywords = recording.keywords, !keywords.isEmpty {
                        KeywordChipsView(keywords: keywords)
                    } else if !keywordsLoading {
                        Text("No keywords yet").font(.caption).foregroundColor(.secondary)
                    }
                }
                .card()
                
                if let todos = recording.todoList, !todos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Action Items").font(.subheadline).fontWeight(.medium)
                        ForEach(todos, id: \.self) { todo in
                            HStack(alignment: .center) {
                                Text("•")
                                Text(todo).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .card()
                }
                
                let segs = viewModel.segments(for: recording)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segs, id: \.id) { segment in
                        TranscriptSegmentCard(
                            isActive: playingSegmentId == segment.id,
                            timeRange: timeRange(for: segment, in: segs),
                            text: segment.text.isEmpty ? statusText(for: segment) : segment.text,
                            isPlaying: playingSegmentId == segment.id,
                            onPlayPause: {
                                if playingSegmentId == segment.id {
                                    PlaybackService.shared.stop()
                                    playingSegmentId = nil
                                } else {
                                    viewModel.play(segment: segment)
                                    playingSegmentId = segment.id
                                }
                            },
                            trailingMenu: {
                                Menu {
                                    Button {
                                        let text = segment.text
                                        if !text.isEmpty {
                                            Task {
                                                let (summary, _) = await SummaryService.generateShortSummary(for: text)
                                                copyAlertMessage = summary.isEmpty ? "No summary generated" : summary
                                                showCopyAlert = true
                                            }
                                        }
                                    } label: {
                                        Label("Generate Summary", systemImage: "text.badge.star")
                                    }
                                    
                                    ShareLink(item: segment.text.isEmpty ? statusText(for: segment) : segment.text) {
                                        Label("Share Text", systemImage: "square.and.arrow.up")
                                    }
                                    
                                    Button {
                                        let text = segment.text
                                        guard !text.isEmpty else { return }
                                        UIPasteboard.general.string = text
                                    } label: {
                                        Label("Copy Text", systemImage: "doc.on.doc")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .foregroundColor(.primary)
                                        .rotationEffect(.degrees(90))
                                        .frame(width: 32, height: 32)
                                }
                            }
                        )
                        .card()
                    }
                }
                .padding(.horizontal, 0)
            }
            .padding(.horizontal)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .alert(copyAlertMessage, isPresented: $showCopyAlert) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $qaRecording) { rec in
            VStack(alignment: .leading, spacing: 16) {
                Text("Ask a Question").font(.headline)
                TextField("Type your question…", text: $qaQuestion).textFieldStyle(RoundedBorderTextFieldStyle())
                if qaLoading {
                    HStack { ProgressView(); Text("Answering…").foregroundColor(.secondary) }
                } else if let answer = qaAnswer, !answer.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Answer").font(.subheadline).fontWeight(.medium)
                        Text(answer).font(.body)
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
        }
    }
    
    private var titleText: String {
        recording.title?.isEmpty == false ? recording.title! : "Recording"
    }
	
	private func timeRange(for segment: TranscriptionSegment, in all: [TranscriptionSegment]) -> String {
		guard let idx = all.firstIndex(where: { $0.id == segment.id }) else {
			return singleTime(segment.timestamp)
		}
		let start = segment.timestamp
		let end: TimeInterval
		if idx + 1 < all.count {
			end = max(all[idx + 1].timestamp, start)
		} else {
			end = max(recording.duration, start)
		}
		return "\(singleTime(start)) - \(singleTime(end))"
	}
	
	private func singleTime(_ t: TimeInterval) -> String {
		let mins = Int(t) / 60
		let secs = Int(t) % 60
		return String(format: "%01d:%02d", mins, secs)
	}
	
	private func statusText(for segment: TranscriptionSegment) -> String {
		switch segment.status {
		case "pending", "processing": return "Processing…"
		case "failed": return "Failed to transcribe"
		case "queued": return "Queued (offline)"
		default: return ""
		}
	}
}


