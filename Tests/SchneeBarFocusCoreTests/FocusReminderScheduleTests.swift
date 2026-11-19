import Foundation
import SchneeBarFocusCore
import Testing

private func instant(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
}

private func localCalendar(_ zone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
}

@Test func focusReminderSpringGapUsesNextTimeNotPreservedMinutes() throws {
    let schedule = try FocusReminderSchedule(rule: .daily(hour: 2, minute: 30))
    let ny = try localCalendar("America/New_York")
    let occurrence = try #require(try schedule.next(after: instant("2026-03-08T05:00:00Z"), calendar: ny))
    #expect(occurrence.date == (try instant("2026-03-08T07:00:00Z")))
    #expect(occurrence.civilDay?.day == 8)
    let next = try #require(try schedule.next(after: occurrence.date, calendar: ny, lastObserved: occurrence))
    #expect(next.date == (try instant("2026-03-09T06:30:00Z")))
}

@Test func focusReminderAutumnRepeatNeverSchedulesSecondFold() throws {
    let schedule = try FocusReminderSchedule(rule: .daily(hour: 1, minute: 30))
    let ny = try localCalendar("America/New_York")
    let first = try #require(try schedule.next(after: instant("2026-11-01T04:00:00Z"), calendar: ny))
    #expect(first.date == (try instant("2026-11-01T05:30:00Z")))
    let between = try instant("2026-11-01T05:45:00Z")
    let next = try #require(try schedule.next(after: between, calendar: ny))
    #expect(next.date == (try instant("2026-11-02T06:30:00Z")))
    #expect(try schedule.next(after: between, calendar: ny, lastObserved: first) == next)
}

@Test func focusReminderWeekdaysSkipWeekendAndUseExactLocalTime() throws {
    let schedule = try FocusReminderSchedule(rule: .weekdays(hour: 9, minute: 15, days: [6, 2]))
    #expect(schedule.rule == .weekdays(hour: 9, minute: 15, days: [2, 6]))
    let tokyo = try localCalendar("Asia/Tokyo")
    let friday = try instant("2026-11-20T00:15:00Z")
    let monday = try #require(try schedule.next(after: friday, calendar: tokyo))
    #expect(monday.date == (try instant("2026-11-23T00:15:00Z")))
    #expect(monday.civilDay?.day == 23)
}

@Test func focusReminderTravelAndLongRollbackDoNotReplayObservedDay() throws {
    let schedule = try FocusReminderSchedule(rule: .daily(hour: 9, minute: 0))
    let tokyo = try localCalendar("Asia/Tokyo"), ny = try localCalendar("America/New_York")
    let before = try instant("2026-11-19T23:00:00Z")
    let observed = try #require(try schedule.next(after: before, calendar: tokyo))
    #expect(observed.date == (try instant("2026-11-20T00:00:00Z")))
    let unobserved = try #require(try schedule.next(after: observed.date, calendar: ny))
    #expect(unobserved.date == (try instant("2026-11-20T14:00:00Z")))
    let next = try #require(try schedule.next(after: observed.date, calendar: ny, lastObserved: observed))
    #expect(next.date == (try instant("2026-11-21T14:00:00Z")))
    #expect(try schedule.next(after: instant("2025-01-01T00:00:00Z"), calendar: ny, lastObserved: observed) == next)
    let different = try FocusReminderSchedule(rule: schedule.rule)
    #expect(throws: FocusReminderSchedule.ValidationError.invalidCursor) {
        try different.next(after: before, calendar: ny, lastObserved: observed)
    }
}

@Test func focusReminderOneShotKeepsAbsoluteDateAndDoesNotReplay() throws {
    let date = try instant("2026-11-20T10:00:00Z")
    let schedule = try FocusReminderSchedule(rule: .once(date))
    let before = date.addingTimeInterval(-1)
    let tokyo = try localCalendar("Asia/Tokyo"), ny = try localCalendar("America/New_York")
    let occurrence = try #require(try schedule.next(after: before, calendar: tokyo))
    #expect(occurrence.date == date && occurrence.civilDay == nil)
    #expect(try schedule.next(after: before, calendar: ny) == occurrence)
    #expect(try schedule.next(after: date, calendar: tokyo) == nil)
    #expect(try schedule.next(after: before, calendar: ny, lastObserved: occurrence) == nil)
}

@Test func focusReminderValidatesRulesAndDecodedVersion() throws {
    for rule in [FocusReminderSchedule.Rule.daily(hour: 24, minute: 0),
                 .daily(hour: 0, minute: -1), .weekdays(hour: 9, minute: 0, days: []),
                 .weekdays(hour: 9, minute: 0, days: [1, 1]), .weekdays(hour: 9, minute: 0, days: [8]),
                 .once(Date(timeIntervalSince1970: .nan))] {
        #expect(throws: FocusReminderSchedule.ValidationError.invalidRule) { try FocusReminderSchedule(rule: rule) }
    }
    let schedule = try FocusReminderSchedule(rule: .daily(hour: 9, minute: 0))
    let encoded = try JSONEncoder().encode(schedule)
    #expect(try JSONDecoder().decode(FocusReminderSchedule.self, from: encoded) == schedule)
    var record = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    record["version"] = 2
    #expect(throws: FocusReminderSchedule.ValidationError.unsupportedVersion) {
        try JSONDecoder().decode(FocusReminderSchedule.self, from: JSONSerialization.data(withJSONObject: record))
    }
    record["version"] = 1
    record["rule"] = ["daily": ["hour": 9, "minute": 60]]
    #expect(throws: FocusReminderSchedule.ValidationError.invalidRule) {
        try JSONDecoder().decode(FocusReminderSchedule.self, from: JSONSerialization.data(withJSONObject: record))
    }
}
