import SwiftUI
import SwiftData

struct RecordScreen: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: RecordingViewModel
    @State private var docked = false
    @State private var playingSegmentId: UUID? = nil
    @State private var focusedSpeakerKey: String? = nil
    
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
			.padding(.bottom, docked ? 140 : 24)
		}
    }
    
    @ViewBuilder
    private var headerBanners: some View {
        if let error = viewModel.errorMessage, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ErrorCapsuleView(text: error)
        }
        if !viewModel.isOnline {
            BannerView(icon: "wifi.slash", title: "Offline Mode", subtitle: "Segments will be queued", color: .orange)
        }
        if viewModel.isInterrupted {
            BannerView(icon: "exclamationmark.triangle.fill", title: "Recording Interrupted", subtitle: viewModel.interruptionMessage, color: .orange)
        }
        if let status = viewModel.realtimeStatusText {
            BannerView(
                icon: viewModel.isRealtimeConnected ? "waveform" : "arrow.triangle.2.circlepath",
                title: viewModel.isRealtimeConnected ? "Realtime Live" : "Status",
                subtitle: status,
                color: viewModel.isRealtimeConnected ? .green : .orange
            )
        }
        if let rec = viewModel.activeRecording,
           rec.speakerStatus == .failed,
           !viewModel.isRecording {
            Button {
                viewModel.retrySpeakerIdentification(for: rec)
            } label: {
                BannerView(
                    icon: "person.2.slash",
                    title: "Couldn’t identify speakers",
                    subtitle: "Transcript kept. Tap to try again.",
                    color: .orange
                )
            }
            .buttonStyle(.plain)
        }
    }
    
    @ViewBuilder
    private var segmentsList: some View {
        if let rec = viewModel.activeRecording {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let building = viewModel.isBuildingSpeakerTranscript(for: rec)
                    let speakerTurns = viewModel.usesSpeakerTurnDisplay(for: rec)
                    let namesJSON = rec.speakerDisplayNamesJSON

                    Group {
                        if building {
                            SpeakerIdentificationProgressView()
                                .padding(.bottom, 8)
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                        removal: .opacity
                                    )
                                )
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                if speakerTurns {
                                    SpeakerRosterView(
                                        recording: rec,
                                        focusedSpeakerKey: $focusedSpeakerKey,
                                        onNameChange: { key, name in
                                            viewModel.updateSpeakerName(name, for: key, in: rec)
                                        },
                                        onEditingEnded: {
                                            viewModel.saveSpeakerNames(for: rec)
                                        }
                                    )
                                    .id("speaker-roster")
                                    .padding(.bottom, 4)
                                }

                                if shouldShowLiveTranscript(for: rec) {
                                    LiveTranscriptView(
                                        words: viewModel.transcriptWords(for: rec),
                                        isConnected: viewModel.isRealtimeConnected,
                                        isRecording: viewModel.isRecording
                                    )
                                    .padding(.bottom, 8)
                                }

                                if shouldShowSegmentRows(for: rec) {
                                    segmentsRows(for: rec, proxy: proxy, namesJSON: namesJSON)
                                }
                            }
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 16)),
                                    removal: .opacity
                                )
                            )
                        }
                    }
                    .animation(.spring(response: 0.5, dampingFraction: 0.86), value: building)
                    .animation(.spring(response: 0.5, dampingFraction: 0.86), value: speakerTurns)
                }
                // Keep bottom content visible above mic and translation chip
                .padding(.bottom, docked ? 220 : 120)
            }
            }
        }
    }

    private func segmentsRows(for recording: Recording, proxy: ScrollViewProxy, namesJSON: String) -> some View {
        let segments = viewModel.segments(for: recording)
        return ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            if viewModel.usesSpeakerTurnDisplay(for: recording), let key = segment.speakerKey, !key.isEmpty {
                speakerTurnCard(for: segment, in: recording, proxy: proxy)
                    .speakerTurnAppear(index: index)
                    .animation(.easeInOut(duration: 0.2), value: namesJSON)
            } else {
                segmentCard(for: segment, in: segments, recordingDuration: recording.duration)
            }
        }
    }

    private func speakerTurnCard(for segment: TranscriptionSegment, in recording: Recording, proxy: ScrollViewProxy) -> some View {
        let key = segment.speakerKey ?? ""
        let canPlay = viewModel.canPlay(segment) && !viewModel.isRecording
        return SpeakerTurnCard(
            speakerKey: key,
            displayName: recording.displayName(for: key),
            timeRange: SpeakerTimeFormatting.range(segment.playbackStart, segment.playbackEnd),
            text: segment.text,
            isActive: playingSegmentId == segment.id,
            isPlaying: playingSegmentId == segment.id,
            isDisabled: !canPlay,
            showDisabledWarningIcon: !viewModel.isRecording && !canPlay,
            isHighlighted: focusedSpeakerKey == key,
            onPlayPause: {
                guard canPlay else { return }
                if playingSegmentId == segment.id {
                    PlaybackService.shared.stop()
                    playingSegmentId = nil
                } else {
                    viewModel.play(segment: segment) {
                        if playingSegmentId == segment.id {
                            playingSegmentId = nil
                        }
                    }
                    playingSegmentId = segment.id
                }
            },
            onNameTap: {
                focusedSpeakerKey = key
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    proxy.scrollTo("speaker-roster", anchor: .top)
                }
            },
            trailingMenu: { EmptyView() }
        )
        .card()
    }

    private func segmentCard(for segment: TranscriptionSegment, in allSegments: [TranscriptionSegment], recordingDuration: TimeInterval) -> some View {
        TranscriptSegmentCard(
            isActive: playingSegmentId == segment.id,
            timeRange: timeRange(for: segment, in: allSegments, recordingDuration: recordingDuration),
            text: segment.text.isEmpty ? statusText(for: segment) : segment.text,
            isPlaying: playingSegmentId == segment.id,
            isDisabled: viewModel.isRecording,
            showDisabledWarningIcon: false,
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
                EmptyView()
            }
        )
        .card()
    }

    private func shouldShowLiveTranscript(for recording: Recording) -> Bool {
        if viewModel.isBuildingSpeakerTranscript(for: recording) {
            return false
        }
        if viewModel.usesSpeakerTurnDisplay(for: recording), !viewModel.isRecording {
            return false
        }
        let usesRealtimeLayout = viewModel.usesFullTranscriptDisplay(for: recording)
        guard usesRealtimeLayout else { return false }

        let hasTranscript = !viewModel.transcriptWords(for: recording).isEmpty
        let isRealtimeSessionVisible = viewModel.isRecording &&
            (viewModel.isRealtimeConnected || viewModel.realtimeStatusText != nil || hasTranscript)

        return isRealtimeSessionVisible ||
            hasTranscript
    }

    private func shouldShowSegmentRows(for recording: Recording) -> Bool {
        if viewModel.isBuildingSpeakerTranscript(for: recording) {
            return false
        }
        if viewModel.usesSpeakerTurnDisplay(for: recording) { return true }
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
				MicButton(isRecording: viewModel.isRecording || viewModel.isStartingRecording, audioLevel: viewModel.audioLevel) {
					if viewModel.isRecording || viewModel.isStartingRecording {
						viewModel.stopRecording()
					} else {
                        PlaybackService.shared.stop()
                        playingSegmentId = nil
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
