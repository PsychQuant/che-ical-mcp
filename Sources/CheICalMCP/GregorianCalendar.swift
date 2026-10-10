import Foundation

extension Calendar {
    /// #299: the Gregorian calendar in `zone`. EventKit's date components are Gregorian, while
    /// `Calendar.current` is the calendar chosen in region settings (Buddhist, ROC, Japanese,
    /// Islamic, …). Code that turns reminder components into instants or back uses this, never
    /// `Calendar.current`, so the year it reads or writes is the year EventKit means.
    static func gregorian(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
