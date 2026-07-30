//
//  AppDirectories.swift
//  Transcriber
//

import Foundation
import os

/// On-disk locations the app owns.
///
/// History and retained audio live in **`~/Documents/Transcriber`** — somewhere
/// the user can see, back up and manage themselves, which is what they asked
/// for. That's a deliberate trade against hiding it in Application Support: the
/// data is more discoverable, and also more exposed (see `rootIsCloudSynced`).
///
/// The app is intentionally unsandboxed, so these are real paths. If the sandbox
/// were ever switched on, `~/Documents` would become a container path and the
/// data would need moving again.
nonisolated enum AppDirectories {
    private static let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Storage")

    /// `~/Documents/Transcriber`
    static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Documents", directoryHint: .isDirectory)
        return documents.appending(path: "Transcriber", directoryHint: .isDirectory)
    }

    /// Retained dictation audio (M3).
    static var recordings: URL {
        root.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    /// Where the data lived before it moved to `~/Documents/Transcriber`.
    static var legacyRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let identifier = Bundle.main.bundleIdentifier ?? "com.pwilliams.Transcriber"
        return base.appending(path: identifier, directoryHint: .isDirectory)
    }

    /// True when `~/Documents` is redirected into iCloud Drive — i.e. System
    /// Settings ▸ iCloud ▸ "Desktop & Documents Folders" is on. Transcripts and
    /// dictation audio would then be uploaded, which quietly breaks the app's
    /// on-device promise, so it's worth saying so in the log.
    static var rootIsCloudSynced: Bool {
        root.resolvingSymlinksInPath().path.contains("Mobile Documents")
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

    /// SQLite sidecars. A `-wal` holds committed transactions that aren't in the
    /// store file yet, and an `-shm` describes the `-wal` — so a store separated
    /// from either is not the database it was, which is why they migrate as one
    /// unit rather than as three files that happen to share a prefix.
    private static let sidecarSuffixes = ["-wal", "-shm"]

    /// Moves everything from `legacy` into `destination`, returning the names it
    /// moved. Existing files at the destination are never overwritten — if any
    /// remain behind, `legacy` is left in place rather than tidied away, so
    /// nothing is silently lost.
    ///
    /// Throws if a move fails, having first put that store family back where it
    /// came from: a half-migrated database is worse than an unmigrated one, and
    /// the caller can only retry next launch if `legacy` is still whole.
    @discardableResult
    static func migrate(from legacy: URL, to destination: URL) throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path) else { return [] }
        let names = try manager.contentsOfDirectory(atPath: legacy.path)
        try ensure(destination)

        var moved: [String] = []
        for family in families(in: names) {
            if let present = family.first(where: {
                manager.fileExists(atPath: destination.appending(path: $0).path)
            }) {
                logger.error("Not migrating \(present, privacy: .public): already present at the new location")
                continue
            }
            do {
                for name in family {
                    try manager.moveItem(at: legacy.appending(path: name),
                                         to: destination.appending(path: name))
                    moved.append(name)
                }
            } catch {
                rollBack(family, from: destination, to: legacy)
                throw error
            }
        }

        if (try? manager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? manager.removeItem(at: legacy)
        }
        if !moved.isEmpty {
            logger.info("Migrated \(moved.count) items to \(destination.path, privacy: .public)")
        }
        return moved
    }

    /// Groups a directory listing so each store travels with its own sidecars.
    /// Every other name is a family of one.
    private static func families(in names: [String]) -> [[String]] {
        let all = Set(names)
        var families: [[String]] = []
        for name in names.sorted() {
            // A `-wal` is only a sidecar when its store is here too; on its own
            // it's just a file with an odd name, and moves like any other.
            if let base = sidecarBase(of: name), all.contains(base) { continue }
            families.append([name] + sidecarSuffixes.map { name + $0 }.filter(all.contains))
        }
        return families
    }

    private static func sidecarBase(of name: String) -> String? {
        for suffix in sidecarSuffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// Returns a partially-moved family to `legacy`. Only ever called for a
    /// family this migration moved, so nothing pre-existing at `destination` can
    /// be dragged back with it.
    private static func rollBack(_ family: [String], from destination: URL, to legacy: URL) {
        let manager = FileManager.default
        for name in family {
            let source = destination.appending(path: name)
            guard manager.fileExists(atPath: source.path) else { continue }
            do {
                try manager.moveItem(at: source, to: legacy.appending(path: name))
            } catch {
                logger.error("Could not roll back \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
