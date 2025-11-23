//
//  SettingsRow.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct SettingsRow: View {
	let iconName: String
	let iconColor: Color
	let title: String
	let subtitle: String?
	let trailingText: String?
	var isDestructive: Bool = false
	var action: (() -> Void)? = nil
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		Button(action: { action?() }) {
			HStack(spacing: 12) {
				let bg = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
				let fg = colorScheme == .dark ? Color.white : Color.black
				RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
					.fill(bg)
					.frame(width: 40, height: 40)
					.overlay(
						Image(systemName: iconName)
							.font(.system(size: 18, weight: .semibold))
							.foregroundColor(fg)
					)
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.app(.medium, size: 17))
						.foregroundColor(isDestructive ? (colorScheme == .dark ? .white : .black) : .primary)
					if let subtitle = subtitle, !subtitle.isEmpty {
						Text(subtitle)
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
				Spacer(minLength: 8)
				if let trailing = trailingText, !trailing.isEmpty {
					Text(trailing)
						.font(.callout)
						.foregroundColor(.secondary)
				}
				Image(systemName: "chevron.right")
					.font(.system(size: 14, weight: .semibold))
                    .foregroundColor((colorScheme == .dark ? Color.white : .black).opacity(0.6))
			}
			.padding(.vertical, 8)
		}
		.buttonStyle(.plain)
	}
}


