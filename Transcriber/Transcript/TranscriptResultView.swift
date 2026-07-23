//
//  TranscriptResultView.swift
//  Transcriber
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File-transcription result: selectable text with Copy and Save actions.
struct TranscriptResultView: View {
    let text: String
    /// Source file name without extension; proposed .txt name on save.
    let sourceName: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    copied = true
                }
                Button("Save…") {
                    save()
                }
                .keyboardShortcut("s")
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = sourceName + ".txt"
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
}

#Preview {
    TranscriptResultView(text: "Example transcript text.", sourceName: "example")
}
