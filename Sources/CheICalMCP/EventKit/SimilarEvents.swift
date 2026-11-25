import Foundation

/// Which events `create_events_batch` lists as similar to a row (#590). Pure, so the order of the
/// steps is tested without EventKit: the events in `excluding` (the batch's own written events) are
/// left out before anything else, so they cannot take a place of the limit; then the events whose
/// title contains a word (two or more characters) of `title`, case-insensitively, most recent first;
/// one per title and calendar (the most recent); at most `limit`.
enum SimilarEvents {
    static func select<Event>(_ events: [Event], title: String, excluding: Set<String>, limit: Int,
                              id: (Event) -> String?, title eventTitle: (Event) -> String?,
                              calendar: (Event) -> String, start: (Event) -> Date?) -> [Event] {
        let words = title.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 }
        let matches = events
            .filter { event in id(event).map { !excluding.contains($0) } ?? true }
            .filter { event in
                guard let candidate = eventTitle(event)?.lowercased() else { return false }
                return words.contains { candidate.contains($0) }
            }
            .sorted { (start($0) ?? .distantPast) > (start($1) ?? .distantPast) }
        var seen = Set<String>()
        var unique: [Event] = []
        for event in matches where unique.count < limit {
            let key = "\(eventTitle(event) ?? "")|\(calendar(event))"
            if seen.insert(key).inserted { unique.append(event) }
        }
        return unique
    }
}
