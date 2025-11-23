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
    let trailing: () -> Trailing
    
    init(title: String, duration: TimeInterval, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.duration = duration
        self.trailing = trailing
    }
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(Self.formatDuration(duration)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            trailing()
        }
        .card()
    }
    
    private static func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}



