//
//  Languages.swift
//  Whisper
//
//  Created by Kirlos Yousef on 23/11/2025.
//

import Foundation

public struct AppLanguage: Identifiable, Equatable {
	public let id: String
	public let code: String
	public let name: String
	
	public init(id: String, code: String, name: String) {
		self.id = id
		self.code = code
		self.name = name
	}
}

public enum Languages {
	public static let supported: [AppLanguage] = [
		.init(id: "ar", code: "ar", name: "Arabic"),
		.init(id: "de", code: "de", name: "German"),
		.init(id: "en", code: "en", name: "English"),
		.init(id: "es", code: "es", name: "Spanish"),
		.init(id: "fr", code: "fr", name: "French"),
		.init(id: "hi", code: "hi", name: "Hindi"),
		.init(id: "it", code: "it", name: "Italian"),
		.init(id: "ja", code: "ja", name: "Japanese"),
		.init(id: "ko", code: "ko", name: "Korean"),
		.init(id: "nl", code: "nl", name: "Dutch"),
		.init(id: "pt", code: "pt", name: "Portuguese"),
		.init(id: "ru", code: "ru", name: "Russian"),
		.init(id: "tr", code: "tr", name: "Turkish"),
		.init(id: "zh", code: "zh", name: "Chinese")
	]
	
	public static let autoCode = "auto"
	public static let autoDisplay = "Auto-detect"
	public static let noTranslationDisplay = "No translation"
	public static let sameAsSpokenDisplay = noTranslationDisplay
	
	public static func displayName(for code: String) -> String {
		if code.lowercased() == autoCode { return autoDisplay }
		return supported.first(where: { $0.code.lowercased() == code.lowercased() })?.name
			?? code.uppercased()
	}

	public static func translationDisplayName(for code: String) -> String {
		if isNoTranslation(code) { return noTranslationDisplay }
		return displayName(for: code)
	}

	public static func isNoTranslation(_ code: String) -> Bool {
		let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return trimmed.isEmpty || trimmed == autoCode
	}

	public static func translationTarget(from code: String) -> String? {
		isNoTranslation(code) ? nil : code.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func isoCode(from localeIdentifier: String) -> String {
		let lowered = localeIdentifier.lowercased()
		if lowered.hasPrefix("zh") { return "zh" }
		return String(lowered.prefix(2))
	}

	public static func preferredCodes(limit: Int = 3) -> [String] {
		let supportedCodes = Set(supported.map(\.code))
		var result: [String] = []
		for identifier in Locale.preferredLanguages {
			let code = isoCode(from: identifier)
			guard supportedCodes.contains(code), !result.contains(code) else { continue }
			result.append(code)
			if result.count >= limit { break }
		}
		return result
	}

	/// Language hints for the realtime session. An explicit language is sent as one hint.
	/// In Auto mode nothing is sent, so the model detects each language itself instead of
	/// choosing between the device languages on short audio chunks.
	public static func realtimeHints(selected: String, stored: String) -> [String] {
		let explicit = selected.lowercased() != autoCode ? selected : stored
		let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !trimmed.isEmpty, trimmed != autoCode else { return [] }
		return [trimmed]
	}

	public static func transcriptionHints(from stored: String) -> [String] {
		let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if trimmed.isEmpty || trimmed == autoCode {
			return preferredCodes()
		}
		return [trimmed]
	}
}



