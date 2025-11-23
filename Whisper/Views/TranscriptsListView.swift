import SwiftUI
import SwiftData

struct TranscriptsListView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject var viewModel: RecordingViewModel
	@Binding var tabSelection: Int
    @State private var showCopyAlert = false
    @State private var copyAlertMessage = ""
    @State private var extractingRecordingId: UUID?
	@StateObject private var settings = SettingsStore()
    
	var body: some View {
		VStack(spacing: 0) {
			content
		}
		.navigationTitle("Transcripts")
		.overlay(alignment: .bottom) {
			VStack(spacing: 12) {
				TranslationChip(language: $settings.defaultTranslationLanguage) { _ in }
				FAB(systemImage: "mic.fill") {
					tabSelection = 1
				}
			}
			.padding(.bottom, 24)
		}
		.toolbar {
			ToolbarItem(placement: .navigationBarLeading) {
				languageMenu
			}
			ToolbarItem(placement: .navigationBarTrailing) {
				Button {
					viewModel.refreshRecordings()
				} label: {
					Image(systemName: "arrow.clockwise")
				}
			}
		}
		.searchable(text: $viewModel.searchText, prompt: "Search transcriptions…")
		.onAppear {
			viewModel.fetchRecordings()
			viewModel.checkNetworkStatus()
		}
		.alert(copyAlertMessage, isPresented: $showCopyAlert) {
			Button("OK", role: .cancel) {}
		}
	}
    
    @ViewBuilder
    private var content: some View {
		VStack(spacing: 16) {
			if !viewModel.isOnline {
				BannerView(icon: "wifi.slash", title: "Offline Mode", subtitle: "Transcriptions will be queued", color: .orange)
					.padding(.horizontal)
			}
			if viewModel.isInterrupted {
				BannerView(icon: "exclamationmark.triangle.fill", title: "Recording Interrupted", subtitle: viewModel.interruptionMessage ?? "Recording will resume automatically when possible", color: .orange)
					.padding(.horizontal)
			}
			if let error = viewModel.errorMessage {
				Text(error).foregroundColor(.red).padding(.horizontal)
			}
			
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 12) {
					ForEach(groupedRecordings.keys.sorted(by: >), id: \.self) { date in
						Text(sectionHeader(for: date))
							.font(.app(.bold, size: 20))
							.padding(.top, 8)
							.padding(.horizontal)
						
						ForEach(Array((groupedRecordings[date] ?? []).enumerated()), id: \.element.id) { idx, recording in
							NavigationLink {
								TranscriptDetailView(viewModel: viewModel, recording: recording)
							} label: {
								RecordingCard(
									title: recording.title?.isEmpty == false ? recording.title! : "Record \(idx + 1)",
									subtitle: timeLabel(recording.createdAt),
									trailing: {
										HStack(spacing: 8) {
											if extractingRecordingId == recording.id {
												ProgressView().scaleEffect(0.7)
											}
											Image(systemName: "chevron.right")
												.foregroundColor(.secondary)
										}
									},
									accessory: {
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
												Task {
													extractingRecordingId = recording.id
													let newKeywords = await viewModel.extractKeywords(for: recording)
													extractingRecordingId = nil
													copyAlertMessage = newKeywords.isEmpty ? "No keywords found (or API not configured)" : "Keywords extracted"
													showCopyAlert = true
												}
											} label: { Label("Extract Keywords", systemImage: "tag") }
											
											Button {
												SummaryService.shareRecording(recording)
											} label: { Label("Share", systemImage: "square.and.arrow.up") }
											
											Menu("Export") {
												Button {
													let md = SummaryService.exportString(for: recording, format: .markdown)
													UIPasteboard.general.string = md
													copyAlertMessage = "Markdown copied to clipboard"
													showCopyAlert = true
												} label: { Label("Copy Markdown", systemImage: "doc.on.doc") }
												Button {
													SummaryService.shareRecording(recording, format: .markdown)
												} label: { Label("Share Markdown", systemImage: "square.and.arrow.up") }
												Button {
													SummaryService.shareRecording(recording, format: .text)
												} label: { Label("Share Text", systemImage: "square.and.arrow.up") }
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
												} label: { Label("Copy Hashtags", systemImage: "number") }
											}
										} label: {
											Image(systemName: "ellipsis.circle").foregroundColor(.accentColor)
										}
									}
								)
								.card()
								.padding(.horizontal)
							}
						}
					}
					Spacer(minLength: 80)
				}
			}
		}
    }
    
    private var languageMenu: some View {
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
    
    private var groupedRecordings: [Date: [Recording]] {
        Dictionary(grouping: viewModel.filteredRecordings) { rec in
            Calendar.current.startOfDay(for: rec.createdAt)
        }
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
	
	private func timeLabel(_ date: Date) -> String {
		let fmt = DateFormatter()
		fmt.dateStyle = .none
		fmt.timeStyle = .short
		return fmt.string(from: date)
	}
}


