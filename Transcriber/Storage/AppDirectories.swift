//
//  AppDirectories.swift
//  Transcriber
//

import Foundation
import os

/// On-disk locations the app owns. The app is intentionally unsandboxed, so
/// these are real `~/Library` paths, not container paths — if the sandbox is
/// ever switched on, existing data would need a one-time migration.
enum AppDirectories {
    private static let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Storage")

    /// `~/Library/Application Support/com.pwilliams.Transcriber`
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let identifier = Bundle.main.bundleIdentifier ?? "com.pwilliams.Transcriber"
        return base.appending(path: identifier, directoryHint: .isDirectory)
    }

    /// Retained dictation audio (M3). Named here so both the store and the
    /// recorder agree on one location.
    static var recordings: URL {
        support.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    /// Creates `url` if needed, owner-only. Transcripts and dictation audio are
    /// private data, so 0700 rather than the default 0755 — and the permissions
    /// are re-asserted on an existing directory, because `createDirectory`
    /// silently leaves the mode of one that's already there alone.
    @discardableResult
    static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            // Not fatal: the directory is usable, just possibly group-readable.
            logger.error("Could not tighten permissions on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return url
    }
}
