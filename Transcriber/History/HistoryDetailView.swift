//
//  HistoryDetailView.swift
//  Transcriber
//

import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One archived dictation: its transcript, where it went, and what can be done
/// with it now.
struct HistoryDetailView: View {
    let entry: HistoryEntry
    let actions: HistoryActions
    let onDelete: () -> Void
    let onDeleteAudio: () -> Void
    let onTogglePin: () -> Void

    @State private var playback = AudioPlaybackController()
    /// Transient result of the last action, e.g. "Copied to the clipboard".
    @State private var feedback: String?
    @State private var isInserting = false
    @State private var isRetranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            metadata

            ScrollView {
                transcript
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if entry.audioFilename != nil || playback.isUnavailable {
                audioSection
            }

            actionBar
        }
        .padding(16)
        .id(entry.persistentModelID)
        .task(id: entry.persistentModelID) {
            feedback = nil
            playback.load(filename: entry.audioFilename)
        }
        .onDisappear {
            playback.stop()
        }
        .sheet(isPresented: $isRetranscribing) {
            RetranscribeSheet(originalLocaleIdentifier: entry.localeIdentifier,
                              run: { locale, replace in
                                  try await actions.retranscribe(entry, locale, replace)
                              },
                              onFinished: {
                                  feedback = "Transcribed again"
                                  playback.load(filename: entry.audioFilename)
                              })
        }
    }

    // MARK: - Transcript

    /// While audio is playing, the sentence being spoken is highlighted — the
    /// stored segment ranges are sample-aligned with the recording, so this
    /// needs no extra analysis.
    private var transcript: some View {
        Text(highlightedText)
            .font(.system(size: 13))
            .textSelection(.enabled)
    }

    private var highlightedText: AttributedString {
        guard playback.isPlaying, !entry.segments.isEmpty else {
            return AttributedString(entry.text)
        }
        var result = AttributedString()
        let now = playback.currentTime
        for segment in entry.segments {
            var piece = AttributedString(segment.text)
            if now >= segment.start && now < segment.end {
                piece.backgroundColor = .yellow.opacity(0.35)
            }
            result += piece
        }
        // Segments only cover committed speech; if they came out short, don't
        // quietly show less than the transcript.
        return String(result.characters).count == entry.text.count ? result : AttributedString(entry.text)
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                    .font(.headline)
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                        .help("Pinned — never deleted automatically")
                }
            }
            HStack(spacing: 6) {
                Text(HistoryFormat.duration(entry.duration))
                Text("·")
                Text(languageName)
                if let app = entry.targetAppName {
                    Text("·")
                    Text(app)
                }
                if let outcome = outcomeDescription {
                    Text("·")
                    Text(outcome)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if entry.isPartial {
                Label("Cut short by an error — this may not be everything that was said.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if entry.audioPrunedAt != nil {
                Label("The recording was deleted to stay under the audio storage limit.",
                      systemImage: "externaldrive.badge.minus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        if playback.isUnavailable {
            Label("Audio no longer available", systemImage: "waveform.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 14)
                    }
                    .keyboardShortcut(" ", modifiers: [])
                    .help(playback.isPlaying ? "Pause" : "Play")

                    Slider(value: Binding(get: { playback.currentTime },
                                          set: { playback.seek(to: $0) }),
                           in: 0...max(playback.duration, 0.01))

                    Text("\(HistoryFormat.duration(playback.currentTime)) / \(HistoryFormat.duration(playback.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Picker("Speed", selection: $playback.rate) {
                        Text("1×").tag(Float(1))
                        Text("1.5×").tag(Float(1.5))
                        Text("2×").tag(Float(2))
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Transcribe Again…") { isRetranscribing = true }
                    Button("Save Audio…", action: saveAudio)
                    Button("Reveal", action: revealAudio)
                    Button("Delete Audio") {
                        playback.stop()
                        onDeleteAudio()
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack {
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(entry.isPinned ? "Unpin" : "Pin", action: onTogglePin)
            Button("Delete", role: .destructive) {
                playback.stop()
                onDelete()
            }
            Button("Save…", action: saveTranscript)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                feedback = "Copied to the clipboard"
            }
            Button("Insert Again", action: insert)
                .keyboardShortcut(.defaultAction)
                .disabled(isInserting)
        }
    }

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: entry.localeIdentifier) ?? entry.localeIdentifier
    }

    private var outcomeDescription: String? {
        guard let raw = entry.deliveryOutcomeRaw,
              let outcome = OutputRouter.Outcome(rawValue: raw) else { return nil }
        switch outcome {
        case .inserted: return "Inserted"
        case .copiedToClipboard: return "Copied"
        }
    }

    private func insert() {
        isInserting = true
        let text = entry.text
        Task {
            let outcome = await actions.insert(text)
            feedback = switch outcome {
            case .inserted: "Inserted into the app you were last in"
            case .copiedToClipboard: "Copied to the clipboard"
            }
            isInserting = false
        }
    }

    private func saveTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(baseFilename).txt"
        let text = entry.text
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.presentFailure("Couldn't save transcript", error)
            }
        }
    }

    private func saveAudio() {
        guard let filename = entry.audioFilename else { return }
        let source = RecordingsDirectory.url(for: filename)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a") ?? .audio]
        panel.nameFieldStringValue = filename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // The panel already asked about replacing an existing file.
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: source, to: url)
            } catch {
                Self.presentFailure("Couldn't save audio", error)
            }
        }
    }

    private func revealAudio() {
        guard let filename = entry.audioFilename else { return }
        NSWorkspace.shared.activateFileViewerSelecting([RecordingsDirectory.url(for: filename)])
    }

    /// `yyyy-MM-dd HH-mm-ss` — sorts, and safe in a filename.
    private var baseFilename: String {
        "Dictation \(RecordingsDirectory.timestamp(for: entry.createdAt))"
    }

    private static func presentFailure(_ message: String, _ error: any Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
