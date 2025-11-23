import SwiftUI
import SwiftData

struct SegmentRow: View {
    let segment: TranscriptionSegment
    let play: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: play) {
                Text(timeLabel(segment.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .underline()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            statusView
            Spacer()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    private var statusView: some View {
        if segment.status == "completed" {
            Text(segment.text)
                .font(.caption)
                .foregroundColor(.primary)
        } else if segment.status == "pending" || segment.status == "processing" {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Processing…")
					.font(.caption2)
					.foregroundColor(.primary)
            }
        } else if segment.status == "failed" {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(.primary)
                    .font(.caption)
                Text("Failed")
					.font(.caption2)
					.foregroundColor(.primary)
            }
        } else if segment.status == "queued" {
            HStack {
                Image(systemName: "icloud.slash")
					.foregroundColor(.primary)
                    .font(.caption)
                Text("Queued (offline)")
					.font(.caption2)
					.foregroundColor(.primary)
            }
        }
    }
    
    private func timeLabel(_ timestamp: TimeInterval) -> String {
        let mins = Int(timestamp) / 60
        let secs = Int(timestamp) % 60
        return String(format: "[%02d:%02d]", mins, secs)
    }
}



