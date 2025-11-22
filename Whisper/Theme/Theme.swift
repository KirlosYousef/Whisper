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
	
	// Tailwind-aligned palette used in the mockups
	static let blue500 = Color(hex: 0x3B82F6)   // blue-500
	static let green500 = Color(hex: 0x22C55E)  // green-500
	static let purple500 = Color(hex: 0xA855F7) // purple-500
	static let red500 = Color(hex: 0xEF4444)    // red-500
	static let orange500 = Color(hex: 0xF97316) // orange-500
	static let teal500 = Color(hex: 0x14B8A6)   // teal-500
	static let slate500 = Color(hex: 0x64748B)  // slate-500
	static let slate700 = Color(hex: 0x334155)  // slate-700
	static let slate100 = Color(hex: 0xF1F5F9)  // slate-100
	
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
    func body(content: Content) -> some View {
        content
            .padding()
			.background(AppTheme.cardBackground(colorScheme))
            .cornerRadius(AppTheme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View {
        modifier(CardBackground())
    }
}

