//
//  RetranscribeSheet.swift
//  Transcriber
//

import Speech
import SwiftUI

/// Re-runs transcription on a retained recording — the fix for "the model heard
/// the wrong language", and a way to benefit from a better model later.
struct RetranscribeSheet: View {
    let originalLocaleIdentifier: String
    /// Runs the transcription. Returns the new text, or throws.
    let run: (_ locale: Locale, _ replace: Bool) async throws -> String
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var localeIdentifier = ""
    @State private var replace = true
    @State private var locales: [LocaleOption] = []
    @State private var progress: Double?
    @State private var errorMessage: String?

    private struct LocaleOption: Identifiable {
        let id: String
        let name: String
    }

    private var isRunning: Bool { progress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe Again")
                .font(.headline)

            Form {
                Picker("Language", selection: $localeIdentifier) {
                    ForEach(locales) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(isRunning)

                Picker("Result", selection: $replace) {
                    Text("Replace this transcript").tag(true)
                    Text("Save as a new entry").tag(false)
                }
                .pickerStyle(.radioGroup)
                .disabled(isRunning)
            }

            if isRunning {
                ProgressView(value: progress ?? 0)
                    .progressViewStyle(.linear)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Button("Transcribe") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || localeIdentifier.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            await loadLocales()
        }
    }

    private func loadLocales() async {
        let supported = await SpeechTranscriber.supportedLocales
        locales = supported
            .map { locale in
                let id = locale.identifier(.bcp47)
                return LocaleOption(id: id,
                                    name: Locale.current.localizedString(forIdentifier: locale.identifier) ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Default to what it was transcribed as, so the picker is a change, not
        // a guess.
        if locales.contains(where: { $0.id == originalLocaleIdentifier }) {
            localeIdentifier = originalLocaleIdentifier
        } else {
            localeIdentifier = locales.first?.id ?? ""
        }
    }

    private func start() {
        errorMessage = nil
        progress = 0
        let locale = Locale(identifier: localeIdentifier)
        let replace = replace
        Task {
            do {
                _ = try await run(locale, replace)
                onFinished()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                progress = nil
            }
        }
    }
}
