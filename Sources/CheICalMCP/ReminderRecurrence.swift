import EventKit
import Foundation

/// An immutable copy: retaining EKRecurrenceRule would let later EventKit mutations
/// rewrite the target identity used by completion and undo.
struct ReminderRecurrenceRuleValue: Equatable, Sendable {
    struct Weekday: Equatable, Sendable {
        let day: Int
        let ordinal: Int
    }
    let frequency: String
    let frequencyRawValue: Int
    let interval: Int
    let calendarIdentifier: String?
    let firstDayOfWeek: Int
    let weekdays: [Weekday]?
    let daysOfMonth: [Int]?
    let monthsOfYear: [Int]?
    let weeksOfYear: [Int]?
    let daysOfYear: [Int]?
    let setPositions: [Int]?
    let endDate: Date?
    /// What the rule holds now: a rollover lowers it, so on a saved series it is the count left (#429).
    private(set) var occurrenceCount: Int?

    init(from rule: EKRecurrenceRule) {
        frequencyRawValue = rule.frequency.rawValue
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        interval = rule.interval
        calendarIdentifier = rule.calendarIdentifier
        firstDayOfWeek = rule.firstDayOfTheWeek
        weekdays = rule.daysOfTheWeek?.map { Weekday(day: $0.dayOfTheWeek.rawValue, ordinal: $0.weekNumber) }
        daysOfMonth = rule.daysOfTheMonth?.map(\.intValue)
        monthsOfYear = rule.monthsOfTheYear?.map(\.intValue)
        weeksOfYear = rule.weeksOfTheYear?.map(\.intValue)
        daysOfYear = rule.daysOfTheYear?.map(\.intValue)
        setPositions = rule.setPositions?.map(\.intValue)
        endDate = rule.recurrenceEnd?.endDate
        if let end = rule.recurrenceEnd, end.endDate == nil, end.occurrenceCount > 0 {
            occurrenceCount = end.occurrenceCount
        } else {
            occurrenceCount = nil
        }
    }

    /// Whether this rule, read after a rollover, is `before` carried over: unchanged, or with
    /// `occurrenceCount` exactly one lower and every other field equal. On iCloud a rollover lowers
    /// the count by one per completion, even when the due date skips occurrences (#429).
    func continues(_ before: Self) -> Bool {
        if self == before { return true }
        guard let remaining = occurrenceCount, let original = before.occurrenceCount,
              remaining == original - 1 else { return false }
        var restored = self
        restored.occurrenceCount = original
        return restored == before
    }

    var dictionary: [String: Any] {
        ["frequency": frequency, "frequency_raw_value": frequencyRawValue, "interval": interval,
         "calendar_identifier": nullable(calendarIdentifier), "first_day_of_week": firstDayOfWeek,
         "days_of_week": nullable(weekdays?.map(\.day)),
         "days_of_week_details": nullable(weekdays?.map { ["day": $0.day, "week_number": $0.ordinal] }),
         "days_of_month": nullable(daysOfMonth), "months_of_year": nullable(monthsOfYear),
         "weeks_of_year": nullable(weeksOfYear), "days_of_year": nullable(daysOfYear),
         "set_positions": nullable(setPositions), "end_date": nullable(endDate.map { utcString($0) }),
         "occurrence_count": nullable(occurrenceCount)]
    }
}

/// Keeps the source components as values, including precision, calendar and timezone.
/// `chronologicalDate` is only a comparison key for compatible due values; it is
/// deliberately not the wire date_time for floating or date-only reminders.
struct ReminderDueValue: Equatable, Sendable {
    let components: DateComponents

    init?(components: DateComponents?) {
        guard let components, components.year != nil,
              components.month != nil, components.day != nil else { return nil }
        // EventKit can attach derived week/weekday fields. They are not part of
        // occurrence identity and can change after a save without changing due.
        var normalized = DateComponents()
        normalized.calendar = components.calendar.map { Calendar(identifier: $0.identifier) }
        normalized.timeZone = components.timeZone
        normalized.era = components.era
        normalized.year = components.year
        normalized.month = components.month
        normalized.day = components.day
        normalized.hour = components.hour
        normalized.minute = components.minute
        normalized.second = components.second
        normalized.nanosecond = components.nanosecond
        normalized.isLeapMonth = components.isLeapMonth
        self.components = normalized
    }

    func hasSamePrecisionAndTimeZone(as other: Self) -> Bool {
        components.calendar?.identifier == other.components.calendar?.identifier &&
        components.timeZone == other.components.timeZone &&
        (components.era == nil) == (other.components.era == nil) &&
        (components.hour == nil) == (other.components.hour == nil) &&
        (components.minute == nil) == (other.components.minute == nil) &&
        (components.second == nil) == (other.components.second == nil) &&
        (components.nanosecond == nil) == (other.components.nanosecond == nil)
    }

