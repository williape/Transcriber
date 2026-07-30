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

    private static let storeName = "History.store"

    private static var storeURL: URL {
        AppDirectories.root.appending(path: storeName, directoryHint: .notDirectory)
    }

    /// The app's store, in `~/Documents/Transcriber`.
    convenience init() throws {
        try AppDirectories.ensure(AppDirectories.root)
        // One-time move for anyone who ran the build that kept history in
        // Application Support.
        try Self.migrateLegacyRoot()
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

    enum MigrationError: LocalizedError {
        case storeLeftBehind(URL)

        var errorDescription: String? {
            switch self {
            case .storeLeftBehind(let url):
                return "The existing history store could not be moved out of \(url.path)."
            }
        }
    }

    /// Brings anything left in the old Application Support folder across, then
    /// refuses to go on if the store didn't make it.
    private static func migrateLegacyRoot() throws {
        do {
            try AppDirectories.migrate(from: AppDirectories.legacyRoot, to: AppDirectories.root)
        } catch {
            // Not rethrown here: what matters isn't whether *something* failed
            // but whether the store specifically is still back there, which the
            // check below establishes either way.
            logger.error("Migration incomplete: \(error.localizedDescription, privacy: .public)")
        }
        try verifyStoreMigrated()
    }

    /// The condition that has to hold before the store at the new location may
    /// be opened: the old one must be gone from the legacy folder. Opening a
    /// fresh store beside a legacy one hides the user's history behind an empty
    /// list, and — the destination now existing — stops the move ever being
    /// retried.
    ///
    /// Deliberately run after *every* attempt rather than only a throwing one: a
    /// family is also skipped without error when part of it is already at the
    /// destination (a stray `-shm` there, say), and a rollback that itself fails
    /// can leave the store behind without `migrate` knowing.
    ///
    /// `legacy` is a parameter only so tests can point it somewhere harmless.
    static func verifyStoreMigrated(in legacy: URL = AppDirectories.legacyRoot) throws {
        let manager = FileManager.default
        let legacyStore = legacy.appending(path: storeName, directoryHint: .notDirectory)
        guard !manager.fileExists(atPath: legacyStore.path) else {
            // History is unavailable for this run (AppDelegate says so) and the
            // old data is untouched, ready for the next launch to try again.
            throw MigrationError.storeLeftBehind(legacy)
        }
        // A sidecar whose store has already moved holds no history anyone can
        // open, so it isn't hiding anything — but the store that did move may be
        // missing the transactions in it, which is worth saying out loud.
        let strays = AppDirectories.sidecarSuffixes
            .map { storeName + $0 }
            .filter { manager.fileExists(atPath: legacy.appending(path: $0).path) }
        if !strays.isEmpty {
            logger.error("Left behind in the old folder: \(strays.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Moves the store and its SQLite sidecars out of the way.
    private static func setAside(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in [""] + AppDirectories.sidecarSuffixes {
            let source = URL(filePath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = URL(filePath: url.path + ".corrupt-\(stamp)" + suffix)
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// Archives a finished dictation. Silently does nothing when history is off
    /// or paused. Never throws: losing a history entry is not worth interrupting
    /// the user, and the transcript is already on its way to their app.
    ///
    /// Returns whether the entry was persisted — the caller owns any audio the
    /// draft referenced, and a rolled-back save leaves that file with nothing
    /// pointing at it.
    @discardableResult
    func record(_ draft: HistoryDraft) -> Bool {
        guard isRecordingEnabled else { return false }
        let context = container.mainContext
        context.insert(HistoryEntry(draft: draft))
        do {
            try context.save()
            // Never log transcript text — counts and durations only, matching the
            // convention in the rest of the app.
            Self.logger.info("Recorded entry (\(draft.text.count) characters, \(Int(draft.duration))s)")
            return true
        } catch {
            context.rollback()
            Self.logger.error("Could not record history entry: \(error.localizedDescription, privacy: .public)")
            return false
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

    private func fetchAllEntries() throws -> [HistoryEntry] {
        try container.mainContext.fetch(
            FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    /// Entries, or an empty array if they can't be read.
    ///
    /// Only safe where "nothing came back" and "nothing is there" mean the same
    /// thing. Anything that **deletes files** by comparing the store against the
    /// recordings folder must use `fetchAllEntries()` instead: a failed fetch
    /// looks exactly like an empty store, and would take every recording with it.
    private func allEntries() -> [HistoryEntry] {
        do {
            return try fetchAllEntries()
        } catch {
            Self.logger.error("Could not fetch entries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Deletion

    /// Deletes entries and any audio they own, reporting whether it stuck so the
    /// UI can say something rather than appearing to have deleted them.
    ///
    /// Files go **after** the save, never before: a failed save rolls the entries
    /// back, and an entry that still points at a recording has to still have one.
    @discardableResult
    func delete(_ doomed: [HistoryEntry]) -> Bool {
        guard !doomed.isEmpty else { return true }
        let context = container.mainContext
        let filenames = doomed.compactMap(\.audioFilename)
        for entry in doomed {
            context.delete(entry)
        }
        guard save(context, describing: "delete \(doomed.count) entries") else { return false }
        for filename in filenames {
            RecordingsDirectory.delete(filename: filename)
        }
        return true
    }

    /// Drops an entry's recording but keeps its transcript.
    @discardableResult
    func deleteAudio(of entry: HistoryEntry, pruned: Bool = false) -> Bool {
        guard let filename = entry.audioFilename else { return true }
        entry.audioFilename = nil
        entry.audioByteCount = nil
        entry.audioPrunedAt = pruned ? Date() : nil
        guard save(container.mainContext, describing: "delete audio") else { return false }
        RecordingsDirectory.delete(filename: filename)
        return true
    }

    /// Pinned entries survive the age limit and the audio size cap.
    ///
    /// Lives here rather than in the view so the write goes through the one place
    /// that reports a failed save instead of discarding it.
    @discardableResult
    func setPinned(_ pinned: Bool, on entry: HistoryEntry) -> Bool {
        entry.isPinned = pinned
        return save(container.mainContext, describing: pinned ? "pin entry" : "unpin entry")
    }

    /// Everything: entries, and every file in the recordings folder — including
    /// any orphans, which is the point of doing it by folder rather than by row.
    func deleteAll() {
        let context = container.mainContext
        let all: [HistoryEntry]
        do {
            all = try fetchAllEntries()
        } catch {
            // Not `allEntries()`: an unreadable store would come back as "no
            // entries", the save would trivially succeed, and every recording
            // would then be deleted while its entry survived.
            Self.logger.error("Could not delete all history: \(error.localizedDescription, privacy: .public)")
            return
        }
        for entry in all {
            context.delete(entry)
        }
        // Same ordering rule as `delete`: if the rows survive a failed save, so
        // must the recordings they name.
        guard save(context, describing: "delete all history") else { return }
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
        let entries: [HistoryEntry]
        do {
            entries = try fetchAllEntries()
        } catch {
            // Same trap as `deleteAll`, and this one runs at every launch: an
            // unreadable store would leave `referenced` empty and every
            // recording on disk looking like an orphan.
            Self.logger.error("Could not reconcile recordings: \(error.localizedDescription, privacy: .public)")
            return
        }
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
        // Deliberately not `AppDirectories.ensure`: this is a folder the user
        // picked, not storage the app owns, and tightening an existing one to
        // 0700 would quietly revoke everyone else's access to a shared
        // directory. `withIntermediateDirectories` leaves an existing directory
        // exactly as it found it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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

    /// Returns whether the save stuck. Callers that also delete files on disk
    /// must check it — a rollback restores rows that reference those files.
    @discardableResult
    private func save(_ context: ModelContext, describing action: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            Self.logger.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
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
