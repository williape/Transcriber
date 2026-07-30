//
//  SettingsView.swift
//  Transcriber
//

import ApplicationServices
import Combine
import ServiceManagement
import Speech
import SwiftUI

struct SettingsView: View {
    let rebinder: ShortcutRebinder
    let onOpenHistory: () -> Void

    // Same UserDefaults keys Preferences uses.
    @AppStorage("insertionMode") private var insertionMode = OutputRouter.InsertionMode.paste.rawValue
    @AppStorage("playsSounds") private var playsSounds = true
    @AppStorage("localeIdentifier") private var localeIdentifier = ""
    @AppStorage("keepsTranscriptHistory") private var keepsTranscriptHistory = true
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var localeOptions: [LocaleOption] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private let trustRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private struct LocaleOption: Identifiable {
        let id: String       // bcp47 identifier
        let name: String
        let installed: Bool
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            history
                .tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 500)
    }

    private var general: some View {
        Form {
            LabeledContent("Dictation shortcut") {
                ShortcutRecorderView(rebinder: rebinder)
            }

            Picker("Language", selection: $localeIdentifier) {
                Text("System (\(displayName(for: Locale.current)))").tag("")
                if !localeOptions.isEmpty {
                    Divider()
                }
                ForEach(localeOptions) { option in
                    Text(option.installed ? option.name : "\(option.name) — downloads on first use")
                        .tag(option.id)
                }
            }

            Picker("Insert text by", selection: $insertionMode) {
                Text("Pasting into the active app").tag(OutputRouter.InsertionMode.paste.rawValue)
                Text("Copying to the clipboard only").tag(OutputRouter.InsertionMode.clipboardOnly.rawValue)
            }
            .pickerStyle(.radioGroup)

            Toggle("Play sounds when dictation starts and stops", isOn: $playsSounds)

            LabeledContent("Launch at login") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Start Transcriber when you log in", isOn: $launchAtLogin)
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

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
        .onReceive(trustRefresh) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            setLaunchAtLogin(enabled)
        }
        .task {
            await loadLocales()
        }
    }

    private var history: some View {
        Form {
            LabeledContent("Dictation history") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep finished dictations", isOn: $keepsTranscriptHistory)
                    Button("Open History…") {
                        onOpenHistory()
                    }
                }
            }

            LabeledContent("Stored in") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("~/Library/Application Support/\(Bundle.main.bundleIdentifier ?? "Transcriber")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Reveal in Finder") {
                        revealStorageFolder()
                    }
                }
            }
        }
        .padding(20)
    }

    private func revealStorageFolder() {
        do {
            let url = try AppDirectories.ensure(AppDirectories.support)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSWorkspace.shared.open(AppDirectories.support.deletingLastPathComponent())
        }
    }

    private func loadLocales() async {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        localeOptions = supported
            .map { locale in
                let id = locale.identifier(.bcp47)
                return LocaleOption(id: id,
                                    name: displayName(for: locale),
                                    installed: installed.contains(id))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView(rebinder: .noop, onOpenHistory: {})
}
