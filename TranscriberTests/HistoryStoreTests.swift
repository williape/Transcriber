//
//  HistoryStoreTests.swift
//  TranscriberTests
//

import Foundation
import SwiftData
import Testing
@testable import Transcriber

@MainActor
struct HistoryStoreTests {

    /// In-memory store with its own defaults, so tests never touch the user's
    /// real history or preferences.
    private func makeStore(keepsHistory: Bool = true,
                           paused: Bool = false) throws -> (HistoryStore, Preferences) {
        let suite = "com.pwilliams.Transcriber.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.keepsTranscriptHistory = keepsHistory
        preferences.historyPaused = paused
        let store = try HistoryStore(configuration: ModelConfiguration(isStoredInMemoryOnly: true),
                                     preferences: preferences)
        return (store, preferences)
    }

    private func draft(text: String = "Hello there.") -> HistoryDraft {
        HistoryDraft(text: text,
                     localeIdentifier: "en-AU",
                     duration: 12.5,
                     isPartial: false,
                     targetAppBundleID: "com.apple.TextEdit",
                     targetAppName: "TextEdit",
                     deliveryOutcomeRaw: OutputRouter.Outcome.inserted.rawValue,
                     segments: [TranscriptSegment(start: 0, end: 1.5, text: "Hello "),
                                TranscriptSegment(start: 1.5, end: 2.5, text: "there.")])
    }

    private func entries(in store: HistoryStore) throws -> [HistoryEntry] {
        try store.container.mainContext.fetch(
            FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    @Test func recordsAnEntry() throws {
        let (store, _) = try makeStore()
        store.record(draft())
        #expect(store.entryCount() == 1)
    }

    @Test func recordsEveryDictation() throws {
        let (store, _) = try makeStore()
        for index in 1...3 {
            store.record(draft(text: "Dictation \(index)"))
        }
        #expect(store.entryCount() == 3)
    }

    @Test func draftFieldsRoundTrip() throws {
        let (store, _) = try makeStore()
        let draft = draft()
        store.record(draft)

        let entry = try #require(try entries(in: store).first)
        #expect(entry.id == draft.id)
        #expect(entry.text == draft.text)
        #expect(entry.localeIdentifier == "en-AU")
        #expect(entry.duration == 12.5)
        #expect(entry.isPartial == false)
        #expect(entry.targetAppBundleID == "com.apple.TextEdit")
        #expect(entry.targetAppName == "TextEdit")
        #expect(entry.deliveryOutcomeRaw == "inserted")
        #expect(entry.segments == draft.segments)
    }

    /// The audio and pin fields exist in the v1 schema so M3/M4 need no
    /// migration; nothing should be populating them yet.
    @Test func audioAndPinFieldsStartEmpty() throws {
        let (store, _) = try makeStore()
        store.record(draft())

        let entry = try #require(try entries(in: store).first)
        #expect(entry.isPinned == false)
        #expect(entry.audioFilename == nil)
        #expect(entry.audioByteCount == nil)
        #expect(entry.audioPrunedAt == nil)
    }

    @Test func partialTranscriptIsFlagged() throws {
        let (store, _) = try makeStore()
        var draft = draft(text: "Half a sen")
        draft.isPartial = true
        store.record(draft)

        let entry = try #require(try entries(in: store).first)
        #expect(entry.isPartial)
    }

    @Test func recordsNothingWhenHistoryIsOff() throws {
        let (store, _) = try makeStore(keepsHistory: false)
        #expect(store.isRecordingEnabled == false)
        store.record(draft())
        #expect(store.entryCount() == 0)
    }

    @Test func recordsNothingWhilePaused() throws {
        let (store, preferences) = try makeStore(paused: true)
        #expect(store.isRecordingEnabled == false)
        store.record(draft())
        #expect(store.entryCount() == 0)

        // Unpausing resumes recording without a relaunch.
        preferences.historyPaused = false
        #expect(store.isRecordingEnabled)
        store.record(draft())
        #expect(store.entryCount() == 1)
    }

    // MARK: - Pinning

    @Test func pinningIsSaved() throws {
        let (store, _) = try makeStore()
        store.record(draft())
        let entry = try #require(try entries(in: store).first)

        #expect(store.setPinned(true, on: entry))
        #expect(try #require(try entries(in: store).first).isPinned)
        #expect(store.setPinned(false, on: entry))
        #expect(try #require(try entries(in: store).first).isPinned == false)
    }

    // MARK: - Migration guard

    /// The check that stands between a failed migration and a fresh empty store
    /// opening on top of the user's history.
    @Test func aStoreLeftInTheOldFolderIsRefused() throws {
        let (legacy, destination) = try legacyAndDestination()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("store".utf8).write(to: legacy.appending(path: "History.store"))

        #expect(throws: HistoryStore.MigrationError.self) {
            try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)
        }
    }

