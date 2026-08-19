//
//  TranslationChip.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct TranslationChip: View {
	@Binding var language: String
	let onChange: (String) -> Void
	@Environment(\.colorScheme) private var colorScheme

	private var labelText: String {
		Languages.isNoTranslation(language)
			? Languages.noTranslationDisplay
			: "Translate to: \(Languages.translationDisplayName(for: language))"
	}
	
	var body: some View {
		Menu {
			Picker("Translate to", selection: $language) {
				Text(Languages.noTranslationDisplay).tag(Languages.autoCode)
				Divider()
				ForEach(Languages.supported) { lang in
					Text(lang.name).tag(lang.code)
				}
			}
		} label: {
			HStack(spacing: 8) {
				Text(labelText)
					.font(.app(.medium, size: 15))
					.foregroundColor(colorScheme == .dark ? .white : .black)
				Image(systemName: "chevron.down")
					.font(.system(size: 13, weight: .semibold))
					.foregroundColor(colorScheme == .dark ? .white : .black)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.background((colorScheme == .dark ? Color.white : Color.black).opacity(0.08), in: Capsule())
			.overlay(Capsule().stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.15), lineWidth: 1))
		}
		.onChange(of: language) { _, newValue in
			HapticsManager.shared.selection()
			onChange(newValue)
		}
		.accessibilityLabel(Text(labelText))
	}
}


