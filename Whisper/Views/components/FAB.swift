//
//  FAB.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct FAB: View {
	let systemImage: String
	let action: () -> Void
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		Button(action: {
			HapticsManager.shared.impact(.light)
			action()
		}) {
			Image(systemName: systemImage)
				.font(.system(size: 28, weight: .bold))
				.foregroundColor(colorScheme == .dark ? .black : .white)
				.frame(width: 64, height: 64)
				.background(colorScheme == .dark ? Color.white : Color.black)
				.clipShape(Circle())
				.shadow(color: (colorScheme == .dark ? Color.white : Color.black).opacity(0.2), radius: 12, x: 0, y: 8)
		}
		.buttonStyle(.plain)
		.accessibilityLabel(Text("Record"))
	}
}


