//
//  HistoryGroupTests.swift
//  TranscriberTests
//

import Foundation
import Testing
@testable import Transcriber

/// Sidebar date buckets. Entries are built but never inserted — the grouping is
/// pure, so it needs no store.
@MainActor
struct HistoryGroupTests {

    private func entry(at date: Date) -> HistoryEntry {
        var draft = HistoryDraft(text: "Hello there.",
                                 localeIdentifier: "en-AU",
                                 duration: 1,
                                 isPartial: false,
                                 segments: [])
        draft.createdAt = date
        return HistoryEntry(draft: draft)
    }

    private func title(for date: Date) -> String? {
        HistoryGroup.grouped([entry(at: date)]).first?.title
    }

    @Test func todayAndYesterdayComeFirst() {
        #expect(title(for: .now) == "Today")
        #expect(title(for: Calendar.current.date(byAdding: .day, value: -1, to: .now)!) == "Yesterday")
    }

    /// "This Week" is the calendar's own week. A rolling seven days would label
    /// dates from the *previous* calendar week as this one — on a Wednesday that's
    /// the back half of the week before.
    @Test func thisWeekMeansTheCalendarWeek() throws {
        let calendar = Calendar.current
        let thisWeek = try #require(calendar.dateInterval(of: .weekOfYear, for: .now))
        // A day inside the current week that isn't today or yesterday, if this
        // week is far enough along to have one.
        let candidate = calendar.date(byAdding: .day, value: -2, to: .now)!
        if thisWeek.contains(candidate) {
            #expect(title(for: candidate) == "This Week")
        }
        // The day before this week started is never "This Week", however few
        // days ago it was.
        let beforeThisWeek = calendar.date(byAdding: .day, value: -1, to: thisWeek.start)!
        #expect(title(for: beforeThisWeek) != "This Week")
    }

    @Test func olderEntriesAreLabelledByMonth() {
        let longAgo = Calendar.current.date(byAdding: .month, value: -3, to: .now)!
        let expected = longAgo.formatted(.dateTime.month(.wide).year())

        #expect(title(for: longAgo) == expected)
    }

    /// Buckets stay in the order the entries arrive (newest first), not
    /// alphabetical order.
    @Test func groupsKeepTheEntryOrder() {
        let calendar = Calendar.current
        let entries = [entry(at: .now),
                       entry(at: calendar.date(byAdding: .day, value: -1, to: .now)!),
                       entry(at: calendar.date(byAdding: .month, value: -6, to: .now)!)]

        let groups = HistoryGroup.grouped(entries)

        #expect(groups.count == 3)
        #expect(groups.first?.title == "Today")
        #expect(groups.dropFirst().first?.title == "Yesterday")
    }
}
