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

    /// Transient result of the last action, e.g. "Copied" or "Pasted into Notes".
    @State private var feedback: String?
    @State private var isInserting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            metadata

            ScrollView {
                Text(entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionBar
        }
        .padding(16)
        .id(entry.persistentModelID)
        .onChange(of: entry.persistentModelID) { _, _ in
            feedback = nil
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                .font(.headline)
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
        }
    }

    private var actionBar: some View {
        HStack {
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete", role: .destructive, action: onDelete)
            Button("Save…", action: save)
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

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedFilename
        let text = entry.text
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save transcript"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private var suggestedFilename: String {
        // Fixed pattern rather than a localized style: this becomes a filename,
        // so it needs to sort and stay free of "/" and ":".
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Dictation \(formatter.string(from: entry.createdAt)).txt"
    }
}
