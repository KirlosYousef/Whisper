//
//  KeywordChip.swift
//  Whisper
//
//  Created by Kirlos Yousef on 23/11/2025.
//

import SwiftUI

struct KeywordChip: View {
	let text: String
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		HStack(spacing: 6) {
			Text(text)
				.font(.caption)
				.fontWeight(.medium)
				.foregroundColor(colorScheme == .dark ? .white : .black)
				.lineLimit(1)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background((colorScheme == .dark ? Color.white : Color.black).opacity(0.08), in: Capsule())
		.overlay(
			Capsule()
				.stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.15), lineWidth: 1)
		)
		.accessibilityLabel(Text("Keyword \(text)"))
	}
}



