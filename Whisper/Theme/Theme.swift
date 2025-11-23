//
//  Theme.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

enum AppTheme {
    static let cornerRadius: CGFloat = 16
    static let smallRadius: CGFloat = 10
	static let cardStroke = Color.gray.opacity(0.12)
	static let accent = Color.accentColor
	
	// Brand & backgrounds (from UI design)
	static let primary = Color(hex: 0x2B8CEE) // #2B8CEE
	// ChatGPT-like: pure white in light, matte black in dark
	static let backgroundLight = Color.white        // #FFFFFF
	static let backgroundDark = Color(hex: 0x0A0A0A) // matte black ~ #0A0A0A
	
	/// Dynamic card background tuned for dark mode designs in the mockups
	static func cardBackground(_ colorScheme: ColorScheme) -> Color {
		background(colorScheme)
	}
	
	static func background(_ colorScheme: ColorScheme) -> Color {
		colorScheme == .dark ? backgroundDark : backgroundLight
	}
}

struct CardBackground: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme
    
    var color: Color? = nil
    private var backgroundColor: Color { (color != nil) ? color! : AppTheme.cardBackground(colorScheme) }
    
    func body(content: Content) -> some View {
        content
            .padding()
			.background(backgroundColor)
            .cornerRadius(AppTheme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(color: Color? = nil) -> some View {
        modifier(CardBackground(color: color))
    }
}

