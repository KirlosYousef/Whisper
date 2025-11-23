//
//  KeywordChipsView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 23/11/2025.
//

import SwiftUI

struct KeywordChipsView: View {
	let keywords: [String]
	
	var body: some View {
		FlowLayout(horizontalSpacing: 2, verticalSpacing: 2) {
			ForEach(keywords, id: \.self) { kw in
				KeywordChip(text: kw)
			}
		}
	}
}

// A simple wrapping flow layout that places subviews next to each other (leading)
// and wraps to the next line when exceeding the available width.
struct FlowLayout: Layout {
	let horizontalSpacing: CGFloat
	let verticalSpacing: CGFloat
	
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let maxWidth = proposal.width ?? .greatestFiniteMagnitude
		var currentRowWidth: CGFloat = 0
		var currentRowHeight: CGFloat = 0
		var totalWidth: CGFloat = 0
		var totalHeight: CGFloat = 0
		var isFirstRow = true
		
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			let nextWidth = currentRowWidth == 0 ? size.width : currentRowWidth + horizontalSpacing + size.width
			if nextWidth > maxWidth && currentRowWidth > 0 {
				totalWidth = max(totalWidth, currentRowWidth)
				totalHeight += currentRowHeight
				if !isFirstRow { totalHeight += verticalSpacing }
				isFirstRow = false
				currentRowWidth = size.width
				currentRowHeight = size.height
			} else {
				currentRowWidth = nextWidth
				currentRowHeight = max(currentRowHeight, size.height)
			}
		}
		if currentRowWidth > 0 {
			totalWidth = max(totalWidth, currentRowWidth)
			totalHeight += currentRowHeight
		}
		// If a width was proposed, prefer that; otherwise use content width
		let finalWidth = proposal.width ?? totalWidth
		return CGSize(width: finalWidth, height: totalHeight)
	}
	
	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let maxWidth = bounds.width
		var x: CGFloat = bounds.minX
		var y: CGFloat = bounds.minY
		var currentRowHeight: CGFloat = 0
		
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			let neededWidth = (x == bounds.minX) ? size.width : (x - bounds.minX + horizontalSpacing + size.width)
			if neededWidth > maxWidth && x > bounds.minX {
				// Wrap to next line
				x = bounds.minX
				y += currentRowHeight + verticalSpacing
				currentRowHeight = 0
			}
			subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
			x += (x == bounds.minX ? 0 : horizontalSpacing) + size.width
			currentRowHeight = max(currentRowHeight, size.height)
		}
	}
}


