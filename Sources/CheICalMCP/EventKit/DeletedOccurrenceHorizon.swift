import Foundation

/// #506 (maintainer decision, 2026-11-12: "放行，檢查到未來 2 年"): a series the listing does not cover
/// whole (open-ended, or ending about five years or more after its start) is checked for occurrences
/// deleted on their own up to a horizon, not to its end. The horizon is now plus `horizonYears`
/// calendar years, added on the wall clock of the series' zone (`Calendar.date(byAdding: .year, ...)`
/// in the zone the verdict expands the rule in; February 29 gives February 28). With no deletion found
/// in the listing, and the listing reaching the horizon without a gap from the first slot the write
/// reaches, the verdict is `noneThrough(end)`, `end` being the end of that unbroken listing (at or
/// after the horizon). An occurrence deleted on its own on or after it is not checked and comes back
/// with the write: the accepted risk, named in the response.
///
/// Applies only to a change of the start, end, all_day or zone in the same account (`updateEvent`
/// passes no horizon for a move to another account or a new rule pattern, and `move_events_batch`
/// and the undo of a move pass none), so those still need the whole series covered.
extension DeletedOccurrenceCheck {
    static let horizonYears = 2

    /// Now plus `horizonYears` years on `calendar`'s wall clock.
    static func horizon(now: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .year, value: horizonYears, to: now)
    }

    /// The range listed around now when the listing from the first start does not reach the horizon:
    /// from 1094 days before now (as #319's delete window looks back) to a day past the horizon.
    /// `listingRanges` adds a year on each side, so a series begun up to about nine years ago is
    /// listed without a gap; an older one leaves one between its first years and now.
    static func windowAroundNow(now: Date, horizon: Date) -> DateInterval {
        let day: TimeInterval = 86_400
        let start = now.addingTimeInterval(-1094 * day)
        return DateInterval(start: start, end: max(start, horizon.addingTimeInterval(day)))
    }

    /// The ranges the verdict lists the series over: #503's ranges (`listingRanges(for:)`) unless a
    /// horizon is given and they end before it; then the window around now is listed too, merged
    /// and cut into one-query pieces (`listingRanges(covering:)`).
    static func listingRanges(window: DateInterval, horizon: Date?, now: Date) -> [DateInterval] {
        let base = SeriesExceptionsPlanner.listingRanges(for: window)
        guard let horizon, let end = base.map(\.end).max(), end < horizon else { return base }
        return SeriesExceptionsPlanner.listingRanges(covering: [window, windowAroundNow(now: now, horizon: horizon)])
    }

    /// The end of the unbroken listing that holds `from` (ranges that meet or overlap count as one;
    /// start inclusive, end exclusive, as an EventKit range), nil when no range holds it.
    static func listedEnd(of ranges: [DateInterval], from: Date) -> Date? {
        var blocks: [DateInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = blocks.last, range.start <= last.end {
                blocks[blocks.count - 1] = DateInterval(start: last.start, end: max(last.end, range.end))
            } else {
                blocks.append(range)
            }
        }
        return blocks.first { $0.start <= from && from < $0.end }?.end
    }

    /// Whether `slot` is inside one of `ranges` (start inclusive, end exclusive).
    static func isListed(_ slot: Date, in ranges: [DateInterval]) -> Bool {
        ranges.contains { $0.start <= slot && slot < $0.end }
    }

    /// The sentence `update_event` adds when the verdict was `noneThrough`.
    static func horizonNote(checkedUntil: String) -> String {
        "The check cannot list this series whole (it has no end, ends about five years or more after its start, or has a count whose end the check cannot place), so occurrences deleted on their own were checked only before \(checkedUntil) (at least \(horizonYears) years from now, #506), and none was found. An occurrence deleted on its own on or after that date was not checked and may have come back with this write; undo does not remove it."
    }
}
