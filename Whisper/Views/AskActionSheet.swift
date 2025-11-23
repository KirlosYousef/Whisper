//
//  AskActionSheet.swift
//  Whisper
//
//  Created by Kirlos Yousef on 24/11/2025.
//

import SwiftUI
import SwiftData
import UIKit

struct AskActionSheet: View {
	@Environment(\.colorScheme) private var colorScheme
	
	let recording: Recording
	let run: (Recording, String) async -> String
	let onDismiss: () -> Void
	
	@State private var prompt: String = ""
	@State private var isLoading: Bool = false
	@State private var result: String = ""
	@State private var showAlert: Bool = false
	@State private var alertMessage: String = ""
	
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header
			inputCard
			resultSection
		}
		.padding()
		.background(AppTheme.background(colorScheme).ignoresSafeArea())
		.alert(alertMessage, isPresented: $showAlert) {
			Button("OK", role: .cancel) {}
		}
		.safeAreaInset(edge: .bottom) {
			controls
				.padding(.horizontal)
				.padding(.bottom, 12)
				.background(AppTheme.background(colorScheme).opacity(0.98))
		}
	}
	
	@ViewBuilder
	private var closeButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .foregroundColor(.secondary)
    }
	
	@ViewBuilder
	private var header: some View {
        HStack {
            Text("Ask or Act")
                .font(.app(.bold, size: 20))
            
            if let title = recording.title, !title.isEmpty {
                Text(title)
                    .font(.app(.regular, size: 14))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            closeButton
        }
        .padding(.top)
	}
	
	private var inputCard: some View {
		VStack(alignment: .leading, spacing: 8) {
			ZStack(alignment: .topLeading) {
				TextEditor(text: $prompt)
					.font(.app(.regular, size: 16))
					.frame(minHeight: 120)
					.padding(.top, 8)
				
				if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					Text("Type a question or command…")
						.font(.app(.regular, size: 16))
						.foregroundColor(.secondary)
						.padding(.top, 14)
						.allowsHitTesting(false)
				}
			}
			
			HStack {
				Spacer()
				if !prompt.isEmpty {
					Button {
						prompt = ""
					} label: {
						Label("Clear", systemImage: "xmark.circle.fill")
					}
					.font(.app(.regular, size: 14))
					.foregroundColor(.secondary)
				}
			}
		}
        .card()
	}
	
	private var controls: some View {
		HStack {
			Button("Cancel") {
				onDismiss()
			}
			.font(.app(.regular, size: 16))
			
			Spacer()
			
			Button {
				runPrompt()
			} label: {
				if isLoading {
					HStack(spacing: 8) {
						ProgressView()
						Text("Running…")
					}
				} else {
					Text("Run")
				}
			}
			.font(.app(.semibold, size: 16))
			.buttonStyle(.borderedProminent)
			.disabled(isLoading || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		}
	}
	
	@ViewBuilder
	private var resultSection: some View {
		if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			VStack(alignment: .leading, spacing: 12) {
				Text("Result")
					.font(.app(.semibold, size: 14))
					.foregroundColor(.secondary)
				Text(result)
					.font(.app(.regular, size: 16))
					.fixedSize(horizontal: false, vertical: true)
				
				HStack {
					Button {
						UIPasteboard.general.string = result
						alertMessage = "Copied to clipboard"
						showAlert = true
					} label: {
						Label("Copy", systemImage: "doc.on.doc")
					}
					.font(.app(.regular, size: 14))
					
					Spacer()
					
					ShareLink(item: result) {
						Label("Share", systemImage: "square.and.arrow.up")
					}
					.font(.app(.regular, size: 14))
				}
				.padding(.top, 2)
			}
			.card(color: Color(.label.withAlphaComponent(0.04)))
		}
	}
	
	private func runPrompt() {
		let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		isLoading = true
		result = ""
		Task {
			let response = await run(recording, trimmed)
			await MainActor.run {
				result = response
				isLoading = false
				if response.isEmpty {
					alertMessage = "No result returned"
					showAlert = true
				}
			}
		}
	}
}


