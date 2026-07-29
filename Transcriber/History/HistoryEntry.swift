//
//  HistoryEntry.swift
//  Transcriber
//

import Foundation
import SwiftData

/// One archived dictation.
///
/// The audio (`audioFilename`, `audioByteCount`, `audioPrunedAt`) and `isPinned`
/// fields are part of the v1 schema even though nothing sets them yet — audio
/// retention (M3) and pinning (M4) then need no schema migration.
///
/// File transcriptions deliberately do **not** appear here (PRD §5.4), which is
/// why there's no source-file reference and no kind discriminator.
@Model
nonisolated final class HistoryEntry {
    #Index<HistoryEntry>([\.createdAt])

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var text: String
    /// BCP-47 identifier of the locale actually used (not the one requested).
    var localeIdentifier: String
    var duration: TimeInterval
    /// The results stream died mid-session; `text` is what was committed before
    /// it did. Shown as a badge so a short transcript isn't mistaken for
    /// everything that was said.
    var isPartial: Bool
    /// Exempt from pruning. No UI until M4 — see PRD F6.9.
    var isPinned: Bool

    /// Insertion target captured at session *start*. The panel is
    /// non-activating, so the app that was frontmost when recording began is
    /// still the one the transcript goes to when it ends.
    var targetAppBundleID: String?
    var targetAppName: String?
    /// `OutputRouter.Outcome` raw value, or nil if delivery never ran.
    var deliveryOutcomeRaw: String?

    /// Retained audio, relative to `AppDirectories.recordings` (M3).
    var audioFilename: String?
    var audioByteCount: Int64?
    /// Set when the size cap reclaimed this entry's audio but kept its text (M4).
    var audioPrunedAt: Date?

    var segments: [TranscriptSegment]

    init(draft: HistoryDraft) {
        self.id = draft.id
        self.createdAt = draft.createdAt
        self.text = draft.text
        self.localeIdentifier = draft.localeIdentifier
        self.duration = draft.duration
        self.isPartial = draft.isPartial
        self.isPinned = false
        self.targetAppBundleID = draft.targetAppBundleID
        self.targetAppName = draft.targetAppName
        self.deliveryOutcomeRaw = draft.deliveryOutcomeRaw
        self.audioFilename = draft.audioFilename
        self.audioByteCount = draft.audioByteCount
        self.audioPrunedAt = nil
        self.segments = draft.segments
    }
}

/// A committed span of transcript with its position in the session's audio
/// timeline, taken from `SpeechTranscriber.Result.range`. Drives click-to-seek
/// playback (M5); harmless to store before then.
nonisolated struct TranscriptSegment: Codable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Everything needed to create an entry, as a value type — so a session's
/// result can be assembled off the main actor and handed to the store without
/// a `@Model` instance escaping its context.
nonisolated struct HistoryDraft: Sendable {
    var id = UUID()
    var createdAt = Date()
    var text: String
    var localeIdentifier: String
    var duration: TimeInterval
    var isPartial: Bool
    var targetAppBundleID: String?
    var targetAppName: String?
    var deliveryOutcomeRaw: String?
    var audioFilename: String?
    var audioByteCount: Int64?
    var segments: [TranscriptSegment]
}

/// Versioned from v1 so later fields have a migration path rather than a
/// "delete the store" moment.
nonisolated enum HistorySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [HistoryEntry.self] }
}

nonisolated enum HistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HistorySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
