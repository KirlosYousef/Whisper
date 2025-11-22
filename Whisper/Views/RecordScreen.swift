import SwiftUI
import SwiftData

struct RecordScreen: View {
    @Environment(\.modelContext) private var modelContext
	@Environment(\.colorScheme) private var colorScheme
    @StateObject var viewModel: RecordingViewModel
    @State private var docked = false
    
    var body: some View {
        VStack(spacing: 16) {
            headerBanners
            segmentsList
            Spacer()
            micArea
        }
        .padding(.horizontal)
		.background(AppTheme.background(colorScheme).ignoresSafeArea())
        .navigationTitle("Record")
        .onChange(of: viewModel.isRecording) { _, newValue in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                docked = newValue
            }
        }
        .onAppear {
            viewModel.checkNetworkStatus()
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
        if let rec = viewModel.activeRecording, docked {
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



