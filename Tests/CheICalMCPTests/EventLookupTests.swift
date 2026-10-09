import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// #260: an event id from the caller can be a reminder's id. `event(withIdentifier:)` given one
/// raises an Objective-C exception Swift cannot catch, so the server aborts. The resolver checks
/// the item's kind with `calendarItem(withIdentifier:)` first and never calls the event lookup for
/// a reminder.
final class EventLookupTests: XCTestCase {
    private let store = EKEventStore()

    private final class Calls {
        var calendarItem: [String] = []
        var event: [String] = []
    }

    private func resolve(_ id: String, calendarItem item: EKCalendarItem?, event: EKEvent?) -> (EKEvent?, Calls) {
        let calls = Calls()
        let result = EventLookup.event(
            identifier: id,
            calendarItem: { calls.calendarItem.append($0); return item },
            event: { calls.event.append($0); return event })
        return (result, calls)
    }

    func testAReminderIdIsNotFoundAndTheEventLookupIsNeverCalled() {
        let reminder = EKReminder(eventStore: store)
        let (result, calls) = resolve("reminder-id", calendarItem: reminder, event: EKEvent(eventStore: store))
        XCTAssertNil(result)
        XCTAssertEqual(calls.calendarItem, ["reminder-id"])
        XCTAssertEqual(calls.event, [], "event(withIdentifier:) aborts the process on a reminder id")
    }

    /// Event ids are `eventIdentifier`s, for which `calendarItem(withIdentifier:)` returned nil on
    /// device (iCloud and Google): nil there is the normal case for an event, so the event lookup
    /// decides.
    func testAnIdTheItemLookupDoesNotKnowGoesToTheEventLookup() {
        let event = EKEvent(eventStore: store)
        let (result, calls) = resolve("event-id", calendarItem: nil, event: event)
        XCTAssertTrue(result === event)
        XCTAssertEqual(calls.event, ["event-id"])
    }

    /// The event lookup still runs for an event the item lookup returns: it is the one with the
    /// recurring-series semantics the callers rely on.
    func testAnEventFromTheItemLookupStillGoesThroughTheEventLookup() {
        let fromItemLookup = EKEvent(eventStore: store)
        let fromEventLookup = EKEvent(eventStore: store)
        let (result, calls) = resolve("event-id", calendarItem: fromItemLookup, event: fromEventLookup)
        XCTAssertTrue(result === fromEventLookup)
        XCTAssertEqual(calls.event, ["event-id"])
    }

    func testAnUnknownIdIsNotFound() {
        let (result, calls) = resolve("missing", calendarItem: nil, event: nil)
        XCTAssertNil(result)
        XCTAssertEqual(calls.event, ["missing"])
    }

    func testAnEmptyIdCallsNeitherLookup() {
        let (result, calls) = resolve("", calendarItem: EKReminder(eventStore: store), event: EKEvent(eventStore: store))
        XCTAssertNil(result)
        XCTAssertEqual(calls.calendarItem, [])
        XCTAssertEqual(calls.event, [])
    }

    // MARK: - The store is wired through the kind check

    /// A store whose two lookups are scripted and recorded.
    private final class FakeStore: EventLookupSource {
        let item: EKCalendarItem?
        let found: EKEvent?
        var calendarItemCalls: [String] = []
        var eventCalls: [String] = []
        init(item: EKCalendarItem?, found: EKEvent?) { self.item = item; self.found = found }
        func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? { calendarItemCalls.append(identifier); return item }
        func event(withIdentifier identifier: String) -> EKEvent? { eventCalls.append(identifier); return found }
    }

    /// `storedEvent(id:)` hands the manager's store to this; the kind check must ask the store's
    /// own `calendarItem(withIdentifier:)`. A wiring that skips it (`{ _ in nil }`) passes the
    /// resolver tests above and still aborts on a reminder's id.
    func testAStoreThatHoldsAReminderUnderTheIdIsNeverAskedForAnEvent() {
        let fake = FakeStore(item: EKReminder(eventStore: store), found: EKEvent(eventStore: store))
        XCTAssertNil(EventLookup.event(identifier: "reminder-id", in: fake))
        XCTAssertEqual(fake.calendarItemCalls, ["reminder-id"])
        XCTAssertEqual(fake.eventCalls, [])
    }

    func testAStoreWithoutAnItemUnderTheIdIsAskedForTheEvent() {
        let event = EKEvent(eventStore: store)
        let fake = FakeStore(item: nil, found: event)
        XCTAssertTrue(EventLookup.event(identifier: "event-id", in: fake) === event)
        XCTAssertEqual(fake.calendarItemCalls, ["event-id"])
        XCTAssertEqual(fake.eventCalls, ["event-id"])
    }

    // MARK: - Every lookup goes through the resolver

