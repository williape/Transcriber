//
//  HistoryPruningPolicy.swift
//  Transcriber
//

import Foundation

/// The bits of an entry the pruning rules need, as a value type — so the policy
/// is pure, testable, and can't accidentally mutate the store.
nonisolated struct PruneCandidate: Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let audioFilename: String?
    let audioByteCount: Int64
    let isPinned: Bool
}

/// What to delete, and why. Both rules skip pinned entries — that's the whole
/// point of a pin.
nonisolated enum HistoryPruningPolicy {
    /// Entries past the age limit. `days == 0` means "keep forever".
    /// Deletes the entry *and* its audio.
    static func expired(_ candidates: [PruneCandidate],
                        retentionDays: Int,
                        now: Date = Date()) -> [UUID] {
        guard retentionDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return candidates
            .filter { !$0.isPinned && $0.createdAt < cutoff }
            .map(\.id)
    }

    /// Entries whose *audio* should be reclaimed to get under `capBytes`,
    /// oldest first. `capBytes == 0` means "no limit". Transcripts are kept:
    /// this rule only ever costs the recording.
    static func audioToReclaim(_ candidates: [PruneCandidate], capBytes: Int) -> [UUID] {
        guard capBytes > 0 else { return [] }
        let withAudio = candidates.filter { $0.audioFilename != nil }
        var total = withAudio.reduce(Int64(0)) { $0 + $1.audioByteCount }
        guard total > capBytes else { return [] }

        var doomed: [UUID] = []
        // Oldest first: the newest recording is the one most likely to still be
        // wanted.
        for candidate in withAudio.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard total > capBytes else { break }
            guard !candidate.isPinned else { continue }
            doomed.append(candidate.id)
            total -= candidate.audioByteCount
        }
        return doomed
    }
}
