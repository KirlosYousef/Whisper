//
//  TranscriptDetailView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 18/11/2025.
//

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
    @State private var playingSegmentId: UUID? = nil
    @State private var showSummaryToast: Bool = false
    @State private var keywordsLoading: Bool = false
    @State private var canPlayRecording: Bool = true
    @State private var showRenameSpeakers = false
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                RecordingHeaderCard(
                    title: titleText,
                    duration: recording.duration,
                    speakerCount: recording.speakerStatus == .completed ? recording.speakerCount : 0
                ) {
                    Menu {
                        if recording.hasSpeakerLabels {
                            Button {
                                showRenameSpeakers = true
                            } label: { Label("Rename speakers", systemImage: "person.crop.circle") }
                        }
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
                        } label: { Label("Extract Keywords", systemImage: "textformat") }
                        
                        Button {
                            AnalyticsService.shared.trackEvent("Recording Shared", properties: [
                                "recording_duration": recording.duration,
                                "format": "default"
                            ])
                            SummaryService.shareRecording(recording)
                        } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        
                        Button {
                            qaRecording = recording
                        } label: { Label("Ask or Act", systemImage: "questionmark.bubble") }
                        
                        Menu("Export") {
                            Button {
                                AnalyticsService.shared.trackEvent("Recording Shared", properties: [
                                    "recording_duration": recording.duration,
                                    "format": "markdown"
                                ])
                                SummaryService.shareRecording(recording, format: .markdown)
                            } label: { Label("Share Markdown", systemImage: "square.and.arrow.up") }
                            
                            Button {
                                AnalyticsService.shared.trackEvent("Recording Shared", properties: [
                                    "recording_duration": recording.duration,
                                    "format": "text"
                                ])
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
                
                Button {
                    qaRecording = recording
                    AnalyticsService.shared.trackEvent("Ask/Act Opened", properties: [
                        "recording_duration": recording.duration,
                        "source": "transcript_detail"
                    ])
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "questionmark.bubble")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask or Act")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Ask questions or take action on this transcript")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .card()
                
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
                            .simultaneousGesture(TapGesture().onEnded {
                                AnalyticsService.shared.trackEvent("Summary Shared", properties: [
                                    "summary_length": summaryText.count,
                                    "recording_duration": recording.duration
                                ])
                            })
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
                                    Label("Share Keywords", systemImage: "textformat")
                                }
                            } label: {
                                Image(systemName: "arrowshape.turn.up.forward.fill")
                                    .foregroundColor(.primary)
                                    .frame(width: 32, height: 32)
                            }
                            .onTapGesture {
                                AnalyticsService.shared.trackEvent("Keywords Shared", properties: [
                                    "keyword_count": keywords.count,
                                    "recording_duration": recording.duration
                                ])
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
                
                speakerIdentificationCard
                
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                
                Group {
                    let building = viewModel.isBuildingSpeakerTranscript(for: recording)
                    if building {
                        SpeakerIdentificationProgressView()
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                    removal: .opacity
                                )
                            )
                    } else if shouldShowSpeakerTurns {
                        speakerTurnsList
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 16)),
                                    removal: .opacity
                                )
                            )
                    } else if shouldShowFullTranscript {
                        fullTranscriptCard
                    } else {
                        let segs = viewModel.segments(for: recording)
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(segs, id: \.id) { segment in
                                TranscriptSegmentCard(
                                    isActive: playingSegmentId == segment.id,
                                    timeRange: timeRange(for: segment, in: segs),
                                    text: segment.text.isEmpty ? statusText(for: segment) : segment.text,
                                    isPlaying: playingSegmentId == segment.id,
                                    isDisabled: !canPlayRecording || !viewModel.canPlay(segment),
                                    onPlayPause: {
                                        togglePlayback(for: segment)
                                    },
                                    trailingMenu: {
                                        segmentMenu(for: segment)
                                    }
                                )
                                .card()
                            }
                        }
                    }
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: viewModel.isBuildingSpeakerTranscript(for: recording))
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: shouldShowSpeakerTurns)
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
            AskActionSheet(
                recording: rec,
                run: { recording, prompt in
                    await viewModel.performCommand(for: recording, prompt: prompt)
                },
                onDismiss: {
                    qaRecording = nil
                }
            )
        }
        .sheet(isPresented: $showRenameSpeakers) {
            RenameSpeakersSheet(recording: recording) {
                viewModel.saveSpeakerNames(for: recording)
            }
        }
        .onAppear {
            viewModel.resumeInterruptedSpeakerIdentification(for: recording)
        }
    }
    
    private var titleText: String {
        recording.title?.isEmpty == false ? recording.title! : "Recording"
    }

    private var shouldShowSpeakerTurns: Bool {
        viewModel.usesSpeakerTurnDisplay(for: recording)
    }

    private var shouldShowFullTranscript: Bool {
        !shouldShowSpeakerTurns &&
        viewModel.usesFullTranscriptDisplay(for: recording) &&
        !fullTranscriptText.isEmpty
    }

    private var fullTranscriptText: String {
        recording.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fullTranscriptTimeRange: String {
        "0:00 - \(singleTime(recording.duration))"
    }

    private var fullTranscriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Full transcript")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                ShareLink(item: fullTranscriptText) {
                    Image(systemName: "arrowshape.turn.up.forward.fill")
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                }
            }

            Text(fullTranscriptTimeRange)
                .font(.app(.medium, size: 14))
                .foregroundColor(.secondary)

            Text(fullTranscriptText)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    @ViewBuilder
    private var speakerIdentificationCard: some View {
        if viewModel.isBuildingSpeakerTranscript(for: recording) {
            EmptyView()
        } else if viewModel.canIdentifySpeakers(for: recording),
                  AudioService.isUsableAudioFile(at: recording.filePath) || viewModel.segments(for: recording).contains(where: { viewModel.canPlay($0) }) {
            Button {
                guard !viewModel.isIdentifyingSpeakers(for: recording) else { return }
                viewModel.retrySpeakerIdentification(for: recording)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: recording.speakerStatus == .failed ? "arrow.clockwise" : "person.3.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.speakerStatus == .failed ? "Try again" : "Identify speakers")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(recording.speakerStatus == .failed
                             ? "Speaker labels failed. Your transcript is still here."
                             : "Label everyone who spoke, however many people.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .card()
        }
    }

    private var speakerTurnsList: some View {
        let segs = viewModel.segments(for: recording)
        return LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segs.enumerated()), id: \.element.id) { index, segment in
                let key = segment.speakerKey ?? ""
                let canPlay = viewModel.canPlay(segment)
                SpeakerTurnCard(
                    speakerKey: key,
                    displayName: recording.displayName(for: key),
                    timeRange: SpeakerTimeFormatting.range(segment.playbackStart, segment.playbackEnd > segment.playbackStart ? segment.playbackEnd : recording.duration),
                    text: segment.text,
                    isActive: playingSegmentId == segment.id,
                    isPlaying: playingSegmentId == segment.id,
                    isDisabled: !canPlay,
                    onPlayPause: {
                        togglePlayback(for: segment)
                    },
                    trailingMenu: {
                        segmentMenu(for: segment)
                    }
                )
                .card()
                .speakerTurnAppear(index: index)
            }
        }
    }

    private func togglePlayback(for segment: TranscriptionSegment) {
        let canPlay = viewModel.canPlay(segment)
        if !canPlay {
            canPlayRecording = false
            return
        }
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
    }

    private func segmentMenu(for segment: TranscriptionSegment) -> some View {
        Menu {
            Button {
                let text = segment.text
                if !text.isEmpty {
                    AnalyticsService.shared.trackEvent("Segment Summary Generation Started", properties: [
                        "segment_timestamp": segment.timestamp,
                        "text_length": text.count
                    ])
                    Task {
                        let (summary, _) = await SummaryService.generateShortSummary(for: text)
                        copyAlertMessage = summary.isEmpty ? "No summary generated" : summary
                        showCopyAlert = true
                        AnalyticsService.shared.trackEvent("Segment Summary Generation Completed", properties: [
                            "summary_length": summary.count,
                            "has_summary": !summary.isEmpty
                        ])
                    }
                }
            } label: {
                Label("Generate Summary", systemImage: "text.badge.star")
            }

            ShareLink(item: segment.text.isEmpty ? statusText(for: segment) : segment.text) {
                Label("Share Text", systemImage: "square.and.arrow.up")
            }
            .simultaneousGesture(TapGesture().onEnded {
                AnalyticsService.shared.trackEvent("Segment Shared", properties: [
                    "segment_timestamp": segment.timestamp,
                    "text_length": segment.text.count
                ])
            })

            Button {
                let text = segment.text
                guard !text.isEmpty else { return }
                UIPasteboard.general.string = text
                HapticsManager.shared.notification(.success)
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
    
    private func timeRange(for segment: TranscriptionSegment, in all: [TranscriptionSegment]) -> String {
        if segment.endTime > segment.playbackStart {
            return SpeakerTimeFormatting.range(segment.playbackStart, segment.endTime)
        }
        guard let idx = all.firstIndex(where: { $0.id == segment.id }) else {
            return singleTime(segment.timestamp)
        }
        let start = segment.timestamp
        let end: TimeInterval
        if all.count == 1 {
            end = max(recording.duration, start)
        } else if idx + 1 < all.count {
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


