//
//  SettingsView.swift
//  Transcriber
//

import ApplicationServices
import Combine
import SwiftUI

struct SettingsView: View {
    // Same UserDefaults key Preferences.insertionMode uses.
    @AppStorage("insertionMode") private var insertionMode = OutputRouter.InsertionMode.paste.rawValue
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    private let trustRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            LabeledContent("Dictation shortcut",
                           value: Preferences.shared.hotkeyShortcut.displayString)

            Picker("Insert text by", selection: $insertionMode) {
                Text("Pasting into the active app").tag(OutputRouter.InsertionMode.paste.rawValue)
                Text("Copying to the clipboard only").tag(OutputRouter.InsertionMode.clipboardOnly.rawValue)
            }
            .pickerStyle(.radioGroup)

            LabeledContent("Accessibility") {
                if accessibilityTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Required for direct insertion; without it, text is copied to the clipboard instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility Settings…") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onReceive(trustRefresh) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }
}

#Preview {
    SettingsView()
}
