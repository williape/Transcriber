//
//  AppDirectoriesTests.swift
//  TranscriberTests
//

import Foundation
import Testing
@testable import Transcriber

struct AppDirectoriesTests {

    private func temporaryURL() -> URL {
        URL.temporaryDirectory.appending(path: "TranscriberTests-\(UUID().uuidString)",
                                         directoryHint: .isDirectory)
    }

    private func permissions(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    @Test func rootIsAFolderInDocuments() {
        #expect(AppDirectories.root.deletingLastPathComponent().lastPathComponent == "Documents")
        #expect(AppDirectories.root.lastPathComponent == "Transcriber")
    }

    @Test func recordingsSitInsideRoot() {
        #expect(AppDirectories.recordings.deletingLastPathComponent().path
                == AppDirectories.root.path)
        #expect(AppDirectories.recordings.lastPathComponent == "Recordings")
    }

    /// The old location, still needed to migrate anyone who ran that build.
    @Test func legacyRootIsScopedToTheBundle() {
        #expect(AppDirectories.legacyRoot.path.contains("Application Support"))
        #expect(AppDirectories.legacyRoot.lastPathComponent == Bundle.main.bundleIdentifier)
    }

    /// Transcripts and dictation audio are private data — the directory must be
    /// owner-only, not the default 0755.
    @Test func ensureCreatesAnOwnerOnlyDirectory() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try AppDirectories.ensure(url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try permissions(of: url) == 0o700)
    }

    /// Called on every launch, and `createDirectory` leaves an existing
    /// directory's mode alone — so `ensure` has to re-assert it.
    @Test func ensureTightensAnExistingLooseDirectory() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        #expect(try permissions(of: url) == 0o755)

        try AppDirectories.ensure(url)
        #expect(try permissions(of: url) == 0o700)
    }

    // MARK: - Migration from the old Application Support location

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    @Test func migrationMovesEverythingAndRemovesTheOldFolder() throws {
        let legacy = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }

        try AppDirectories.ensure(legacy)
        try write("store", to: legacy.appending(path: "History.store"))
        try AppDirectories.ensure(legacy.appending(path: "Recordings", directoryHint: .isDirectory))

        let moved = try AppDirectories.migrate(from: legacy, to: destination)

        #expect(Set(moved) == ["History.store", "Recordings"])
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "History.store").path))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Recordings").path))
        // Nothing left behind, so the old folder shouldn't linger.
        #expect(FileManager.default.fileExists(atPath: legacy.path) == false)
    }

    /// A store already at the new location wins; the old one is left alone
    /// rather than overwritten or deleted.
    @Test func migrationNeverClobbersTheNewLocation() throws {
        let legacy = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }

        try AppDirectories.ensure(legacy)
        try write("old", to: legacy.appending(path: "History.store"))
        try AppDirectories.ensure(destination)
        try write("new", to: destination.appending(path: "History.store"))

        let moved = try AppDirectories.migrate(from: legacy, to: destination)

        #expect(moved.isEmpty)
        let survivor = try String(decoding: Data(contentsOf: destination.appending(path: "History.store")),
                                 as: UTF8.self)
        #expect(survivor == "new")
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "History.store").path))
    }

    /// A `-wal` holds committed transactions the store file doesn't have yet, so
    /// arriving without it is arriving as a different database.
    @Test func migrationKeepsAStoreWithItsSidecars() throws {
        let legacy = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }

        try AppDirectories.ensure(legacy)
        try write("store", to: legacy.appending(path: "History.store"))
        try write("wal", to: legacy.appending(path: "History.store-wal"))
        try write("shm", to: legacy.appending(path: "History.store-shm"))

        let moved = try AppDirectories.migrate(from: legacy, to: destination)

        #expect(Set(moved) == ["History.store", "History.store-wal", "History.store-shm"])
        for name in moved {
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: name).path))
        }
    }

    /// The whole point of grouping: a store that can't travel with its sidecars
    /// stays put, so the next launch can try the move again on an intact set.
    @Test func aFailedMoveRollsBackTheWholeStoreFamily() throws {
        let legacy = temporaryURL()
        let destination = temporaryURL()
        let immovable = legacy.appending(path: "History.store-shm")
        defer {
            // Immutable files can't be deleted either.
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: immovable.path)
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }

        try AppDirectories.ensure(legacy)
        try write("store", to: legacy.appending(path: "History.store"))
        try write("wal", to: legacy.appending(path: "History.store-wal"))
        try write("shm", to: immovable)
        // `rename(2)` fails with EPERM on an immutable file — a real move failure
        // part-way through the family, which is the case worth pinning down.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: immovable.path)

        #expect(throws: (any Error).self) {
            try AppDirectories.migrate(from: legacy, to: destination)
        }

        for name in ["History.store", "History.store-wal", "History.store-shm"] {
            #expect(FileManager.default.fileExists(atPath: legacy.appending(path: name).path),
                    "\(name) should have been rolled back to the old location")
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: name).path) == false,
                    "\(name) should not be left at the new location")
        }
    }

    /// Skipping a family that's already arrived mustn't stop everything else
    /// migrating.
    @Test func migrationSkipsAnAlreadyPresentFamilyAndCarriesOn() throws {
        let legacy = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }

        try AppDirectories.ensure(legacy)
        try write("old", to: legacy.appending(path: "History.store"))
        try write("old wal", to: legacy.appending(path: "History.store-wal"))
        try AppDirectories.ensure(legacy.appending(path: "Recordings", directoryHint: .isDirectory))
        try AppDirectories.ensure(destination)
        try write("new", to: destination.appending(path: "History.store"))

        let moved = try AppDirectories.migrate(from: legacy, to: destination)

        #expect(moved == ["Recordings"])
        // The sidecar belongs to the store that stayed behind, and must not be
        // grafted onto the store already at the new location.
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "History.store-wal").path) == false)
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "History.store-wal").path))
    }

    /// A `-wal` with no store beside it is just a file with an odd name.
    @Test func anOrphanedSidecarMigratesOnItsOwn() throws {
        let legacy = temporaryURL()
        let destination = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: destination)
        }

        try AppDirectories.ensure(legacy)
        try write("stray", to: legacy.appending(path: "History.store-wal"))

        let moved = try AppDirectories.migrate(from: legacy, to: destination)

        #expect(moved == ["History.store-wal"])
    }

    @Test func migrationIsANoOpWithoutAnOldFolder() throws {
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination) }

        let moved = try AppDirectories.migrate(from: temporaryURL(), to: destination)

        #expect(moved.isEmpty)
    }

    @Test func ensureIsIdempotent() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try AppDirectories.ensure(url)
        let marker = url.appending(path: "marker.txt", directoryHint: .notDirectory)
        try Data("keep me".utf8).write(to: marker)

        try AppDirectories.ensure(url)

        // A second call must not wipe what's already there.
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
