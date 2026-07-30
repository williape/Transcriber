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
