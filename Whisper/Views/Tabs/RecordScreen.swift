import SwiftUI
import SwiftData

struct RecordScreen: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: RecordingViewModel
    @State private var docked = false
    
    var body: some View {
		ZStack {
			VStack(spacing: 16) {
				headerBanners
				segmentsList
				Spacer(minLength: 0)
			}
			.padding(.horizontal)
			
			// Mic button floating center -> bottom when docked
			micArea
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: docked ? .bottom : .center)
				.padding(.horizontal)
		}
		.background(AppTheme.background(colorScheme).ignoresSafeArea())
		.navigationTitle("Record")
		.onChange(of: viewModel.isRecording) { _, newValue in
			if newValue {
				withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
					docked = true
				}
			}
		}
		.onAppear {
			viewModel.checkNetworkStatus()
			AnalyticsService.shared.trackEvent("Record Screen Viewed", properties: [
				"is_online": viewModel.isOnline
			])
		}
		.onChange(of: viewModel.errorMessage) { _, newValue in
			if newValue != nil {
				HapticsManager.shared.notification(.error)
			}
		}
		.overlay(alignment: .bottom) {
			VStack(spacing: 12) {
				TranslationChip(language: $viewModel.sessionTranslationLanguage) { newValue in
					AnalyticsService.shared.trackEvent("Session Translation Language Changed", properties: [
						"language": newValue
					])
				}
			}
			// Keep chip above the mic when docked
			.padding(.bottom, docked ? 160 : 24)
		}
    }
    
    @ViewBuilder
    private var headerBanners: some View {
        if !viewModel.isOnline {
            BannerView(icon: "wifi.slash", title: "Offline Mode", subtitle: "Segments will be queued", color: .orange)
        }
        if viewModel.isInterrupted {
            BannerView(icon: "exclamationmark.triangle.fill", title: "Recording Interrupted", subtitle: viewModel.interruptionMessage, color: .orange)
        }
        if let status = viewModel.realtimeStatusText, viewModel.isRecording {
            BannerView(
                icon: viewModel.isRealtimeConnected ? "waveform" : "arrow.triangle.2.circlepath",
                title: viewModel.isRealtimeConnected ? "Realtime Live" : "Realtime Status",
                subtitle: status,
                color: viewModel.isRealtimeConnected ? .green : .orange
            )
        }
    }
    
    @ViewBuilder
    private var segmentsList: some View {
        if let rec = viewModel.activeRecording {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if shouldShowLiveTranscript(for: rec) {
                        LiveTranscriptView(
                            words: viewModel.transcriptWords(for: rec),
                            isConnected: viewModel.isRealtimeConnected,
                            isRecording: viewModel.isRecording
                        )
                        .padding(.bottom, 8)
                    }

                    if shouldShowSegmentRows(for: rec) {
                        ForEach(viewModel.segments(for: rec), id: \.id) { seg in
                            SegmentRow(segment: seg) {
                                viewModel.play(segment: seg)
                            }
                            .card()
                        }
                    }
                }
                // Keep bottom content visible above mic and translation chip
                .padding(.bottom, docked ? 220 : 120)
            }
        }
    }

    private func shouldShowLiveTranscript(for recording: Recording) -> Bool {
        let usesRealtimeLayout = viewModel.usesFullTranscriptDisplay(for: recording)
        guard usesRealtimeLayout else { return false }

        let hasTranscript = !viewModel.transcriptWords(for: recording).isEmpty
        let isRealtimeSessionVisible = viewModel.isRecording &&
            (viewModel.isRealtimeConnected || viewModel.realtimeStatusText != nil || hasTranscript)

        return isRealtimeSessionVisible ||
            hasTranscript
    }

    private func shouldShowSegmentRows(for recording: Recording) -> Bool {
        let hasFullTranscript = viewModel.usesFullTranscriptDisplay(for: recording) &&
            !viewModel.transcriptWords(for: recording).isEmpty

        return !viewModel.hidesSegmentRowsDuringRealtime && !hasFullTranscript
    }
    
    private var micArea: some View {
		VStack {
			HStack(spacing: 12) {
				MicButton(isRecording: viewModel.isRecording, audioLevel: viewModel.audioLevel) {
					if viewModel.isRecording {
						viewModel.stopRecording()
					} else {
						viewModel.requestPermission()
						if !viewModel.permissionDenied {
							viewModel.startRecording()
						}
					}
				}
                
                if viewModel.isRecording {
                    Button {
						HapticsManager.shared.selection()
                        if viewModel.isPaused {
                            viewModel.resumeRecording()
                        } else {
                            viewModel.pauseRecording()
                        }
                    } label: {
                        Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.horizontal)
                }
			}
			.padding(.vertical, 24)
		}
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(.clear)
        .padding(.bottom, docked ? 8 : 0)
    }
}
