//
//  TranscriptSegmentCard.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct TranscriptSegmentCard<TrailingMenu: View>: View {
	let isActive: Bool
	let timeRange: String
	let text: String
	let isPlaying: Bool
	let onPlayPause: () -> Void
	@ViewBuilder var trailingMenu: () -> TrailingMenu
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Button(action: {
				HapticsManager.shared.selection()
				onPlayPause()
			}) {
				RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
					.fill(isActive
                          ? (Color(.label))
						  : (Color(.label).opacity(0.15)))
					.frame(width: 44, height: 44)
					.overlay(
						Image(systemName: isPlaying ? "pause.fill" : "play.fill")
							.font(.system(size: 20, weight: .bold))
							.foregroundColor(isActive
											 ? (Color(.systemBackground))
                                             : (.black))
					)
			}
			.buttonStyle(.plain)
			
			VStack(alignment: .leading, spacing: 6) {
				Text(timeRange)
					.font(.app(.medium, size: 14))
					.foregroundColor(.secondary)
				Text(text)
					.font(.caption)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 8)
			
			trailingMenu()
		}
		.padding(12)
		.background(isActive
					? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
					: .clear)
		.overlay(
			RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
				.stroke(isActive
						? (colorScheme == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.15))
						: AppTheme.cardStroke,
						lineWidth: 1)
		)
		.background(.clear)
		.cornerRadius(AppTheme.cornerRadius)
	}
}