    /// A stranded `-wal` holds committed dictations, and opening the store makes
    /// a fresh one — so this is the last chance to bring it across.
    @Test func aStrandedWriteAheadLogIsRecovered() throws {
        let (legacy, destination) = try legacyAndDestination()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("wal".utf8).write(to: legacy.appending(path: "History.store-wal"))

        try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)

        let moved = destination.appending(path: "History.store-wal")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "History.store-wal").path) == false)
    }

    /// If it can't be brought across, history waits rather than opening a store
    /// that is quietly missing those dictations.
    @Test func anImmovableWriteAheadLogIsRefused() throws {
        let (legacy, destination) = try legacyAndDestination()
        let log = legacy.appending(path: "History.store-wal")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: log.path)
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("wal".utf8).write(to: log)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: log.path)

        #expect(throws: HistoryStore.MigrationError.self) {
            try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)
        }
    }

    /// A `-wal` records changes since *its own* database's last checkpoint, so
    /// with no store at the new location there's nothing it can be applied to —
    /// dropping it next to a store that will be created fresh would be worse than
    /// leaving it alone.
    @Test func aWriteAheadLogIsLeftAloneWithNoStoreToMatchIt() throws {
        let (legacy, destination) = try legacyAndDestination(withMigratedStore: false)
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("wal".utf8).write(to: legacy.appending(path: "History.store-wal"))

        try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)

        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "History.store-wal").path))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "History.store-wal").path) == false)
    }

    /// Once the migrated store has been opened it has a log of its own, and the
    /// old one can no longer be applied to it. Refusing forever would cost the
    /// user a working history for a file nothing can read.
    @Test func anOutdatedWriteAheadLogDoesNotBlockLaunch() throws {
        let (legacy, destination) = try legacyAndDestination()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("old wal".utf8).write(to: legacy.appending(path: "History.store-wal"))
        try Data("current wal".utf8).write(to: destination.appending(path: "History.store-wal"))

        try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)

        // Neither clobbered nor deleted.
        let current = try String(decoding: Data(contentsOf: destination.appending(path: "History.store-wal")),
                                as: UTF8.self)
        #expect(current == "current wal")
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "History.store-wal").path))
    }

    /// An `-shm` is a shared-memory index over the `-wal` — derived state, so a
    /// stray one is noise and must not hold history back.
    @Test func aStraySharedMemoryIndexIsDiscarded() throws {
        let (legacy, destination) = try legacyAndDestination()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("shm".utf8).write(to: legacy.appending(path: "History.store-shm"))

        try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)

        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "History.store-shm").path) == false)
    }

    @Test func noOldFolderIsFine() throws {
        let (legacy, destination) = try legacyAndDestination()
        try FileManager.default.removeItem(at: legacy)
        defer { try? FileManager.default.removeItem(at: destination) }

        try HistoryStore.verifyStoreMigrated(in: legacy, to: destination)
    }

    /// A legacy folder, and a destination that already holds a migrated store —
    /// the state a stranded sidecar has to be judged against.
    private func legacyAndDestination(withMigratedStore: Bool = true) throws -> (legacy: URL, destination: URL) {
        let legacy = URL.temporaryDirectory.appending(path: "LegacyTests-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        let destination = URL.temporaryDirectory.appending(path: "RootTests-\(UUID().uuidString)",
                                                          directoryHint: .isDirectory)
        for url in [legacy, destination] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if withMigratedStore {
            try Data("store".utf8).write(to: destination.appending(path: "History.store"))
        }
        return (legacy, destination)
    }

    // MARK: - Export

    /// The export destination is the user's folder, not the app's storage —
    /// exporting into a shared one must not tighten it to owner-only and lock
    /// everyone else out.
    @Test func exportLeavesTheChosenFoldersPermissionsAlone() throws {
        let (store, _) = try makeStore()
        store.record(draft())
        let directory = URL.temporaryDirectory.appending(path: "ExportTests-\(UUID().uuidString)",
                                                        directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        let exported = try store.export(to: directory)

        #expect(exported == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))
    }

    @Test func exportCreatesAMissingDestination() throws {
        let (store, _) = try makeStore()
        store.record(draft())
        let directory = URL.temporaryDirectory.appending(path: "ExportTests-\(UUID().uuidString)",
                                                        directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.export(to: directory) == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))
    }

    /// A pause lasts for the app run only, so it must not be written to defaults.
    @Test func pauseIsNotPersisted() throws {
        let suite = "com.pwilliams.Transcriber.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.historyPaused = true

        #expect(Preferences(defaults: defaults).historyPaused == false)
    }
}
