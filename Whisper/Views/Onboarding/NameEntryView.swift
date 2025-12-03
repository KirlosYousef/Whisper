//
//  NameEntryView.swift
//  Whisper
//
//  Created by Kirlos Yousef on 3/12/2025.
//

import SwiftUI

struct NameEntryView: View {
    @Binding var userName: String
    let isValid: Bool
    let onSubmit: () -> Void
    let onUserNameChanged: ((String) -> Void)?
    
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTextFieldFocused: Bool
    
    init(
        userName: Binding<String>,
        isValid: Bool,
        onSubmit: @escaping () -> Void,
        onUserNameChanged: ((String) -> Void)? = nil
    ) {
        self._userName = userName
        self.isValid = isValid
        self.onSubmit = onSubmit
        self.onUserNameChanged = onUserNameChanged
    }
    
    private var primaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Title
            VStack(spacing: 12) {
                Text("What's your name?")
                    .font(.app(.semibold, size: 28))
                    .foregroundColor(.primary)
                
                Text("We'll use this to personalize your experience")
                    .font(.app(.regular, size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            // Text field
            VStack(alignment: .leading, spacing: 8) {
                TextField("Enter your name", text: $userName)
                    .font(.app(.regular, size: 17))
                    .foregroundColor(.primary)
                    .padding()
                    .background(
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
                    )
                    .cornerRadius(AppTheme.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                            .stroke(
                                isTextFieldFocused ? primaryColor : AppTheme.cardStroke,
                                lineWidth: isTextFieldFocused ? 2 : 1
                            )
                    )
                    .focused($isTextFieldFocused)
                    .onChange(of: userName) { _, newValue in
                        onUserNameChanged?(newValue)
                    }
                    .onSubmit {
                        if isValid {
                            onSubmit()
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                
                if !userName.isEmpty && !isValid {
                    Text("Name must be between 1 and 50 characters")
                        .font(.app(.regular, size: 13))
                        .foregroundColor(.red)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Submit button
            Button(action: {
                HapticsManager.shared.impact(.medium)
                onSubmit()
            }) {
                Text("Continue")
                    .font(.app(.semibold, size: 17))
                    .foregroundColor(isValid ? (colorScheme == .dark ? .black : .white) : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        isValid ? primaryColor : Color.gray.opacity(0.3)
                    )
                    .cornerRadius(AppTheme.cornerRadius)
            }
            .disabled(!isValid)
            .padding(.horizontal)
            .padding(.bottom, 48)
        }
        .background(AppTheme.background(colorScheme).ignoresSafeArea())
        .onAppear {
            // Focus text field after a short delay for better UX
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isTextFieldFocused = true
            }
        }
    }
}

