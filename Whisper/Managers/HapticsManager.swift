//
//  HapticsManager.swift
//  Whisper
//
//  Created by Kirlos Yousef on 24/11/2025.
//

import Foundation
import UIKit

final class HapticsManager {
	static let shared = HapticsManager()
	private init() {}
	
	// Read from AppStorage("hapticsEnabled") defaulting to true if unset
	private var isEnabled: Bool {
		if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
			return true
		}
		return UserDefaults.standard.bool(forKey: "hapticsEnabled")
	}
	
	// Cache generators to reduce allocation cost
	private lazy var selectionGenerator = UISelectionFeedbackGenerator()
	private lazy var impactLightGenerator = UIImpactFeedbackGenerator(style: .light)
	private lazy var impactMediumGenerator = UIImpactFeedbackGenerator(style: .medium)
	private lazy var impactHeavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
	private lazy var notificationGenerator = UINotificationFeedbackGenerator()
	
	func prepare() {
		guard isEnabled else { return }
		selectionGenerator.prepare()
		impactLightGenerator.prepare()
		impactMediumGenerator.prepare()
		impactHeavyGenerator.prepare()
		notificationGenerator.prepare()
	}
	
	func selection() {
		guard isEnabled else { return }
		selectionGenerator.selectionChanged()
		selectionGenerator.prepare()
	}
	
	func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
		guard isEnabled else { return }
		switch style {
		case .light:
			impactLightGenerator.impactOccurred()
			impactLightGenerator.prepare()
		case .medium:
			impactMediumGenerator.impactOccurred()
			impactMediumGenerator.prepare()
		case .heavy:
			impactHeavyGenerator.impactOccurred()
			impactHeavyGenerator.prepare()
		@unknown default:
			impactMediumGenerator.impactOccurred()
			impactMediumGenerator.prepare()
		}
	}
	
	func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
		guard isEnabled else { return }
		notificationGenerator.notificationOccurred(type)
		notificationGenerator.prepare()
	}
}


