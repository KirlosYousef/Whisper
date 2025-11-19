//
//  PayWallView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 15/11/2025.
//


import SwiftUI
import RevenueCatUI

struct PayWallView: View {
    var displayCloseButton: Bool = false
    
    var body: some View {
        PaywallView(displayCloseButton: displayCloseButton)
    }
}

struct PayWallViewModifier: ViewModifier {
    @Binding var showPaywallView: Bool
    @State private var showCloseButton = false
    
    @AppStorage("showPaywall") private var showPaywall = true
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showPaywall) {
                ZStack {
                    PayWallView(displayCloseButton: false)
                    
                    if showCloseButton {
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    showPaywall = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                        .padding()
                                        .shadow(radius: 2)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .onAppear {
                    // Show close button after a few seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation {
                            showCloseButton = true
                        }
                    }
                }
                .onDisappear {
                    showCloseButton = false
                    showPaywall = false
                }
            }
    }
}

extension View {
    func paywall() -> some View {
        modifier(PayWallViewModifier(showPaywallView: .constant(true)))
    }
}
