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
    let onResetPanelPosition: () -> Void
    /// Settings owns the destructive history actions; the store itself lives in
    /// the app delegate.
    let historyAdmin: HistoryAdmin

    // Same UserDefaults keys Preferences uses.
    @AppStorage("insertionMode") private var insertionMode = OutputRouter.InsertionMode.paste.rawValue
    @AppStorage("playsSounds") private var playsSounds = true
    @AppStorage("includesSystemAudio") private var includesSystemAudio = false
    @AppStorage("localeIdentifier") private var localeIdentifier = ""
    @AppStorage("keepsTranscriptHistory") private var keepsTranscriptHistory = true
    @AppStorage("keepsAudioRecordings") private var keepsAudioRecordings = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("audioStorageCapBytes") private var audioStorageCapBytes = 1_073_741_824
    @State private var confirmingDeleteAll = false
    @State private var storage = HistoryAdmin.Storage(entryCount: 0, audioBytes: 0)
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
        // A two-column grid rather than `Form`: labels right-aligned in one
        // column, every control starting on the same left edge in the other.
        // `Form` only lines things up for rows that carry their own label,
        // and nested labelled pickers and bare toggles broke the edge.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            row("Shortcut") {
                ShortcutRecorderView(rebinder: rebinder)
            }

            row("Language") {
                Picker("Language", selection: $localeIdentifier) {
                    Text("System (\(displayName(for: Locale.current)))").tag("")
                    if !localeOptions.isEmpty {
                        Divider()
                    }
                    ForEach(localeOptions) { option in
                        Text(option.installed ? option.name : "\(option.name) (downloads on first use)")
                            .tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            row("Output") {
                Picker("Output", selection: $insertionMode) {
                    Text("Paste into the active app").tag(OutputRouter.InsertionMode.paste.rawValue)
                    Text("Copy to the clipboard only").tag(OutputRouter.InsertionMode.clipboardOnly.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            row("Audio") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include system audio (use headphones)", isOn: $includesSystemAudio)
                    if includesSystemAudio {
                        // A denial can't be detected — the tap just records
                        // silence — so the way to fix it stays in view.
                        Button("Open Privacy Settings…") {
                            openPrivacyPane("Privacy_ScreenCapture")
                        }
                    }
                    Toggle("Play start and stop sounds", isOn: $playsSounds)
                }
            }

            row("Panel") {
                Button("Reset Position", action: onResetPanelPosition)
            }

            row("Login") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open at login", isOn: $launchAtLogin)
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            row("Accessibility") {
                if accessibilityTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Required for direct insertion.")
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility Settings…") {
                            openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                }
            }

            sectionDivider

            row("History") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Keep dictations", isOn: $keepsTranscriptHistory)
                    Toggle("Keep audio (about 11 MB per hour)", isOn: $keepsAudioRecordings)
                        .disabled(!keepsTranscriptHistory)
                }
            }

            row("Delete after") {
                Picker("Delete after", selection: $historyRetentionDays) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!keepsTranscriptHistory)
            }

            row("Audio limit") {
                Picker("Audio limit", selection: $audioStorageCapBytes) {
                    Text("No limit").tag(0)
                    Text("500 MB").tag(524_288_000)
                    Text("1 GB").tag(1_073_741_824)
                    Text("5 GB").tag(5_368_709_120)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!keepsTranscriptHistory || !keepsAudioRecordings)
            }

            row("Stored") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(storageSummary)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open History…", action: onOpenHistory)
                        Button("Reveal Folder", action: revealStorageFolder)
                        Button("Export…", action: exportHistory)
                        Button("Delete All…") {
                            confirmingDeleteAll = true
                        }
                    }
                }
            }

        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .onReceive(trustRefresh) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            setLaunchAtLogin(enabled)
        }
        .onChange(of: historyRetentionDays) { _, _ in
            historyAdmin.prune()
            storage = historyAdmin.storage()
        }
        .onChange(of: audioStorageCapBytes) { _, _ in
            historyAdmin.prune()
            storage = historyAdmin.storage()
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmingDeleteAll) {
            Button("Delete \(storage.entryCount) Transcripts and All Audio", role: .destructive) {
                historyAdmin.deleteAll()
                storage = historyAdmin.storage()
            }
        } message: {
            Text("This can't be undone. Export first if you want a copy.")
        }
        .task {
            storage = historyAdmin.storage()
            await loadLocales()
        }
    }

    /// One grid row: the label right-aligned in the first column, the
    /// control leading-aligned in the second.
    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            content()
                .gridColumnAlignment(.leading)
        }
    }

    private var sectionDivider: some View {
        Divider()
            .gridCellColumns(2)
            .padding(.vertical, 4)
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private var storageSummary: String {
        let entries = storage.entryCount == 1 ? "1 transcript" : "\(storage.entryCount) transcripts"
        guard storage.audioBytes > 0 else { return "\(entries), no audio kept." }
        let size = ByteCountFormatStyle(style: .file).format(storage.audioBytes)
        return "\(entries), \(size) of audio."
    }

    private func exportHistory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to write one Markdown file per dictation, plus history.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            historyAdmin.export(url)
        }
    }

    /// Opens `~/Documents/Transcriber`, which holds the history store and (from
    /// M3) retained audio.
    private func revealStorageFolder() {
        do {
            let url = try AppDirectories.ensure(AppDirectories.root)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSWorkspace.shared.open(AppDirectories.root.deletingLastPathComponent())
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

/// The history operations Settings needs, as closures — same pattern as
/// `ShortcutRebinder`, so the view never reaches for the store.
@MainActor
struct HistoryAdmin {
    struct Storage {
        let entryCount: Int
        let audioBytes: Int64
    }

    var storage: () -> Storage
    var prune: () -> Void
    var deleteAll: () -> Void
    var export: (URL) -> Void

    static let noop = HistoryAdmin(storage: { Storage(entryCount: 0, audioBytes: 0) },
                                   prune: {},
                                   deleteAll: {},
                                   export: { _ in })
}

#Preview {
    SettingsView(rebinder: .noop,
                 onOpenHistory: {},
                 onResetPanelPosition: {},
                 historyAdmin: .noop)
}