    /// `file:line` of each `event(withIdentifier:` call in `text`, of each `eventWithIdentifier`
    /// (the selector, e.g. in `NSSelectorFromString`) and of each unlabeled reference to the
    /// method on a receiver named `…store` / `…Store` (`eventStore.event`, as this code names its
    /// stores), comments excluded. The whole file is matched, so a call split over lines counts.
    /// A declaration with an internal parameter name (`func event(withIdentifier identifier:
    /// String)`, the protocol's spelling) is not matched; one without would be, a false alarm.
    static func eventLookups(in text: String, file: String) -> [String] {
        let code = SourceScan.strippingComments(text)
        let ns = code as NSString
        let patterns = [#"(?<![A-Za-z0-9_])event\s*\(\s*withIdentifier\s*:"#, #"eventWithIdentifier"#,
                        #"(?<![A-Za-z0-9_])[A-Za-z0-9_]*[Ss]tore\s*\.\s*event\b(?!\s*\()"#]
        var offsets: [Int] = []
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            offsets += regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        }
        return offsets.sorted().map { offset in
            let line = ns.substring(to: offset).unicodeScalars.filter { $0 == "\n" }.count + 1
            return "\(file):\(line)"
        }
    }

    func testClassifierCatchesCallsAndIgnoresOtherLookupsAndComments() {
        XCTAssertEqual(Self.eventLookups(in: "let e = eventStore.event(withIdentifier: id)", file: "x"), ["x:1"])
        XCTAssertEqual(Self.eventLookups(in: "store.event( withIdentifier : id)", file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: "store.event (withIdentifier: id)", file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: "let a = 1\nlet e = store.event(\n    withIdentifier: id)", file: "x"), ["x:2"])
        XCTAssertEqual(Self.eventLookups(in: "let lookup = store.event(withIdentifier:)", file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: #"store.perform(NSSelectorFromString("eventWithIdentifier:"), with: id)"#, file: "x").count, 1)
        XCTAssertTrue(Self.eventLookups(in: "store.calendarItem(withIdentifier: id)", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "func event(withIdentifier identifier: String) -> EKEvent?", file: "x").isEmpty)
    }

    /// `event` is the only method of that name on `EKEventStore`, so it can be passed without its
    /// label (`ids.map(store.event)`); such a reference reaches the same lookup.
    func testClassifierCatchesUnlabeledReferencesToAStoresEventMethod() {
        XCTAssertEqual(Self.eventLookups(in: "let f: (String) -> EKEvent? = store.event", file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: "let found = ids.compactMap(eventStore.event)", file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(
            in: "EventLookup.event(identifier: id, calendarItem: { _ in nil }, event: eventStore.event)", file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: "let g = self.eventStore . event\n", file: "x").count, 1)
        XCTAssertTrue(Self.eventLookups(in: "store.events(matching: predicate)", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "let id = store.eventIdentifier", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "let t = result.event.title; let k = EKEntityType.event", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "store.calendars(for: .event)", file: "x").isEmpty)
    }

    func testClassifierSkipsCommentsButNotStringsThatLookLikeThem() {
        XCTAssertTrue(Self.eventLookups(in: "// eventStore.event(withIdentifier:) returns the master", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "/* store.event(withIdentifier: id) */ let a = 1", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "/* outer /* inner */ store.event(withIdentifier: id) */", file: "x").isEmpty)
        XCTAssertEqual(Self.eventLookups(in: #"let u = "https://example.com"; let e = store.event(withIdentifier: id)"#, file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: ##"let r = #"a//b"#; let e = store.event(withIdentifier: id)"##, file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: #"let s = "\(f("//"))"; let e = store.event(withIdentifier: id)"#, file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: "let s = \"\"\"\n// not a comment\n\"\"\"\nlet e = store.event(withIdentifier: id)", file: "x"), ["x:4"])
        XCTAssertEqual(Self.eventLookups(in: "// c\r\nlet e = store.event(withIdentifier: id)", file: "x"), ["x:2"])
        XCTAssertEqual(Self.eventLookups(in: #"let r = /https?:\/\//; let e = store.event(withIdentifier: id)"#, file: "x").count, 1)
        XCTAssertEqual(Self.eventLookups(in: "let r = #/a//b/#; let e = store.event(withIdentifier: id)", file: "x").count, 1)
    }

    /// `getEventTimezone` and `getEvent` called `event(withIdentifier:)` directly before #260;
    /// `delete_event` runs the first of them before anything else. Exactly one call may exist, the
    /// resolver's in `EventLookup.swift`: a second one, even in that file (`storedEvent(id:)`
    /// returning `eventStore.event(withIdentifier: id)`), skips the reminder check again.
    /// The scan above counts calls and references to the event lookup, not which store reaches
    /// the kind check: `EventLookup.event(identifier: id, calendarItem: { _ in nil }, event: …)`
    /// in `storedEvent(id:)` would skip it while the resolver tests still pass. So the one wiring
    /// line is pinned as text (comments removed, whitespace collapsed); a guard against a revert,
    /// which a rename of `id` or `eventStore` also turns red.
    func testStoredEventHandsTheManagersStoreToTheResolver() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventLookup.swift")
        let code = SourceScan.collapsingWhitespace(
            SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        let body = try XCTUnwrap(SourceScan.body(of: "func storedEvent(id: String) -> EKEvent? {", in: code))
        XCTAssertEqual(body.trimmingCharacters(in: .whitespaces), "EventLookup.event(identifier: id, in: eventStore)")
    }

    func testOnlyTheResolverCallsTheEventLookup() throws {
        var found: [String] = []
        for file in try SourceScan.swiftFiles() {
            found += Self.eventLookups(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        XCTAssertEqual(found.map { $0.components(separatedBy: ":")[0] }, ["EventLookup.swift"],
                       "look events up with storedEvent(id:) (EventLookup), not event(withIdentifier:): \(found)")
    }
}
