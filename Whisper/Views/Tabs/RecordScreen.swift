import SwiftUI
import SwiftData

struct RecordScreen: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: RecordingViewModel
    @State private var docked = false
    @State private var playingSegmentId: UUID? = nil
    
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
                PlaybackService.shared.stop()
                playingSegmentId = nil
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
                if !viewModel.isRecording {
                    Menu {
                        Picker("Transcription mode", selection: Binding(
                            get: { viewModel.preRecordingTranscriptionMode },
                            set: { newMode in
                                viewModel.setPreRecordingTranscriptionMode(newMode)
                                AnalyticsService.shared.trackEvent("Pre-recording Transcription Mode Selected", properties: [
                                    "mode": newMode.rawValue
                                ])
                            }
                        )) {
                            ForEach(TranscriptionMode.allCases) { mode in
                                Text(mode.settingsTitle).tag(mode)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Transcribe: \(viewModel.preRecordingTranscriptionMode.settingsTitle)")
                                .font(.app(.medium, size: 15))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.15), lineWidth: 1))
                    }
                }

                if !viewModel.isRecording {
                    TranslationChip(language: $viewModel.sessionTranslationLanguage) { newValue in
                        AnalyticsService.shared.trackEvent("Session Translation Language Changed", properties: [
                            "language": newValue
                        ])
                    }
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
                        let segments = viewModel.segments(for: rec)
                        ForEach(segments, id: \.id) { seg in
                            TranscriptSegmentCard(
                                isActive: playingSegmentId == seg.id,
                                timeRange: timeRange(for: seg, in: segments, recordingDuration: rec.duration),
                                text: seg.text.isEmpty ? statusText(for: seg) : seg.text,
                                isPlaying: playingSegmentId == seg.id,
                                isDisabled: viewModel.isRecording,
                                onPlayPause: {
                                    if playingSegmentId == seg.id {
                                        PlaybackService.shared.stop()
                                        playingSegmentId = nil
                                    } else {
                                        viewModel.play(segment: seg)
                                        playingSegmentId = seg.id
                                    }
                                },
                                trailingMenu: {
                                    EmptyView()
                                }
                            )
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

    private func timeRange(for segment: TranscriptionSegment, in all: [TranscriptionSegment], recordingDuration: TimeInterval) -> String {
        guard let idx = all.firstIndex(where: { $0.id == segment.id }) else {
            return singleTime(segment.timestamp)
        }

        let start = segment.timestamp
        let end: TimeInterval
        if all.count == 1 {
            end = max(recordingDuration, start)
        } else if idx + 1 < all.count {
            end = max(all[idx + 1].timestamp, start)
        } else {
            end = max(recordingDuration, start)
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
