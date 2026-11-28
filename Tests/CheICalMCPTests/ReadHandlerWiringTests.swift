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

    /// No code in `Server.swift` names the types `EKEvent` or `EKCalendar` (comments and strings
    /// blanked; `EKEventStore`, `EKSpan` and the like are other types and are allowed). This is a
    /// type-name check only: an inferred type slips past it. That the reads the handlers await
    /// return values is checked on the seams (`testTheSeamsReturnValuesBuiltOnTheActor`).
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
        // #604: list and search are declared in the protocol twice each (without and with a `calendar_id`),
        // in the protocol extension once each (the default of the new one), and in the manager twice each.
        XCTAssertEqual(SourcePins.ranges(of: "-> EventRowsPicked<Info>", in: range).count, 10, "list and search: protocol, its defaults and the manager")
        XCTAssertEqual(SourcePins.ranges(of: "-> [EventReadValue]", in: range).count, 5, "conflicts: protocol, its default and the manager")
        XCTAssertTrue(range.contains("-> [CalendarReadValue]"))
        let file = try SourcePins.source("EventRangeReadSource.swift")
        let manager = String(file[try XCTUnwrap(file.range(of: "extension EventKitManager:")).lowerBound...])
        for (method, pattern) in [("func checkConflictValues(", ".map(EventReadValue.init)"),
                                  ("func listCalendarValues(", "CalendarReadValue($0, entityTypes: [read.name])")] {
            let body = try XCTUnwrap(SourcePins.body(of: method, in: manager), method)
            XCTAssertTrue(body.contains(pattern), "\(method) builds values inside the actor with \(pattern)")
        }
        for method in ["func listEventValues<", "func searchEventValues<"] {
            let body = try XCTUnwrap(SourcePins.body(of: method, in: manager), method)
            XCTAssertTrue(body.contains("EventRowsPicked.picking("), "\(method) copies only the rows the handler keeps")
        }
    }

    /// PR #495 round 1: the conformance runs on the actor; a `nonisolated` method in it would read
    /// the store's events off it.
    func testTheManagersConformanceHasNoNonisolatedMember() throws {
        let file = try SourcePins.source("EventRangeReadSource.swift")
        let start = try XCTUnwrap(file.range(of: "extension EventKitManager: EventRangeReadSource, CalendarListSource"))
        let block = SourcePins.code(String(file[start.lowerBound...]))
        XCTAssertFalse(block.contains("nonisolated"))
    }
}
