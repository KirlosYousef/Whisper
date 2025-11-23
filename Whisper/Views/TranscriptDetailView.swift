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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordingHeaderCard(title: titleText, duration: recording.duration) {
                Menu {
                    Button {
                        Task {
                            let (summary, todos) = await SummaryService.generateSummary(for: recording.fullTranscript)
                            recording.summary = summary
                            recording.todoList = todos
                            try? modelContext.save()
                        }
                    } label: { Label("Generate Summary", systemImage: "text.badge.star") }
                    
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
                            let md = SummaryService.exportString(for: recording, format: .markdown)
                            UIPasteboard.general.string = md
                            copyAlertMessage = "Markdown copied to clipboard"
                            showCopyAlert = true
                        } label: { Label("Copy Markdown", systemImage: "doc.on.doc") }
                        
                        Button {
                            SummaryService.shareRecording(recording, format: .text)
                        } label: { Label("Share Text", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundColor(.primary)
                }
            }
            
            if let summary = recording.summary, !summary.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Summary").font(.subheadline).fontWeight(.medium)
                        Text(summary).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .card(color: Color(.label.withAlphaComponent(0.04)))
            }
            
            if let todos = recording.todoList, !todos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Action Items").font(.subheadline).fontWeight(.medium)
                    ForEach(todos, id: \.self) { todo in
                        HStack(alignment: .top) {
                            Text("•")
                            Text(todo).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .card()
            }
            
			ScrollView {
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
										copyAlertMessage = "Text copied"
										showCopyAlert = true
									} label: {
										Label("Copy Text", systemImage: "doc.on.doc")
									}
								} label: {
									Image(systemName: "ellipsis.circle").foregroundColor(.primary)
								}
							}
						)
						.card()
					}
				}
				.padding(.horizontal, 0)
			}
        }
        .padding(.horizontal)
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


