import XCTest
@testable import CheICalMCP

/// #590: `SimilarEvents.select`, the choice behind `create_events_batch`'s `similar_events`, over
/// plain values. The batch's own events are left out before the limit and the one-per-title rule.
final class SimilarEventsTests: XCTestCase {
    private struct Event { let id: String?; let title: String?; let calendar: String; let start: Date }

    private func select(_ events: [Event], title: String, excluding: Set<String> = [], limit: Int = 3) -> [String?] {
        SimilarEvents.select(events, title: title, excluding: excluding, limit: limit,
                             id: { $0.id }, title: { $0.title }, calendar: { $0.calendar }, start: { $0.start }).map(\.id)
    }

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    /// A newer event the batch wrote, with the same title as an older one, does not crowd it out.
    func testTheBatchsOwnEventIsLeftOutBeforeTheOnePerTitleRule() {
        let events = [Event(id: "created-1", title: "Standup", calendar: "A", start: at(100)),
                      Event(id: "older", title: "Standup", calendar: "A", start: at(0))]
        XCTAssertEqual(select(events, title: "Standup", excluding: ["created-1"]), ["older"])
        XCTAssertEqual(select(events, title: "Standup"), ["created-1"], "without the exclusion, the newest of the title")
    }

    /// The limit counts only the events that can be listed.
    func testTheBatchsOwnEventsTakeNoPlaceOfTheLimit() {
        let own = (1...3).map { Event(id: "created-\($0)", title: "Standup \($0)", calendar: "A", start: at(Double(100 + $0))) }
        let others = [Event(id: "a", title: "Standup a", calendar: "A", start: at(2)), Event(id: "b", title: "Standup b", calendar: "A", start: at(1))]
        XCTAssertEqual(select(own + others, title: "Standup", excluding: Set(own.compactMap(\.id))), ["a", "b"])
    }

    /// Matching by a word of two or more characters, most recent first, one per title and calendar.
    func testMatchingOrderAndOnePerTitleAndCalendar() {
        let events = [Event(id: "1", title: "Weekly standup", calendar: "A", start: at(10)),
                      Event(id: "2", title: "Weekly standup", calendar: "A", start: at(20)),
                      Event(id: "3", title: "Weekly standup", calendar: "B", start: at(5)),
                      Event(id: "4", title: "Lunch", calendar: "A", start: at(30)),
                      Event(id: "5", title: nil, calendar: "A", start: at(40))]
        XCTAssertEqual(select(events, title: "standup"), ["2", "3"])
        XCTAssertEqual(select(events, title: "a"), [], "a one-character word matches nothing")
        XCTAssertEqual(select(events, title: "STANDUP", limit: 1), ["2"])
    }
}
