//
//  Font+App.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI
import UIKit

extension Font {
	/// Returns Inter when available, otherwise falls back to SF Pro with the requested weight.
	static func app(_ weight: Font.Weight, size: CGFloat) -> Font {
		let interName: String
		switch weight {
		case .bold: interName = "Inter-Bold"
		case .semibold: interName = "Inter-SemiBold"
		case .medium: interName = "Inter-Medium"
		default: interName = "Inter-Regular"
		}
		if UIFont(name: interName, size: size) != nil {
			return .custom(interName, size: size)
		}
		return .system(size: size, weight: weight)
	}
}


