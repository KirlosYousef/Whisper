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
	
	public static func displayName(for code: String) -> String {
		if code.lowercased() == autoCode { return autoDisplay }
		return supported.first(where: { $0.code.lowercased() == code.lowercased() })?.name
			?? code.uppercased()
	}
}



