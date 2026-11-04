import Foundation

extension DateFormatter {
    /// #304: a formatter for a fixed-pattern date that a caller reads as data (the `*_local`
    /// strings, the recurrence `end_date`, `searched_from` / `searched_to`, the `undo_history`
    /// time). A `DateFormatter` left at its defaults takes the host locale, whose calendar decides
    /// the year (Buddhist 2569, ROC 0115, Japanese 0008, Islamic 1448 for 2026) and whose numbering
    /// system decides the digits (Arabic-Indic under `ar_SA`). `en_US_POSIX` gives Gregorian years
    /// and ASCII digits; a Gregorian calendar alone fixes the year but not the digits, so the
    /// locale is set and the calendar is pinned on top (checked with Foundation, 2026-11-05).
    ///
    /// For output only. The input parser keeps `FlexibleDate.formatter`, which sets the locale
    /// but no calendar: a formatter given an explicit calendar parses an impossible date
    /// leniently (#299).
    ///
    /// `hostDefault` is the formatter the host would hand out; tests pass one carrying another
    /// locale, since a test cannot change `Locale.current`. The locale is assigned before the
    /// calendar because assigning a locale resets the calendar to the locale's own.
    static func machineReadable(_ pattern: String, zone: TimeZone,
                                hostDefault: DateFormatter = DateFormatter()) -> DateFormatter {
        let formatter = hostDefault
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        formatter.calendar = gregorian
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter
    }
}
