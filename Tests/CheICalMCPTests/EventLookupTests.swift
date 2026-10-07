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

    /// Event ids are `eventIdentifier`s, which `calendarItem(withIdentifier:)` usually does not
    /// know: nil there is the normal case for an event, so the event lookup decides.
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

    // MARK: - Every lookup goes through the resolver

    /// Returns `file:line` for each call of `event(withIdentifier:` in `text`, comments excluded.
    static func eventLookups(in text: String, file: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])event\(\s*withIdentifier\s*:"#)
        var out: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.components(separatedBy: "//").first ?? line   // comments may name it
            let ns = code as NSString
            if regex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) != nil {
                out.append("\(file):\(i + 1)")
            }
        }
        return out
    }

    func testClassifierCatchesCallsAndIgnoresOtherLookupsAndComments() {
        XCTAssertEqual(Self.eventLookups(in: "let e = eventStore.event(withIdentifier: id)", file: "x"), ["x:1"])
        XCTAssertEqual(Self.eventLookups(in: "store.event( withIdentifier : id)", file: "x").count, 1)
        XCTAssertTrue(Self.eventLookups(in: "store.calendarItem(withIdentifier: id)", file: "x").isEmpty)
        XCTAssertTrue(Self.eventLookups(in: "// eventStore.event(withIdentifier:) returns the master", file: "x").isEmpty)
    }

    /// `getEventTimezone` and `getEvent` called `event(withIdentifier:)` directly before #260;
    /// `delete_event` runs the first of them before anything else. A new direct call would skip
    /// the reminder check again.
    func testOnlyTheResolverCallsTheEventLookup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var found: [String] = []
        for file in files {
            found += Self.eventLookups(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        XCTAssertEqual(found.map { $0.components(separatedBy: ":")[0] }, ["EventLookup.swift"],
                       "look events up with storedEvent(id:) (EventLookup), not event(withIdentifier:): \(found)")
    }
}
