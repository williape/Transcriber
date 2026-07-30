//
//  HistoryListView.swift
//  Transcriber
//

import AppKit
import SwiftData
import SwiftUI

struct HistoryListView: View {
    let actions: HistoryActions
    let store: HistoryStore

    @Environment(\.modelContext) private var context
    @Query(sort: \HistoryEntry.createdAt, order: .reverse) private var entries: [HistoryEntry]
    @AppStorage("keepsTranscriptHistory") private var keepsTranscriptHistory = true

    @State private var searchText = ""
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var confirmingBulkDelete = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .confirmationDialog("Delete \(selection.count) transcripts?",
                            isPresented: $confirmingBulkDelete) {
            Button("Delete \(selection.count) Transcripts", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        HistoryRowView(entry: entry)
                            .tag(entry.persistentModelID)
                            .contextMenu {
                                Button("Copy") { copy(entry.text) }
                                Button(entry.isPinned ? "Unpin" : "Pin") { togglePin(entry) }
                                Button("Delete", role: .destructive) { delete([entry]) }
                            }
                    }
                }
            }
        }
        .onDeleteCommand(perform: requestDeleteSelected)
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No Dictations Yet", systemImage: "clock")
            } description: {
                if keepsTranscriptHistory {
                    Text("Finished dictations will appear here.")
                } else {
                    Text("History is turned off in Settings, so nothing is being kept.")
                }
            }
        } else if filteredEntries.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            HistoryDetailView(entry: entry,
                              actions: actions,
                              onDelete: { delete([entry]) },
                              onDeleteAudio: { store.deleteAudio(of: entry) },
                              onTogglePin: { togglePin(entry) })
        } else if selection.count > 1 {
            multipleSelection
        } else {
            ContentUnavailableView("No Transcript Selected",
                                   systemImage: "text.alignleft",
                                   description: Text("Pick a dictation on the left."))
        }
    }

    private var multipleSelection: some View {
        VStack(spacing: 12) {
            Text("\(selection.count) transcripts selected")
                .font(.headline)
            HStack {
                Button("Copy All") {
                    copy(selectedEntries.map(\.text).joined(separator: "\n\n"))
                }
                Button("Delete…", role: .destructive) {
                    confirmingBulkDelete = true
                }
            }
        }
        .padding()
    }

    // MARK: - Data

    private var filteredEntries: [HistoryEntry] {
        guard !searchText.isEmpty else { return entries }
        // `localizedStandardContains` is the case- and diacritic-insensitive
        // comparison Finder uses.
        return entries.filter { entry in
            entry.text.localizedStandardContains(searchText)
                || (entry.targetAppName?.localizedStandardContains(searchText) ?? false)
        }
    }

    private var groups: [HistoryGroup] {
        HistoryGroup.grouped(filteredEntries)
    }

    private var selectedEntries: [HistoryEntry] {
        entries.filter { selection.contains($0.persistentModelID) }
    }

    private var selectedEntry: HistoryEntry? {
        guard selection.count == 1 else { return nil }
        return selectedEntries.first
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func requestDeleteSelected() {
        // One is an obvious, easily-redictated loss; a bulk delete deserves a
        // confirmation.
        if selection.count > 1 {
            confirmingBulkDelete = true
        } else if let entry = selectedEntry {
            delete([entry])
        }
    }

    private func deleteSelected() {
        delete(selectedEntries)
    }

    private func delete(_ doomed: [HistoryEntry]) {
        for entry in doomed {
            selection.remove(entry.persistentModelID)
        }
        // Through the store, so the entry's recording goes with it.
        store.delete(doomed)
    }

    /// Pinned entries survive the age limit and the audio size cap.
    private func togglePin(_ entry: HistoryEntry) {
        entry.isPinned.toggle()
        try? context.save()
    }
}

/// A date bucket in the sidebar.
struct HistoryGroup: Identifiable {
    let id: String
    let title: String
    let entries: [HistoryEntry]

    /// Buckets newest-first entries into Today / Yesterday / This Week / month.
    static func grouped(_ entries: [HistoryEntry]) -> [HistoryGroup] {
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        for entry in entries {
            let title = self.title(for: entry.createdAt)
            if buckets[title] == nil {
                order.append(title)
                buckets[title] = []
            }
            buckets[title]?.append(entry)
        }
        return order.map { HistoryGroup(id: $0, title: $0, entries: buckets[$0] ?? []) }
    }

    private static func title(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now), date > weekAgo {
            return "This Week"
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

private struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = AppIcon.image(forBundleID: entry.targetAppBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.createdAt, format: .dateTime.hour().minute())
                    if let name = entry.targetAppName {
                        Text("· \(name)")
                            .lineLimit(1)
                    }
                    if entry.isPartial {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .help("This transcript was cut short by an error.")
                    }
                    if entry.audioFilename != nil {
                        Image(systemName: "waveform")
                            .help("Audio recording kept")
                    }
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .help("Pinned — never deleted automatically")
                    }
                    Spacer(minLength: 4)
                    Text(HistoryFormat.duration(entry.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(HistoryFormat.snippet(entry.text))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Shared formatting so the row, the detail pane and the menu agree.
enum HistoryFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func snippet(_ text: String, limit: Int = 80) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Icons are looked up by bundle ID and cached — a row redraw shouldn't hit the
/// filesystem.
@MainActor
enum AppIcon {
    private static var cache: [String: NSImage?] = [:]

    static func image(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}
