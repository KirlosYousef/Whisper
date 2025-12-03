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
		}
		.onChange(of: viewModel.errorMessage) { _, newValue in
			if newValue != nil {
				HapticsManager.shared.notification(.error)
			}
		}
		.overlay(alignment: .bottom) {
			VStack(spacing: 12) {
				TranslationChip(language: $viewModel.sessionTranslationLanguage) { _ in }
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
        if let error = viewModel.errorMessage {
            Text(error).foregroundColor(.red)
        }
    }
    
    @ViewBuilder
    private var segmentsList: some View {
        if let rec = viewModel.activeRecording {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.segments(for: rec), id: \.id) { seg in
                        SegmentRow(segment: seg) {
                            viewModel.play(segment: seg)
                        }
                        .card()
                    }
                }
                // Keep bottom content visible above mic and translation chip
                .padding(.bottom, docked ? 220 : 120)
            }
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



