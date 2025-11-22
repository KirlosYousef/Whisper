//
//  PaywallManager.swift
//  Whisper
//
//  Created by Kirlos Yousef on 15/11/2025.
//

import Foundation
import RevenueCat

class PaywallManager: NSObject, ObservableObject {
    static var shared = PaywallManager()
    
    @Published var isPremium: Bool = false
    
    override init() {
        super.init()
        setup()
    }
    
    func setup() {
        // Purchases.logLevel = .debug
        Purchases.configure(withAPIKey: "")
        Purchases.shared.delegate = self
        
        Task {
            _ = await isPremiumMember()
        }
    }
    
    func loginUser(name: String) {
        DispatchQueue.global(qos: .userInteractive).async {
            Purchases.shared.attribution.setDisplayName(name)
        }
    }
    
    @MainActor
    func isPremiumMember() async -> Bool {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            let isPremiumMember = !customerInfo.entitlements.active.isEmpty // user has access to some entitlement
            
            self.isPremium = isPremiumMember
            return isPremiumMember
        } catch {
            // handle error
            print(error.localizedDescription)
            return false
        }
    }
}

extension PaywallManager: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task {
            _ = await isPremiumMember()
        }
    }
}
