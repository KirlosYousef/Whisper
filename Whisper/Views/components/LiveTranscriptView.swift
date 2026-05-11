import SwiftUI

struct LiveTranscriptView: View {
    let words: [String]
    let isConnected: Bool
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedWordKey: String?
    @State private var highlightVersion = 0

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(background)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transcriptScroller
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(isConnected ? "Realtime transcription" : "Preparing realtime")
                .font(.app(.semibold, size: 13))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var transcriptScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .id(transcriptKey)
            }
            .onChange(of: words) { _, updatedWords in
                guard !updatedWords.isEmpty else { return }
                restartHighlight(for: updatedWords)
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(transcriptKey, anchor: .bottom)
                }
            }
        }
    }

    private var transcriptText: some View {
        Group {
            if words.isEmpty {
                Text(isRecording ? "Listening..." : "Your words will appear here.")
                    .font(.app(.medium, size: 24))
                    .foregroundColor(.secondary)
            } else {
                combinedTranscriptText
                    .lineSpacing(8)
                    .animation(.spring(response: 0.25, dampingFraction: 0.78), value: words.count)
            }
        }
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

    private var transcriptKey: String {
        words.joined(separator: " ")
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

    private var background: some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
    }
}
