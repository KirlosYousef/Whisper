import SwiftUI
import SwiftData

struct RecordScreen: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: RecordingViewModel
    @ObservedObject private var usageAccess = UsageAccessManager.shared
    @ObservedObject private var paywallCoordinator = PaywallCoordinator.shared
    @State private var docked = false
    @State private var playingSegmentId: UUID? = nil
    @State private var focusedSpeakerKey: String? = nil
    @State private var followLiveTranscript = true
    @State private var isProgrammaticLiveScroll = false
    @State private var liveScrollViewportHeight: CGFloat = 0
    
    var body: some View {
		ZStack {
			VStack(spacing: 16) {
				headerBanners
                if viewModel.isPreparingRealtime {
                    SessionStatusView(kind: .preparing)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    segmentsList
                }
				Spacer(minLength: 0)
			}
			.padding(.horizontal)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: viewModel.isPreparingRealtime)
			
			// Mic button floating center -> bottom when docked
			micArea
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: docked ? .bottom : .center)
				.padding(.horizontal)
		}
		.background(AppTheme.background(colorScheme).ignoresSafeArea())
		.navigationTitle("Record")
		.onChange(of: viewModel.isRecording) { _, newValue in
			if newValue {
				followLiveTranscript = true
				withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
					docked = true
				}
			}
		}
        .onChange(of: viewModel.isPreparingRealtime) { _, preparing in
            if preparing {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    docked = true
                }
            }
        }
		.onAppear {
			viewModel.checkNetworkStatus()
			// Saved audio is retried by the app whenever access changes; this only refreshes the numbers shown here.
			Task { await usageAccess.refresh() }
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
                if !viewModel.isRecording && !viewModel.isStartingRecording && !viewModel.isFinishingRealtime {
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

                if !viewModel.isRecording && !viewModel.isStartingRecording && !viewModel.isFinishingRealtime {
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
		.task {
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 15_000_000_000)
				guard !Task.isCancelled else { break }
				await usageAccess.refreshUsageSnapshot()
			}
		}
		.alert("5 trial minutes left", isPresented: Binding(
			get: { usageAccess.shouldShowFiveMinuteWarning },
			set: { if !$0 { usageAccess.markFiveMinuteWarningPresented() } }
		)) {
			Button("Continue recording", role: .cancel) { usageAccess.markFiveMinuteWarningPresented() }
		} message: {
			Text("Your 3-day trial includes 30 transcription minutes in total. A recording in progress keeps saving if they run out.")
		}
		.alert("Microphone access is off", isPresented: $viewModel.showPermissionAlert) {
			Button("Open Settings") {
				if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Turn on microphone access for Revera AI in Settings to record.")
		}
    }
    
    @ViewBuilder
    private var headerBanners: some View {
        if case .trial(let remainingMs) = usageAccess.accessState {
            let remainingMinutes = Int(ceil(Double(remainingMs) / 60_000))
            BannerView(
                icon: "clock",
                title: remainingMinutes == 1 ? "1 trial minute remaining" : "\(remainingMinutes) trial minutes remaining",
                subtitle: "30 transcription minutes in your 3-day trial",
                color: remainingMinutes > 5 ? .blue : .orange
            )
        }
        if case .trialExhausted(let unlimitedStartsAt) = usageAccess.accessState {
            VStack(alignment: .leading, spacing: 10) {
                Text("You’ve used your 30 trial minutes.")
                    .font(.app(.semibold, size: 15))
                if let unlimitedStartsAt {
                    Text("Unlimited starts \(unlimitedStartsAt.formatted(date: .abbreviated, time: .omitted)), when your trial ends. Saved audio transcribes automatically then.")
                        .font(.app(.regular, size: 14))
                        .foregroundStyle(.secondary)
                } else if usageAccess.isConfirmingPurchase || usageAccess.purchaseConfirmation == .pending {
                    // Bought, but the App Store has not confirmed it to the Worker yet.
                    Text("Purchase received. Unlimited is activating and unlocks automatically.")
                        .font(.app(.regular, size: 14))
                        .foregroundStyle(.secondary)
                    if !usageAccess.isConfirmingPurchase {
                        capsuleButton("Check again") {
                            Task { _ = await usageAccess.confirmPurchase(productID: UsageAccessManager.unlimitedProductID) }
                        }
                    }
                } else {
                    Text("Upgrade to Unlimited to keep recording and transcribing. Your saved audio stays on this device.")
                        .font(.app(.regular, size: 14))
                        .foregroundStyle(.secondary)
                    capsuleButton("Upgrade to Unlimited") { paywallCoordinator.present(.upgrade) }
                }
                Button("Manage subscription") {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") { openURL(url) }
                }
                .font(.app(.medium, size: 13))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        } else if viewModel.hasUsageLockedTranscriptions {
            if usageAccess.accessState.canTranscribe {
                Button {
                    Task { await viewModel.retryUsageLockedTranscriptionsWhenAccessIsAvailable(refreshFirst: false) }
                } label: {
                    BannerView(icon: "arrow.clockwise", title: "Saved audio is ready to transcribe", subtitle: "Tap to transcribe it now.", color: .blue)
                }
                .buttonStyle(.plain)
            } else {
                BannerView(
                    icon: "lock",
                    title: "Saved audio is waiting",
                    subtitle: [
                        "It transcribes automatically once your subscription is verified.",
                        usageAccess.lastAccessDetail.map { "Verification failed (\($0)). Retrying." }
                    ].compactMap { $0 }.joined(separator: " "),
                    color: .orange
                )
            }
        }
        if let error = viewModel.errorMessage, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ErrorCapsuleView(text: error)
        }
        if !viewModel.isOnline {
            BannerView(icon: "wifi.slash", title: "Offline Mode", subtitle: "Segments will be queued", color: .orange)
        }
        if viewModel.isInterrupted {
            BannerView(icon: "exclamationmark.triangle.fill", title: "Recording Interrupted", subtitle: viewModel.interruptionMessage, color: .orange)
        }
        if let status = viewModel.realtimeStatusText, !viewModel.isPreparingRealtime, !viewModel.isFinishingRealtime {
            BannerView(
                icon: viewModel.isRealtimeConnected ? "waveform" : "info.circle",
                title: viewModel.isRealtimeConnected ? "Realtime Live" : "Live captions off",
                subtitle: status,
                color: viewModel.isRealtimeConnected ? .green : .orange
            )
        }
        if shouldShowLivePreviewHint {
            LivePreviewHintView()
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

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.app(.semibold, size: 15))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.primary))
        }
        .buttonStyle(.plain)
    }

    private var shouldShowLivePreviewHint: Bool {
        viewModel.isRecording &&
        viewModel.activeRecording.map { shouldShowLiveTranscript(for: $0) } == true
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

                    if viewModel.isFinishingRealtime {
                        SessionStatusView(kind: .finishing, style: .compact)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

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
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: viewModel.isFinishingRealtime)
                // Keep bottom content visible above mic and translation chip
                .padding(.bottom, docked ? 220 : 120)
            }
            .coordinateSpace(name: "recordScroll")
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { liveScrollViewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in
                            liveScrollViewportHeight = height
                        }
                }
            )
            .onChange(of: viewModel.liveTranscript) { _, _ in
                scrollLiveTranscriptToEnd(using: proxy)
            }
            .onChange(of: viewModel.liveTranscriptWords.count) { _, _ in
                scrollLiveTranscriptToEnd(using: proxy)
            }
            .onPreferenceChange(LiveTranscriptBottomPreferenceKey.self) { minY in
                updateLiveTranscriptFollow(bottomMinY: minY)
            }
            .overlay(alignment: .bottom) {
                if viewModel.isRecording, shouldShowLiveTranscript(for: rec), !followLiveTranscript {
                    Button {
                        followLiveTranscript = true
                        scrollLiveTranscriptToEnd(using: proxy, force: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Jump to live")
                                .font(.app(.semibold, size: 13))
                        }
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, docked ? 8 : 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
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

    private func scrollLiveTranscriptToEnd(using proxy: ScrollViewProxy, force: Bool = false) {
        guard viewModel.isRecording else { return }
        guard force || followLiveTranscript else { return }
        isProgrammaticLiveScroll = true
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo("live-transcript-end", anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            isProgrammaticLiveScroll = false
        }
    }

    private func updateLiveTranscriptFollow(bottomMinY: CGFloat) {
        guard viewModel.isRecording, liveScrollViewportHeight > 0 else { return }
        guard !isProgrammaticLiveScroll else { return }
        let isNearBottom = bottomMinY < liveScrollViewportHeight + 72
        if isNearBottom != followLiveTranscript {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                followLiveTranscript = isNearBottom
            }
        }
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
        case "locked": return "Saved audio · waiting for subscription"
        case "failed": return "Failed to transcribe"
        case "queued": return "Queued (offline)"
        default: return ""
        }
    }
    
    private var micArea: some View {
		VStack {
			HStack(spacing: 12) {
				MicButton(
                    isRecording: viewModel.isRecording,
                    audioLevel: viewModel.audioLevel,
                    isPreparing: viewModel.isStartingRecording || viewModel.isFinishingRealtime
                ) {
                    if viewModel.isFinishingRealtime { return }
					if viewModel.isRecording || viewModel.isStartingRecording {
						viewModel.stopRecording()
					} else {
                        PlaybackService.shared.stop()
                        playingSegmentId = nil
						Task { @MainActor in
							switch await viewModel.startRecording() {
							case .needsUpgrade:
								paywallCoordinator.present(.upgrade)
							case .needsSubscription:
								// The app's hard paywall is already covering this screen.
								break
							case .started, .permissionDenied, .cancelled, .failed:
								break
							}
						}
					}
				}
                .allowsHitTesting(!viewModel.isFinishingRealtime)
                
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
