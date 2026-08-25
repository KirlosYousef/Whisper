import SwiftUI

struct LiveTranscriptView: View {
    let words: [String]
    let isConnected: Bool
    let isRecording: Bool
    var bottomAnchorId: String = "live-transcript-end"
    var reportsBottomPosition = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedWordKey: String?
    @State private var highlightVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transcriptText
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

            if reportsBottomPosition {
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchorId)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: LiveTranscriptBottomPreferenceKey.self,
                                value: geo.frame(in: .named("recordScroll")).minY
                            )
                        }
                    )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(background)
        .onChange(of: words) { _, updatedWords in
            guard !updatedWords.isEmpty else { return }
            restartHighlight(for: updatedWords)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(headerTitle)
                .font(.app(.semibold, size: 13))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var transcriptText: some View {
        Group {
            if words.isEmpty {
                Text(emptyStateText)
                    .font(.app(.medium, size: 24))
                    .foregroundColor(.secondary)
            } else {
                combinedTranscriptText
                    .lineSpacing(8)
                    .animation(.spring(response: 0.25, dampingFraction: 0.78), value: words.count)
            }
        }
    }

    private var emptyStateText: String {
        guard isRecording else { return "Transcript will appear here." }
        return isConnected ? "Listening…" : "Getting realtime ready…"
    }

    private var combinedTranscriptText: Text {
        let lastWord = words.last ?? ""
        let previous = words.dropLast().joined(separator: " ")
        let prefix = previous.isEmpty ? "" : previous + " "
        let isHighlighted = highlightedWordKey == currentWordKey

        return Text(prefix)
            .font(.app(.medium, size: 24))
            .foregroundColor(.primary.opacity(0.78))
        + Text(lastWord)
            .font(.app(isHighlighted ? .bold : .medium, size: isHighlighted ? 30 : 24))
            .foregroundColor(isHighlighted ? .primary : .primary.opacity(0.78))
    }

    private var currentWordKey: String {
        "\(words.count)-\(words.last ?? "")"
    }

    private func restartHighlight(for updatedWords: [String]) {
        let key = "\(updatedWords.count)-\(updatedWords.last ?? "")"
        highlightVersion += 1
        let version = highlightVersion
        highlightedWordKey = key

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard highlightVersion == version else { return }
            highlightedWordKey = nil
        }
    }

    private var headerTitle: String {
        if !isRecording {
            return "Full transcript"
        }

        return isConnected ? "Realtime transcription" : "Preparing realtime"
    }

    private var statusColor: Color {
        if !isRecording {
            return .secondary
        }

        return isConnected ? .green : .orange
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
    }
}

struct LivePreviewHintView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Live preview")
                    .font(.app(.semibold, size: 13))
                Text("This may look rough as you talk. After you stop, you’ll get the full transcript with speakers labeled.")
                    .font(.app(.regular, size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live preview. This may look rough as you talk. After you stop, you’ll get the full transcript with speakers labeled.")
    }
}

struct LiveTranscriptBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
