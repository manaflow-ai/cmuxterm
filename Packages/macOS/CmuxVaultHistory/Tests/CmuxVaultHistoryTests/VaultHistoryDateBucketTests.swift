import Foundation
import Testing

@testable import CmuxVaultHistory

@Suite struct VaultHistoryDateBucketTests {
    @Test(arguments: [Calendar.Identifier.gregorian, .iso8601], [
        "UTC", "America/Los_Angeles", "Asia/Tokyo",
    ])
    func weekGroupingSpansNewYear(
        identifier: Calendar.Identifier,
        timeZoneIdentifier: String
    ) throws {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let firstWeekNow = try #require(calendar.date(from:
            DateComponents(year: 2025, month: 1, day: 3, hour: 12)
        ))
        let firstWeekStart = try #require(calendar.date(from:
            DateComponents(year: 2024, month: 12, day: 30, hour: 12)
        ))
        let precedingSunday = try #require(calendar.date(from:
            DateComponents(year: 2024, month: 12, day: 29, hour: 12)
        ))
        let priorYearFirstWeek = try #require(calendar.date(from:
            DateComponents(year: 2024, month: 1, day: 1, hour: 12)
        ))
        let lastWeekNow = try #require(calendar.date(from:
            DateComponents(year: 2021, month: 1, day: 1, hour: 12)
        ))
        let lastWeekStart = try #require(calendar.date(from:
            DateComponents(year: 2020, month: 12, day: 28, hour: 12)
        ))

        // Both directions of calendar-year / week-numbering-year disagreement.
        // These dates are outside the rolling 24 hours and yesterday buckets.
        #expect(VaultHistoryDateBucket.bucket(
            for: firstWeekStart, now: firstWeekNow, calendar: calendar
        ) == .thisWeek)
        #expect(VaultHistoryDateBucket.bucket(
            for: lastWeekStart, now: lastWeekNow, calendar: calendar
        ) == .thisWeek)
        #expect(VaultHistoryDateBucket.bucket(
            for: precedingSunday, now: firstWeekNow, calendar: calendar
        ) == .older)
        #expect(VaultHistoryDateBucket.bucket(
            for: priorYearFirstWeek, now: firstWeekNow, calendar: calendar
        ) == .older)
    }

    @Test func weekGroupingHonorsSundayFirstCalendarAtNewYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1

        let now = try #require(calendar.date(from:
            DateComponents(year: 2025, month: 1, day: 2, hour: 12)
        ))
        let sunday = try #require(calendar.date(from:
            DateComponents(year: 2024, month: 12, day: 29, hour: 12)
        ))
        let precedingSaturday = try #require(calendar.date(from:
            DateComponents(year: 2024, month: 12, day: 28, hour: 12)
        ))

        #expect(VaultHistoryDateBucket.bucket(
            for: sunday, now: now, calendar: calendar
        ) == .thisWeek)
        #expect(VaultHistoryDateBucket.bucket(
            for: precedingSaturday, now: now, calendar: calendar
        ) == .older)
    }
}
