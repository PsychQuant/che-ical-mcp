import Foundation

/// #270 round 4: the day `findOccurrence` searches, `[start, end)`: the calendar day containing
/// `date` in `zone` (nil: the host zone, as before). Pure, so the zone is value-tested; a
/// `findOccurrence` that ignored its zone kept every test green before this.
enum OccurrenceDay {
    static func window(containing date: Date, in zone: TimeZone?) -> (start: Date, end: Date)? {
        var calendar = Calendar.current
        if let zone { calendar.timeZone = zone }
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }
}
