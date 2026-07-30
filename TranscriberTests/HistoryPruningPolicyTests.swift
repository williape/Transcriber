//
//  HistoryPruningPolicyTests.swift
//  TranscriberTests
//

import Foundation
import Testing
@testable import Transcriber

struct HistoryPruningPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(daysAgo: Double,
                           audioBytes: Int64? = nil,
                           pinned: Bool = false) -> PruneCandidate {
        PruneCandidate(id: UUID(),
                       createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                       audioFilename: audioBytes == nil ? nil : "\(UUID()).m4a",
                       audioByteCount: audioBytes ?? 0,
                       isPinned: pinned)
    }

    // MARK: - Age expiry

    @Test func neverExpiresWhenRetentionIsOff() {
        let candidates = [candidate(daysAgo: 3650)]

        #expect(HistoryPruningPolicy.expired(candidates, retentionDays: 0, now: now).isEmpty)
    }

    @Test func expiresOnlyEntriesPastTheLimit() {
        let old = candidate(daysAgo: 31)
        let fresh = candidate(daysAgo: 29)

        let expired = HistoryPruningPolicy.expired([old, fresh], retentionDays: 30, now: now)

        #expect(expired == [old.id])
    }

    /// An entry exactly at the limit is not yet past it.
    @Test func theBoundaryIsNotExpired() {
        let exactly = candidate(daysAgo: 30)

        #expect(HistoryPruningPolicy.expired([exactly], retentionDays: 30, now: now).isEmpty)
    }

    @Test func pinnedEntriesNeverExpire() {
        let pinned = candidate(daysAgo: 400, pinned: true)

        #expect(HistoryPruningPolicy.expired([pinned], retentionDays: 7, now: now).isEmpty)
    }

    // MARK: - Audio size cap

    @Test func noReclaimWithoutACap() {
        let candidates = [candidate(daysAgo: 1, audioBytes: 5_000_000_000)]

        #expect(HistoryPruningPolicy.audioToReclaim(candidates, capBytes: 0).isEmpty)
    }

    @Test func noReclaimUnderTheCap() {
        let candidates = [candidate(daysAgo: 1, audioBytes: 400),
                          candidate(daysAgo: 2, audioBytes: 500)]

        #expect(HistoryPruningPolicy.audioToReclaim(candidates, capBytes: 1000).isEmpty)
    }

    /// Exactly at the cap is within it — reclaiming there would be a surprise.
    @Test func theCapBoundaryIsWithinBudget() {
        let candidates = [candidate(daysAgo: 1, audioBytes: 600),
                          candidate(daysAgo: 2, audioBytes: 400)]

        #expect(HistoryPruningPolicy.audioToReclaim(candidates, capBytes: 1000).isEmpty)
    }

    @Test func reclaimsOldestFirstAndStopsAtTheCap() {
        let newest = candidate(daysAgo: 1, audioBytes: 500)
        let middle = candidate(daysAgo: 5, audioBytes: 500)
        let oldest = candidate(daysAgo: 9, audioBytes: 500)

        let reclaimed = HistoryPruningPolicy.audioToReclaim([newest, middle, oldest],
                                                            capBytes: 1000)

        // Dropping the oldest alone gets to 1000, which is within budget.
        #expect(reclaimed == [oldest.id])
    }

    @Test func reclaimsAsManyAsNeeded() {
        let newest = candidate(daysAgo: 1, audioBytes: 500)
        let middle = candidate(daysAgo: 5, audioBytes: 500)
        let oldest = candidate(daysAgo: 9, audioBytes: 500)

        let reclaimed = HistoryPruningPolicy.audioToReclaim([newest, middle, oldest],
                                                            capBytes: 400)

        #expect(reclaimed == [oldest.id, middle.id, newest.id])
    }

    /// Pinned audio is skipped even when that leaves the total over the cap —
    /// the pin is the user overriding the policy on purpose.
    @Test func pinnedAudioSurvivesTheCap() {
        let pinned = candidate(daysAgo: 100, audioBytes: 5000, pinned: true)
        let ordinary = candidate(daysAgo: 1, audioBytes: 500)

        let reclaimed = HistoryPruningPolicy.audioToReclaim([pinned, ordinary], capBytes: 1000)

        #expect(reclaimed == [ordinary.id])
    }

    /// Entries with no recording aren't candidates for an audio-only rule.
    @Test func textOnlyEntriesAreIgnored() {
        let textOnly = candidate(daysAgo: 100)
        let withAudio = candidate(daysAgo: 1, audioBytes: 2000)

        let reclaimed = HistoryPruningPolicy.audioToReclaim([textOnly, withAudio], capBytes: 1000)

        #expect(reclaimed == [withAudio.id])
    }
}
