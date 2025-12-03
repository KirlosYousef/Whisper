import SwiftUI
import SwiftData

struct TranscriptsListView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var viewModel: RecordingViewModel
	@Binding var tabSelection: Int
    @State private var showCopyAlert = false
    @State private var copyAlertMessage = ""
    @State private var extractingRecordingId: UUID?
    
	var body: some View {
		VStack(spacing: 0) {
			content
		}
		.navigationTitle("Transcripts")
		.overlay(alignment: .bottom) {
			VStack(spacing: 12) {
				TranslationChip(language: $viewModel.sessionTranslationLanguage) { _ in }
				FAB(systemImage: "mic.fill") {
					tabSelection = 1
				}
			}
			.padding(.bottom, 24)
		}
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				Button {
					HapticsManager.shared.selection()
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
		.onChange(of: viewModel.errorMessage) { _, newValue in
			if newValue != nil {
				HapticsManager.shared.notification(.error)
			}
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
								VStack(alignment: .leading, spacing: 8) {
									RecordingCard(
										title: recording.title?.isEmpty == false ? recording.title! : "Record \(idx + 1)",
                                        duration: timeLabel(recording.createdAt),
										subtitle: {
											recording.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
										}(),
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
											Text(formatDuration(recording.duration))
												.font(.caption)
												.foregroundColor(.secondary)
												.monospacedDigit()
										}
									)
								}
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
	
	private func formatDuration(_ t: TimeInterval) -> String {
		let mins = Int(t) / 60
		let secs = Int(t) % 60
		return String(format: "%02d:%02d", mins, secs)
	}
}


