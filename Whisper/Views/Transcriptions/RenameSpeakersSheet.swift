//
//  RenameSpeakersSheet.swift
//  Whisper
//

import SwiftUI

struct RenameSpeakersSheet: View {
    let recording: Recording
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var names: [String: String] = [:]

    private var speakerKeys: [String] {
        recording.speakerKeysInAppearanceOrder()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(speakerKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(SpeakerStyle.color(for: key))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Text(SpeakerStyle.initial(for: names[key]?.isEmpty == false ? names[key]! : recording.displayName(for: key)))
                                            .font(.app(.semibold, size: 13))
                                            .foregroundColor(.white)
                                    )
                                TextField(recording.displayName(for: key), text: binding(for: key))
                                    .font(.app(.medium, size: 17))
                                    .textInputAutocapitalization(.words)
                            }
                            let snippet = recording.snippet(for: key)
                            if !snippet.isEmpty {
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .card()
                    }
                }
                .padding()
            }
            .background(AppTheme.background(colorScheme).ignoresSafeArea())
            .navigationTitle("Rename speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                var initial: [String: String] = [:]
                for key in speakerKeys {
                    let current = recording.displayName(for: key)
                    initial[key] = current.hasPrefix("Speaker ") ? "" : current
                }
                names = initial
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { names[key] ?? "" },
            set: { names[key] = $0 }
        )
    }

    private func save() {
        for key in speakerKeys {
            recording.setDisplayName(names[key] ?? "", for: key)
        }
        onSave()
        dismiss()
    }
}
