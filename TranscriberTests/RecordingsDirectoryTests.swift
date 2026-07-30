//
//  RecordingsDirectoryTests.swift
//  TranscriberTests
//

import Foundation
import Testing
@testable import Transcriber

struct RecordingsDirectoryTests {

    private func temporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "RecordingsTests-\(UUID().uuidString)",
                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try #require(formatter.date(from: iso))
    }

    @Test func timestampIsSortableAndFilesystemSafe() throws {
        let stamp = RecordingsDirectory.timestamp(for: try date("2026-07-30 10:45:12"))

        #expect(stamp == "2026-07-30 10-45-12")
        #expect(stamp.contains(":") == false)
        #expect(stamp.contains("/") == false)
    }

    /// Lexicographic order has to match chronological order, or Finder's
    /// name-sorted view is useless.
    @Test func timestampsSortChronologically() throws {
        let earlier = RecordingsDirectory.timestamp(for: try date("2026-07-30 09:59:59"))
        let later = RecordingsDirectory.timestamp(for: try date("2026-07-30 10:00:00"))
        let nextYear = RecordingsDirectory.timestamp(for: try date("2027-01-01 00:00:00"))

        #expect(earlier < later)
        #expect(later < nextYear)
    }

    @Test func filenameUsesTheTimestamp() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let name = try RecordingsDirectory.reserveFilename(for: try date("2026-07-30 10:45:12"),
                                                          in: directory)

        #expect(name == "2026-07-30 10-45-12.m4a")
    }

    /// Two recordings inside the same second must not overwrite each other, and
    /// the reservation has to hold the name without a separate write.
    @Test func collisionsGetAFinderStyleSuffix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let when = try date("2026-07-30 10:45:12")

        let first = try RecordingsDirectory.reserveFilename(for: when, in: directory)
        let second = try RecordingsDirectory.reserveFilename(for: when, in: directory)
        let third = try RecordingsDirectory.reserveFilename(for: when, in: directory)

        #expect(first == "2026-07-30 10-45-12.m4a")
        #expect(second == "2026-07-30 10-45-12 (2).m4a")
        #expect(third == "2026-07-30 10-45-12 (3).m4a")
    }

    /// The filename comes off a stored entry, so it must not be able to point
    /// anywhere but inside the recordings folder.
    @Test func deleteRefusesPathsOutsideTheFolder() throws {
        let bystander = URL.temporaryDirectory.appending(path: "bystander-\(UUID().uuidString).txt")
        try Data("keep me".utf8).write(to: bystander)
        defer { try? FileManager.default.removeItem(at: bystander) }

        RecordingsDirectory.delete(filename: "../../../../\(bystander.lastPathComponent)")
        RecordingsDirectory.delete(filename: bystander.path)
        RecordingsDirectory.delete(filename: "")
        RecordingsDirectory.delete(filename: "..")

        #expect(FileManager.default.fileExists(atPath: bystander.path))
    }
}
