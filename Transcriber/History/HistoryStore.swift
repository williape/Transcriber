//
//  HistoryStore.swift
//  Transcriber
//

import Foundation
import SwiftData
import os

/// Owns the SwiftData container for dictation history and is the only thing that
/// writes to it.
///
/// Writes use the container's main context: an entry is a few hundred bytes, and
/// recording happens *after* delivery, once the panel is already dismissing — so
/// there's nothing to gain from a background context here, and sharing one
/// context means M2's `@Query` views update live for free. Pruning and export
/// (M4), which touch every row, get their own `@ModelActor` then.
@MainActor
final class HistoryStore {
    let container: ModelContainer

    private let preferences: Preferences
    // Static so the convenience initializer can log before `self` exists.
    private static let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "History")

    /// `false` when the user has turned history off, or paused it for now.
    var isRecordingEnabled: Bool {
        preferences.keepsTranscriptHistory && !preferences.historyPaused
    }

    private static var storeURL: URL {
        AppDirectories.root.appending(path: "History.store", directoryHint: .notDirectory)
    }

    /// The app's store, in `~/Documents/Transcriber`.
    convenience init() throws {
        try AppDirectories.ensure(AppDirectories.root)
        // One-time move for anyone who ran the build that kept history in
        // Application Support.
        _ = try? AppDirectories.migrate(from: AppDirectories.legacyRoot, to: AppDirectories.root)
        if AppDirectories.rootIsCloudSynced {
            Self.logger.error("~/Documents is synced to iCloud Drive — transcripts and audio will leave this Mac")
        }
        let url = Self.storeURL
        do {
            try self.init(configuration: ModelConfiguration(url: url))
        } catch {
            // An unreadable store must not cost the user their dictation tool:
            // set it aside (so it can still be recovered by hand) and start
            // fresh rather than failing every launch from here on.
            Self.logger.error("History store unusable, starting fresh: \(error.localizedDescription, privacy: .public)")
            try Self.setAside(url)
            try self.init(configuration: ModelConfiguration(url: url))
        }
        Self.logger.info("History store ready at \(url.path, privacy: .public)")
    }

    /// Explicit configuration — lets tests run against an in-memory store and
    /// their own defaults instead of the user's real ones.
    /// `preferences` defaults to the shared instance — resolved in the body
    /// rather than as a default argument, which would be evaluated off the main
    /// actor.
    init(configuration: ModelConfiguration, preferences: Preferences? = nil) throws {
        self.preferences = preferences ?? .shared
        container = try ModelContainer(for: Schema(versionedSchema: HistorySchemaV1.self),
                                       migrationPlan: HistoryMigrationPlan.self,
                                       configurations: configuration)
    }

    /// Moves the store and its SQLite sidecars out of the way.
    private static func setAside(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = URL(filePath: url.path + ".corrupt-\(stamp)" + suffix)
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// Archives a finished dictation. Silently does nothing when history is off
    /// or paused. Never throws: losing a history entry is not worth interrupting
    /// the user, and the transcript is already on its way to their app.
    func record(_ draft: HistoryDraft) {
        guard isRecordingEnabled else { return }
        let context = container.mainContext
        context.insert(HistoryEntry(draft: draft))
        do {
            try context.save()
            // Never log transcript text — counts and durations only, matching the
            // convention in the rest of the app.
            Self.logger.info("Recorded entry (\(draft.text.count) characters, \(Int(draft.duration))s)")
        } catch {
            context.rollback()
            Self.logger.error("Could not record history entry: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Most recent entries, newest first — backs the menu bar's Recent
    /// Transcripts submenu.
    func recent(limit: Int) -> [HistoryEntry] {
        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        do {
            return try container.mainContext.fetch(descriptor)
        } catch {
            Self.logger.error("Could not fetch recent entries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Total entries. Used for the launch log line and, later, the Settings
    /// storage readout.
    func entryCount() -> Int {
        do {
            return try container.mainContext.fetchCount(FetchDescriptor<HistoryEntry>())
        } catch {
            Self.logger.error("Could not count history entries: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
