import SwiftUI

struct BannerView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let color: Color
	@Environment(\.colorScheme) private var colorScheme
    
    init(icon: String, title: String, subtitle: String? = nil, color: Color = .accentColor) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
					.foregroundColor(.primary)
                Text(title)
                    .font(.headline)
					.foregroundColor(.primary)
                Spacer()
            }
            if let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
		.background((colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
        .cornerRadius(AppTheme.smallRadius)
    }
}


