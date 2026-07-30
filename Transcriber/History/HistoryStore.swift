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

    /// Total entries. Used for the launch log line and the Settings storage
    /// readout.
    func entryCount() -> Int {
        do {
            return try container.mainContext.fetchCount(FetchDescriptor<HistoryEntry>())
        } catch {
            Self.logger.error("Could not count history entries: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func allEntries() -> [HistoryEntry] {
        do {
            return try container.mainContext.fetch(
                FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        } catch {
            Self.logger.error("Could not fetch entries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Deletion

    /// Deletes entries and any audio they own.
    func delete(_ doomed: [HistoryEntry]) {
        guard !doomed.isEmpty else { return }
        let context = container.mainContext
        for entry in doomed {
            if let filename = entry.audioFilename {
                RecordingsDirectory.delete(filename: filename)
            }
            context.delete(entry)
        }
        save(context, describing: "delete \(doomed.count) entries")
    }

    /// Drops an entry's recording but keeps its transcript.
    func deleteAudio(of entry: HistoryEntry, pruned: Bool = false) {
        guard let filename = entry.audioFilename else { return }
        RecordingsDirectory.delete(filename: filename)
        entry.audioFilename = nil
        entry.audioByteCount = nil
        entry.audioPrunedAt = pruned ? Date() : nil
        save(container.mainContext, describing: "delete audio")
    }

    /// Everything: entries, and every file in the recordings folder — including
    /// any orphans, which is the point of doing it by folder rather than by row.
    func deleteAll() {
        let context = container.mainContext
        let all = allEntries()
        for entry in all {
            context.delete(entry)
        }
        save(context, describing: "delete all history")
        RecordingsDirectory.deleteAllRecordings()
        Self.logger.info("Deleted all history (\(all.count) entries)")
    }

    // MARK: - Re-transcription

    /// Stores a fresh transcript for `entry`, either replacing its text or
    /// creating a sibling entry.
    ///
    /// A new entry gets its **own copy** of the audio: sharing one file would
    /// mean deleting either entry strands the other. Segments are dropped —
    /// `FileTranscriber` doesn't report them, and stale ranges would highlight
    /// the wrong words during playback.
    func applyRetranscription(_ text: String,
                              locale: Locale,
                              to entry: HistoryEntry,
                              replace: Bool) {
        let identifier = locale.identifier(.bcp47)
        if replace {
            entry.text = text
            entry.localeIdentifier = identifier
            entry.segments = []
            entry.isPartial = false
            save(container.mainContext, describing: "replace transcript")
            Self.logger.info("Replaced transcript (\(text.count) characters, \(identifier, privacy: .public))")
            return
        }

        var audio: SessionAudioRecorder.Recorded?
        if let filename = entry.audioFilename {
            audio = try? RecordingsDirectory.duplicate(filename: filename)
        }
        let draft = HistoryDraft(text: text,
                                 localeIdentifier: identifier,
                                 duration: entry.duration,
                                 isPartial: false,
                                 targetAppBundleID: entry.targetAppBundleID,
                                 targetAppName: entry.targetAppName,
                                 deliveryOutcomeRaw: nil,
                                 audioFilename: audio?.filename,
                                 audioByteCount: audio?.byteCount,
                                 segments: [])
        // Bypasses `record`: the user explicitly asked for this entry, so the
        // history on/off toggle isn't the right gate.
        let context = container.mainContext
        context.insert(HistoryEntry(draft: draft))
        save(context, describing: "save re-transcription")
        Self.logger.info("Saved re-transcription as a new entry (\(text.count) characters)")
    }

    // MARK: - Pruning and reconciliation

    private func candidates() -> [PruneCandidate] {
        allEntries().map {
            PruneCandidate(id: $0.id,
                           createdAt: $0.createdAt,
                           audioFilename: $0.audioFilename,
                           audioByteCount: $0.audioByteCount ?? 0,
                           isPinned: $0.isPinned)
        }
    }

    /// Applies the age limit and the audio size cap. Cheap enough to run at
    /// launch and after each recorded dictation.
    func prune() {
        let entries = allEntries()
        guard !entries.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let candidates = candidates()

        let expired = HistoryPruningPolicy.expired(candidates,
                                                   retentionDays: preferences.historyRetentionDays)
        if !expired.isEmpty {
            delete(expired.compactMap { byID[$0] })
            Self.logger.info("Pruned \(expired.count) expired entries")
        }

        // Recompute: the age pass may already have freed enough audio.
        let remaining = candidates.filter { !expired.contains($0.id) }
        let reclaim = HistoryPruningPolicy.audioToReclaim(remaining,
                                                          capBytes: preferences.audioStorageCapBytes)
        for id in reclaim {
            guard let entry = byID[id] else { continue }
            deleteAudio(of: entry, pruned: true)
        }
        if !reclaim.isEmpty {
            Self.logger.info("Reclaimed audio from \(reclaim.count) entries to stay under the size cap")
        }
    }

    /// Reconciles the store against the recordings folder: files nobody owns are
    /// deleted, and entries whose file has gone (deleted in Finder, or a session
    /// killed before the `.m4a` was finalized) lose their audio reference.
    func reconcileRecordings() {
        let entries = allEntries()
        let referenced = Set(entries.compactMap(\.audioFilename))
        let onDisk = RecordingsDirectory.recordingFilenames()

        for entry in entries where entry.audioFilename != nil {
            guard let filename = entry.audioFilename, !onDisk.contains(filename) else { continue }
            entry.audioFilename = nil
            entry.audioByteCount = nil
        }

        var orphansRemoved = 0
        for filename in onDisk where !referenced.contains(filename) {
            // A file younger than a minute is probably a recording in flight,
            // not an orphan.
            guard RecordingsDirectory.age(of: filename) > 60 else { continue }
            RecordingsDirectory.delete(filename: filename)
            orphansRemoved += 1
        }

        save(container.mainContext, describing: "reconcile recordings")
        if orphansRemoved > 0 {
            Self.logger.info("Removed \(orphansRemoved) orphaned recordings")
        }
    }

    // MARK: - Export

    /// Writes one Markdown file per entry plus a `history.json` manifest, so the
    /// SwiftData store is never the only copy. Returns the number exported.
    @discardableResult
    func export(to directory: URL) throws -> Int {
        let entries = allEntries()
        try AppDirectories.ensure(directory)

        for entry in entries {
            let stamp = RecordingsDirectory.timestamp(for: entry.createdAt)
            var body = "# Dictation \(stamp)\n\n"
            body += "- Duration: \(Int(entry.duration.rounded()))s\n"
            body += "- Language: \(entry.localeIdentifier)\n"
            if let app = entry.targetAppName {
                body += "- Inserted into: \(app)\n"
            }
            if let audio = entry.audioFilename {
                body += "- Audio: \(audio)\n"
            }
            if entry.isPartial {
                body += "- Incomplete: cut short by an error\n"
            }
            body += "\n\(entry.text)\n"
            let url = uniqueURL(in: directory, named: "\(stamp).md")
            try Data(body.utf8).write(to: url)
        }

        let manifest = entries.map(ExportedEntry.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: directory.appending(path: "history.json", directoryHint: .notDirectory))

        Self.logger.info("Exported \(entries.count) entries")
        return entries.count
    }

    private func uniqueURL(in directory: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var attempt = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) {
            candidate = "\(base) (\(attempt)).\(ext)"
            attempt += 1
        }
        return directory.appending(path: candidate, directoryHint: .notDirectory)
    }

    // MARK: - Saving

    private func save(_ context: ModelContext, describing action: String) {
        do {
            try context.save()
        } catch {
            context.rollback()
            Self.logger.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Flat, stable shape for `history.json` — deliberately independent of the
/// `@Model`, so an export from today still reads after a schema change.
private struct ExportedEntry: Encodable {
    let id: UUID
    let createdAt: Date
    let text: String
    let localeIdentifier: String
    let duration: TimeInterval
    let isPartial: Bool
    let isPinned: Bool
    let targetAppBundleID: String?
    let targetAppName: String?
    let deliveryOutcome: String?
    let audioFilename: String?
    let audioByteCount: Int64?
    let segments: [TranscriptSegment]

    init(_ entry: HistoryEntry) {
        id = entry.id
        createdAt = entry.createdAt
        text = entry.text
        localeIdentifier = entry.localeIdentifier
        duration = entry.duration
        isPartial = entry.isPartial
        isPinned = entry.isPinned
        targetAppBundleID = entry.targetAppBundleID
        targetAppName = entry.targetAppName
        deliveryOutcome = entry.deliveryOutcomeRaw
        audioFilename = entry.audioFilename
        audioByteCount = entry.audioByteCount
        segments = entry.segments
    }
}
