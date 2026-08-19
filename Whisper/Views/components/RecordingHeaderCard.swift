//
//  RecordingHeaderCard.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct RecordingHeaderCard<Trailing: View>: View {
    let title: String
    let duration: TimeInterval
    var speakerCount: Int = 0
    let trailing: () -> Trailing
    
    init(title: String, duration: TimeInterval, speakerCount: Int = 0, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.duration = duration
        self.speakerCount = speakerCount
        self.trailing = trailing
    }
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                HStack(spacing: 6) {
                    Text(Self.formatDuration(duration)).font(.caption).foregroundColor(.secondary)
                    if speakerCount > 0 {
                        Text("·").font(.caption).foregroundColor(.secondary)
                        Text(speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            trailing()
        }
        .card(color: Color(.label.withAlphaComponent(0.04)))
    }
    
    private static func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}



