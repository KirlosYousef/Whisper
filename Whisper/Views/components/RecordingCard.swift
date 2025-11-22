import SwiftUI

struct RecordingCard<Trailing: View, Accessory: View>: View {
	let title: String
	let subtitle: String?
	let trailing: () -> Trailing
	let accessory: () -> Accessory
	@Environment(\.colorScheme) private var colorScheme
	
	init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
		self.title = title
		self.subtitle = subtitle
		self.trailing = trailing
		self.accessory = accessory
	}
	
	var body: some View {
		HStack(alignment: .center, spacing: 12) {
			let bg = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
			let fg = colorScheme == .dark ? Color.white : Color.black
			RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
				.fill(bg)
				.frame(width: 40, height: 40)
				.overlay(
					Image(systemName: "mic.fill")
						.font(.system(size: 18, weight: .semibold))
						.foregroundColor(fg)
				)
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.app(.medium, size: 17))
					.foregroundColor(.primary)
					.lineLimit(1)
				if let subtitle = subtitle, !subtitle.isEmpty {
					Text(subtitle)
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			Spacer()
			accessory()
			trailing()
		}
		.contentShape(Rectangle())
	}
}


