//
//  SettingsView.swift
//  Transcriber
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Dictation shortcut",
                           value: Preferences.shared.hotkeyShortcut.displayString)
            Text("Shortcut customization arrives in a later phase.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
    }
}

#Preview {
    SettingsView()
}
