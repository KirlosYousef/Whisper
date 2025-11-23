//
//  IconBadge.swift
//  Whisper
//
//  Created by Kirlos Yousef on 22/11/2025.
//

import SwiftUI

struct IconBadge: View {
	let systemName: String
	let background: Color
	let size: CGFloat
	@Environment(\.colorScheme) private var colorScheme
	
	init(systemName: String, background: Color, size: CGFloat = 40) {
		self.systemName = systemName
		self.background = background
		self.size = size
	}
	
	var body: some View {
		RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
			.fill(background)
			.frame(width: size, height: size)
			.overlay(
				Image(systemName: systemName)
					.font(.system(size: size * 0.45, weight: .semibold))
					.foregroundColor(colorScheme == .dark ? .black : .white)
			)
	}
}


