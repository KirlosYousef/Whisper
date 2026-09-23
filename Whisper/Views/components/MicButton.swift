//
//  MicButton.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct MicButton: View {
    enum Mode: Equatable {
        case idle
        case preparing
        case recording
    }

    let mode: Mode
    let audioLevel: Float
    let action: () -> Void
	@Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    init(isRecording: Bool, audioLevel: Float, isPreparing: Bool = false, action: @escaping () -> Void) {
        self.mode = isPreparing ? .preparing : (isRecording ? .recording : .idle)
        self.audioLevel = audioLevel
        self.action = action
    }

    init(mode: Mode, audioLevel: Float, action: @escaping () -> Void) {
        self.mode = mode
        self.audioLevel = audioLevel
        self.action = action
    }
    
    var body: some View {
        Button(action: {
            HapticsManager.shared.impact(mode == .preparing ? .light : .medium)
			action()
		}) {
            ZStack {
                if mode == .recording {
                    Circle()
						.stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.25), lineWidth: 8)
                        .frame(width: 110, height: 110)
                        .scaleEffect(CGFloat(1.0 + (audioLevel * 0.3)))
                        .opacity(Double(0.3 + (audioLevel * 0.7)))
                        .animation(.easeOut(duration: 0.1), value: audioLevel)
                }

                if mode == .preparing {
                    preparingRing
                }

                Circle()
					.fill(colorScheme == .dark ? Color.white : Color.black)
                    .frame(width: 80, height: 80)
                    .scaleEffect(mode == .recording ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: mode)
                Image(systemName: iconName)
					.foregroundColor(colorScheme == .dark ? .black : .white)
                    .font(.system(size: mode == .preparing ? 30 : 36, weight: .bold))
                    .scaleEffect(mode == .recording ? 1.2 : 1.0)
                    .symbolEffect(.pulse, options: .repeating, isActive: mode == .preparing && !reduceMotion)
                    .animation(.spring(), value: mode)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityValue(accessibilityValue)
    }

    private var preparingRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let angle = reduceMotion
                ? 0.0
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 6)
                    .frame(width: 104, height: 104)
                Circle()
                    .trim(from: 0, to: reduceMotion ? 1 : 0.22)
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 104, height: 104)
                    .rotationEffect(.degrees(angle))
            }
        }
    }

    private var iconName: String {
        switch mode {
        case .idle: "mic.fill"
        case .preparing: "waveform"
        case .recording: "stop.fill"
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .idle: "Start Recording"
        case .preparing: "Cancel preparing"
        case .recording: "Stop Recording"
        }
    }

    private var accessibilityHint: String {
        switch mode {
        case .idle: "Double tap to start recording"
        case .preparing: "Double tap to cancel before recording starts"
        case .recording: "Double tap to stop recording"
        }
    }

    private var accessibilityValue: String {
        switch mode {
        case .idle: "Ready to record"
        case .preparing: "Preparing live transcription"
        case .recording: "Recording in progress"
        }
    }
}
