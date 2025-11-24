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
    static let primary = Color(.label)
    
	static let backgroundLight = Color.white
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
    var insets: EdgeInsets? = nil
    private var backgroundColor: Color { (color != nil) ? color! : AppTheme.cardBackground(colorScheme) }
    private var contentInsets: EdgeInsets {
        if let insets { return insets }
        // Default system padding approximation
        return EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    }
    
    func body(content: Content) -> some View {
        content
            .padding(contentInsets)
			.background(backgroundColor)
            .cornerRadius(AppTheme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(color: Color? = nil, insets: EdgeInsets? = nil) -> some View {
        modifier(CardBackground(color: color, insets: insets))
    }
}