    var chronologicalDate: Date? {
        var calendar = Calendar(identifier: components.calendar?.identifier ?? .gregorian)
        // A date-only value denotes a day, not a midnight in a particular zone.
        calendar.timeZone = components.hour == nil ? TimeZone(secondsFromGMT: 0)! :
            (components.timeZone ?? TimeZone(secondsFromGMT: 0)!)
        var wall = DateComponents()
        wall.era = components.era
        wall.year = components.year; wall.month = components.month; wall.day = components.day
        wall.isLeapMonth = components.isLeapMonth
        wall.hour = components.hour ?? 0; wall.minute = components.minute ?? 0
        wall.second = components.second ?? 0
        guard let candidate = calendar.date(from: wall) else { return nil }
        let fields: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
        let actual = calendar.dateComponents(fields, from: candidate)
        guard actual.year == wall.year, actual.month == wall.month, actual.day == wall.day,
              actual.hour == wall.hour, actual.minute == wall.minute, actual.second == wall.second,
              wall.era == nil || actual.era == wall.era,
              wall.isLeapMonth == nil || actual.isLeapMonth == wall.isLeapMonth else { return nil }
        // A repeated wall time cannot identify one absolute occurrence. Ask for
        // both matching policies instead of accepting Foundation's default fold.
        // Foundation's first/last policies can agree incorrectly for non-hour
        // folds (for example Lord Howe). Verify alternate nearby UTC offsets by
        // round-tripping the same wall components, without assuming a one-hour shift.
        let currentOffset = calendar.timeZone.secondsFromGMT(for: candidate)
        let nearbyOffsets = Set([-172800.0, 172800.0].map {
            calendar.timeZone.secondsFromGMT(for: candidate.addingTimeInterval($0))
        })
        for offset in nearbyOffsets where offset != currentOffset {
            let alternate = candidate.addingTimeInterval(Double(currentOffset - offset))
            let alternateWall = calendar.dateComponents(fields, from: alternate)
            if alternateWall.era == actual.era, alternateWall.year == actual.year,
               alternateWall.month == actual.month, alternateWall.day == actual.day,
               alternateWall.hour == actual.hour, alternateWall.minute == actual.minute,
               alternateWall.second == actual.second {
                return nil
            }
        }
        let start = calendar.startOfDay(for: candidate).addingTimeInterval(-1)
        var clock = DateComponents()
        clock.hour = wall.hour; clock.minute = wall.minute; clock.second = wall.second
        let first = calendar.nextDate(after: start, matching: clock, matchingPolicy: .strict,
                                      repeatedTimePolicy: .first, direction: .forward)
        let last = calendar.nextDate(after: start, matching: clock, matchingPolicy: .strict,
                                     repeatedTimePolicy: .last, direction: .forward)
        guard let first, first == last else { return nil }
        let nanos = components.nanosecond ?? 0
        guard (0..<1_000_000_000).contains(nanos) else { return nil }
        return first.addingTimeInterval(Double(nanos) / 1_000_000_000)
    }

    var dictionary: [String: Any] {
        let date = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        // HH:MM:SS; a missing minute/second is 00, as EventKit treats it. Sub-second (truncated)
        // precision is milliseconds on both `time` and `date_time`, printed only when it is
        // non-zero (#252: a start EventKit fills in reads back with `nanosecond = 0` while the
        // due has none, and the same time must render the same string on both).
        let millis = (components.nanosecond ?? 0) / 1_000_000
        let fraction = millis != 0 ? String(format: ".%03d", millis) : ""
        let time: String? = components.hour.map {
            String(format: "%02d:%02d:%02d", $0, components.minute ?? 0, components.second ?? 0) + fraction
        }
        // `date_time` shows the same truncated milliseconds as `time` (#252 verify: the ISO 8601
        // formatter rounds, so 999 999 999 ns read .999 on `time` and the next second on
        // `date_time`). The whole second is the instant without its sub-second part, and the
        // fraction is the one `time` carries. chronologicalDate still decides whether there is an
        // instant at all (it refuses a nanosecond outside 0..<1e9).
        var wholeSecond = components
        wholeSecond.nanosecond = nil
        let instant = components.hour != nil && components.timeZone != nil && chronologicalDate != nil
            ? ReminderDueValue(components: wholeSecond)?.chronologicalDate : nil
        return ["date": date, "time": nullable(time),
                "timezone": nullable(components.timeZone?.identifier),
                "calendar_identifier": nullable(components.calendar.map { String(describing: $0.identifier) }),
                "date_time": nullable(instant.map { String(utcString($0).dropLast()) + fraction + "Z" })]
    }
}

func reminderMetadata(hasRecurrence: Bool, rules: [ReminderRecurrenceRuleValue]?, due: ReminderDueValue?) -> [String: Any] {
    // Both names share one value; keep the legacy array/null contract (#198).
    let recurrence: Any = hasRecurrence ? nullable(rules.flatMap { $0.isEmpty ? nil : $0.map(\.dictionary) }) : []
    return ["has_recurrence": hasRecurrence,
            "recurrence_rules": recurrence,
            "reminder_recurrence_rules": recurrence,
            "due": nullable(due?.dictionary)]
}

private func nullable<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

/// `yyyy-MM-ddTHH:mm:ssZ` in UTC, whole seconds (the `Z` is always the last character).
private func utcString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
