import XCTest
@testable import CheICalMCP

/// #490: the read handlers (`list_calendars`, `list_events`, `search_events`, `list_events_quick`,
/// `check_conflicts`) used to receive `EKCalendar` / `EKEvent` objects from the `EventKitManager`
/// actor and read their properties off it, in the server's nonisolated handlers and in
/// `formatEventDict`. They receive values built on the actor now (`EventReadValue`,
/// `CalendarReadValue`). An in-memory store cannot show where a property is read, so these pins
/// read the source; `ReadValueIsolationHandlerTests` drives the handlers through a source whose
/// event traps off its actor.
final class ReadHandlerWiringTests: XCTestCase {
    private struct Missing: Error, CustomStringConvertible { let description: String }

    private static func code(_ file: String) throws -> String {
        SourcePins.code(try SourcePins.source(file))
    }

    /// No code in `Server.swift` names an EventKit event or calendar object, so no handler can read
    /// one's properties (comments and strings blanked; `EKEventStore`, `EKSpan` and the like are
    /// other types and are allowed).
    func testTheServerHoldsNoEventKitEventOrCalendar() throws {
        let server = try Self.code("Server.swift")
        for type in ["EKEvent", "EKCalendar"] {
            let uses = SourcePins.ranges(ofPattern: "\\b\(type)\\b", in: server)
            XCTAssertTrue(uses.isEmpty, "\(type) appears \(uses.count) time(s) in Server.swift")
        }
    }

    /// The five read handlers go through the narrow read seams, never through `eventKitManager`.
    func testTheReadHandlersGoThroughTheValueSeams() throws {
        let source = try SourcePins.source("Server.swift")
        for handler in ["handleListCalendars", "handleListEvents(", "handleSearchEvents", "handleListEventsQuick", "handleCheckConflicts"] {
            let declaration = handler.hasSuffix("(") ? "private func \(handler)" : "private func \(handler)("
            guard let body = SourcePins.body(of: declaration, in: source) else {
                throw Missing(description: "not found: \(declaration)")
            }
            XCTAssertFalse(body.contains("eventKitManager."), "\(handler) reads through the manager directly")
        }
    }

    /// The seams return values, and the manager builds them on its actor.
    func testTheSeamsReturnValuesBuiltOnTheActor() throws {
        let range = try Self.code("EventRangeReadSource.swift")
        XCTAssertFalse(range.contains("[EKEvent]"), "EventRangeReadSource returns no EventKit objects")
        XCTAssertEqual(SourcePins.ranges(of: "-> [EventReadValue]", in: range).count, 6, "list, search, conflicts: protocol and the manager")
        XCTAssertTrue(range.contains("-> [CalendarReadValue]"))
        let file = try SourcePins.source("EventRangeReadSource.swift")
        let manager = String(file[try XCTUnwrap(file.range(of: "extension EventKitManager:")).lowerBound...])
        for method in ["func listEventValues(", "func searchEventValues(", "func checkConflictValues(", "func listCalendarValues("] {
            let body = try XCTUnwrap(SourcePins.body(of: method, in: manager), method)
            XCTAssertTrue(body.contains(".map(EventReadValue.init)") || body.contains(".map(CalendarReadValue.init)"),
                          "\(method) maps to values inside the actor")
        }
    }
}
