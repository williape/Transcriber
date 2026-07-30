//
//  RecordingsDirectory.swift
//  Transcriber
//

import Foundation
import os

/// Owns `~/Documents/Transcriber/Recordings` and the names of the files in it.
///
/// One `.m4a` per dictation, named for when it was recorded —
/// `2026-07-30 10-45-12.m4a` — so the folder is browsable and sorts
/// chronologically in Finder without the app's help.
///
/// The scheme is **not** load-bearing: each history entry stores the actual
/// filename it was given, so renaming the scheme later (or a user renaming a
/// file) doesn't orphan anything that's already recorded.
nonisolated enum RecordingsDirectory {
    private static let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Recordings")

    static let fileExtension = "m4a"

    /// Creates the directory if needed and returns it.
    @discardableResult
    static func ensureDirectory() throws -> URL {
        let directory = try AppDirectories.ensure(AppDirectories.recordings)
        // Dictation audio has no business in Spotlight results.
        let marker = directory.appending(path: ".metadata_never_index", directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? Data().write(to: marker)
        }
        return directory
    }

    /// Claims a filename for a recording made at `date`, creating an empty file
    /// to hold the name.
    ///
    /// Two recordings can land in the same second, so a taken name gets a
    /// Finder-style ` (2)`, ` (3)` suffix. The claim is made with `O_EXCL` — a
    /// "does it exist?" check followed by a create would let two recorders
    /// starting in the same second both pick the same name and write over each
    /// other. `AVAudioFile(forWriting:)` overwrites the placeholder.
    static func reserveFilename(for date: Date, in directory: URL) throws -> String {
        let stamp = timestamp(for: date)
        var candidate = "\(stamp).\(fileExtension)"
        var attempt = 2
        while true {
            let path = directory.appending(path: candidate).path
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if descriptor >= 0 {
                close(descriptor)
                return candidate
            }
            guard errno == EEXIST else {
                throw CocoaError(.fileWriteUnknown)
            }
            candidate = "\(stamp) (\(attempt)).\(fileExtension)"
            attempt += 1
        }
    }

    /// `yyyy-MM-dd HH-mm-ss` in local time: sorts lexicographically, contains
    /// nothing a filesystem objects to, and reads as the wall-clock time the
    /// user was speaking.
    static func timestamp(for date: Date) -> String {
        // A fixed POSIX locale and Gregorian calendar — otherwise a user whose
        // region uses a non-Gregorian calendar gets unsortable filenames.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Recordings present on disk, excluding dotfiles like the Spotlight marker.
    static func recordingFilenames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AppDirectories.recordings.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    /// Seconds since the file was last written; `.infinity` if it's not there.
    static func age(of filename: String) -> TimeInterval {
        let path = AppDirectories.recordings.appending(path: filename).path
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return .infinity
        }
        return -modified.timeIntervalSinceNow
    }

    /// Total bytes of every recording — backs the storage readout and size cap.
    static func totalBytes() -> Int64 {
        recordingFilenames().reduce(into: Int64(0)) { total, name in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: AppDirectories.recordings.appending(path: name).path)
            total += (attributes?[.size] as? Int64) ?? 0
        }
    }

    /// Removes every recording, orphans included.
    static func deleteAllRecordings() {
        for name in recordingFilenames() {
            delete(filename: name)
        }
    }

    static func url(for filename: String) -> URL {
        AppDirectories.recordings.appending(path: filename, directoryHint: .notDirectory)
    }

    /// Copies a recording under a fresh timestamped name — used when a
    /// re-transcription is saved as a new entry, so each entry owns its audio
    /// and deleting one never strands the other.
    static func duplicate(filename: String, at date: Date = Date()) throws -> SessionAudioRecorder.Recorded {
        let directory = try ensureDirectory()
        let copy = try reserveFilename(for: date, in: directory)
        let destination = directory.appending(path: copy, directoryHint: .notDirectory)
        // The reservation left an empty placeholder in the way.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url(for: filename), to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? Int64
        return SessionAudioRecorder.Recorded(filename: copy, byteCount: size ?? 0)
    }

    /// Deletes a recording by the filename stored on its history entry.
    /// Refuses anything that isn't a plain name inside the recordings folder —
    /// the stored string must never be able to reach elsewhere on disk.
    static func delete(filename: String) {
        guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else {
            logger.error("Refusing to delete suspicious recording name")
            return
        }
        let url = AppDirectories.recordings.appending(path: filename, directoryHint: .notDirectory)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — nothing to do.
        } catch {
            logger.error("Could not delete recording: \(error.localizedDescription, privacy: .public)")
        }
    }
}
