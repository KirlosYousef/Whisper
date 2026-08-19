//
//  SpeakerRosterView.swift
//  Whisper
//

import SwiftUI

struct SpeakerRosterView: View {
    let recording: Recording
    @Binding var focusedSpeakerKey: String?
    var onNameChange: (String, String) -> Void
    var onEditingEnded: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: String?
    @State private var draftNames: [String: String] = [:]

    private var speakerKeys: [String] {
        recording.speakerKeysInAppearanceOrder()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speakers")
                    .font(.app(.semibold, size: 16))
                Text("\(speakerKeys.count)")
                    .font(.app(.medium, size: 13))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
            }

            Text("Name each person. Every line they spoke updates instantly.")
                .font(.app(.regular, size: 13))
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                ForEach(Array(speakerKeys.enumerated()), id: \.element) { index, key in
                    speakerRow(key: key, index: index)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .onAppear(perform: loadDrafts)
        .onChange(of: recording.speakerDisplayNamesJSON) { _, _ in
            if focusedField == nil {
                loadDrafts()
            }
        }
        .onChange(of: focusedSpeakerKey) { _, newValue in
            focusedField = newValue
        }
        .onChange(of: focusedField) { _, newValue in
            if focusedSpeakerKey != newValue {
                focusedSpeakerKey = newValue
            }
            if newValue == nil {
                onEditingEnded()
            }
        }
    }

    private func speakerRow(key: String, index: Int) -> some View {
        let placeholder = "Speaker \(index + 1)"
        let isFocused = focusedField == key
        let turns = recording.turnCount(for: key)
        let snippet = recording.snippet(for: key)
        let current = draftNames[key] ?? ""
        let display = current.isEmpty ? placeholder : current

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(SpeakerStyle.color(for: key))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(SpeakerStyle.initial(for: display))
                            .font(.app(.semibold, size: 14))
                            .foregroundColor(.white)
                    )
                    .scaleEffect(isFocused ? 1.06 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isFocused)

                VStack(alignment: .leading, spacing: 2) {
                    TextField(placeholder, text: nameBinding(for: key))
                        .font(.app(.semibold, size: 17))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: key)
                        .onSubmit {
                            focusedField = nil
                        }

                    Text(turns == 1 ? "1 turn" : "\(turns) turns")
                        .font(.app(.regular, size: 12))
                        .foregroundColor(.secondary)
                }

                if current.isEmpty {
                    Text("Add name")
                        .font(.app(.medium, size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }

            if !snippet.isEmpty {
                Text(snippet)
                    .font(.app(.regular, size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 48)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                .fill(isFocused
                      ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                .stroke(
                    isFocused ? Color.primary.opacity(0.35) : AppTheme.cardStroke,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = key
            focusedSpeakerKey = key
        }
    }

    private func nameBinding(for key: String) -> Binding<String> {
        Binding(
            get: { draftNames[key] ?? "" },
            set: { newValue in
                draftNames[key] = newValue
                withAnimation(.easeInOut(duration: 0.2)) {
                    onNameChange(key, newValue)
                }
            }
        )
    }

    private func loadDrafts() {
        var next: [String: String] = [:]
        for key in speakerKeys {
            let current = recording.displayName(for: key)
            next[key] = current.hasPrefix("Speaker ") ? "" : current
        }
        draftNames = next
    }
}
