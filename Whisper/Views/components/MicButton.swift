//
//  MicButton.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct MicButton: View {
    let isRecording: Bool
    let audioLevel: Float
    let action: () -> Void
	@Environment(\.colorScheme) private var colorScheme
    
    init(isRecording: Bool, audioLevel: Float, action: @escaping () -> Void) {
        self.isRecording = isRecording
        self.audioLevel = audioLevel
        self.action = action
    }
    
    var body: some View {
        Button(action: {
			HapticsManager.shared.impact(.medium)
			action()
		}) {
            ZStack {
                if isRecording {
                    Circle()
						.stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.25), lineWidth: 8)
                        .frame(width: 110, height: 110)
                        .scaleEffect(CGFloat(1.0 + (audioLevel * 0.3)))
                        .opacity(Double(0.3 + (audioLevel * 0.7)))
                        .animation(.easeOut(duration: 0.1), value: audioLevel)
                }
                Circle()
					.fill(colorScheme == .dark ? Color.white : Color.black)
                    .frame(width: 80, height: 80)
                    .scaleEffect(isRecording ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
					.foregroundColor(colorScheme == .dark ? .black : .white)
                    .font(.system(size: 36, weight: .bold))
                    .scaleEffect(isRecording ? 1.2 : 1.0)
                    .animation(.spring(), value: isRecording)
            }
        }
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
        .accessibilityHint(isRecording ? "Double tap to stop recording" : "Double tap to start recording")
        .accessibilityValue(isRecording ? "Recording in progress" : "Ready to record")
    }
}



