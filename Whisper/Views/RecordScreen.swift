import SwiftUI
import SwiftData

struct RecordScreen: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
    @StateObject var viewModel: RecordingViewModel
    @State private var docked = false
	@StateObject private var settings = SettingsStore()
    
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
		.onDisappear {
			viewModel.translationOverride = nil
		}
		.overlay(alignment: .bottom) {
			VStack(spacing: 12) {
				TranslationChip(language: Binding(
					get: { viewModel.translationOverride ?? settings.defaultTranslationLanguage },
					set: { viewModel.translationOverride = $0 }
				)) { _ in }
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
            }
        }
    }
    
    private var micArea: some View {
        VStack {
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
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(.clear)
        .padding(.bottom, docked ? 8 : 0)
    }
}



