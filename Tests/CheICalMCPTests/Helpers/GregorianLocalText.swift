import Foundation

/// #304: the `*_local` text a response should carry for `date`, derived without a `DateFormatter`:
/// the Gregorian components in `zone`, printed with ASCII digits. Tests compare the server's
/// formatter with this, not with a formatter of their own, which under a non-Gregorian host locale
/// printed the same wrong year as the server did and so agreed with it.
enum GregorianLocalText {
    static func of(_ date: Date, in zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
