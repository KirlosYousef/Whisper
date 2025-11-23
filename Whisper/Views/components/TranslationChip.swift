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
	
	private let languageDisplay: [String: String] = [
		"auto": "Auto",
		"ar": "Arabic",
		"en": "English",
		"fr": "French",
		"es": "Spanish",
		"de": "German",
		"zh": "Chinese",
		"ja": "Japanese",
		"ko": "Korean",
		"ru": "Russian",
		"pt": "Portuguese",
		"it": "Italian",
		"nl": "Dutch",
		"tr": "Turkish",
		"hi": "Hindi"
	]
	
	var body: some View {
		Menu {
			Picker("Translate to", selection: $language) {
				Text("Auto").tag("auto")
				Divider()
				Text("Arabic").tag("ar")
				Text("English").tag("en")
				Text("French").tag("fr")
				Text("Spanish").tag("es")
				Text("German").tag("de")
				Text("Chinese").tag("zh")
				Text("Japanese").tag("ja")
				Text("Korean").tag("ko")
				Text("Russian").tag("ru")
				Text("Portuguese").tag("pt")
				Text("Italian").tag("it")
				Text("Dutch").tag("nl")
				Text("Turkish").tag("tr")
				Text("Hindi").tag("hi")
			}
		} label: {
			HStack(spacing: 8) {
				Text("Translate to: \(languageDisplay[language, default: language.uppercased()])")
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
			onChange(newValue)
		}
		.accessibilityLabel(Text("Translate to \(languageDisplay[language, default: language])"))
	}
}


