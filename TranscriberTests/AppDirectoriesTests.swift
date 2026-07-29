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

    @Test func supportPathIsScopedToTheBundle() {
        let path = AppDirectories.support.path
        #expect(path.contains("Application Support"))
        #expect(AppDirectories.support.lastPathComponent == Bundle.main.bundleIdentifier)
    }

    @Test func recordingsSitInsideSupport() {
        #expect(AppDirectories.recordings.deletingLastPathComponent().path
                == AppDirectories.support.path)
        #expect(AppDirectories.recordings.lastPathComponent == "Recordings")
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
