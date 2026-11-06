import Foundation

/// The one rule for matching a calendar name (#437): the exact title, or, when no title matches
/// exactly, the title ignoring case. `findCalendars` and `find_duplicate_events` both use it.
enum CalendarNameMatch {
    static func matching<Item>(_ all: [Item], name: String, source: String?,
                                   title: (Item) -> String, sourceTitle: (Item) -> String) -> [Item] {
        let exact = all.filter { title($0) == name && (source == nil || sourceTitle($0) == source) }
        guard exact.isEmpty else { return exact }
        let lowerName = name.lowercased()
        let lowerSource = source?.lowercased()
        return all.filter { title($0).lowercased() == lowerName && (lowerSource == nil || sourceTitle($0).lowercased() == lowerSource) }
    }
}

/// #437: which calendars `find_duplicate_events` reads. It only compares different calendars, so a
/// name that matched nothing used to answer a false `duplicate_count` of 0, and no match at all read
/// every calendar (`[]` reads as all). A name two accounts share reads both, unlike `findCalendars`:
/// this tool has no `calendar_source`, and those two are what is compared before merging.
enum DuplicateCalendars {
    /// All of `all` without names. Refuses a name that matches nothing, then fewer than two calendars.
    static func resolve<Item>(names: [String]?, among all: [Item], identifier: (Item) -> String,
                                  title: (Item) -> String, sourceTitle: (Item) -> String) throws -> [Item] {
        var read = all
        if let names {
            var seen = Set<String>()
            read = []
            for name in names {
                let matched = CalendarNameMatch.matching(all, name: name, source: nil, title: title, sourceTitle: sourceTitle)
                guard !matched.isEmpty else { throw EventKitError.calendarNotFound(identifier: name) }
                read += matched.filter { seen.insert(identifier($0)).inserted }
            }
        }
        guard read.count >= 2 else { throw EventKitError.tooFewCalendarsToCompare(found: read.count, named: names != nil) }
        return read
    }

    /// `calendars_checked`: the titles read, with the account where two share a title. For reading,
    /// not a name to pass back: `calendar_names` takes titles. Two calendars of one title in one
    /// account get one label.
    static func checkedLabels<Item>(_ read: [Item], title: (Item) -> String,
                                        sourceTitle: (Item) -> String) -> [String] {
        let titles = read.map(title)
        return read.map { calendar in
            let name = title(calendar)
            return titles.filter { $0 == name }.count > 1 ? "\(name) (\(sourceTitle(calendar)))" : name
        }
    }
}

/// What `find_duplicate_events` read and found.
struct DuplicateSearchValue: Sendable {
    let calendarsChecked: [String]
    let pairs: [DuplicatePair]
}

/// #437: the narrow seam `find_duplicate_events` goes through (CLAUDE.md "Test Seam Convention"), so
/// a handler test reads the response. Production passes nothing and gets `EventKitManager.shared`.
protocol DuplicateSearchSource: Sendable {
    func findDuplicateEvents(calendarNames: [String]?, startDate: Date, endDate: Date,
                             toleranceMinutes: Int) async throws -> DuplicateSearchValue
}

extension EventKitManager: DuplicateSearchSource {}
