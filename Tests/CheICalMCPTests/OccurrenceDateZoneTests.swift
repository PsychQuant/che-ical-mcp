import XCTest
@testable import CheICalMCP

/// #270: the zone a date-only `occurrence_date` is read in. `delete_event` read it with
/// `getEventTimezone` before calendar access was ensured: before access was ever granted the
/// lookup finds nothing and the date is read in the server zone. One manager method now ensures
/// access first, and `delete_event` and `move_events_batch` share it. An in-memory store cannot
/// withhold access, so the wiring is pinned in the source. #271: that lookup also read the stored
/// object without `refresh()`, so after the event's zone was changed elsewhere the old zone came
/// back; an in-memory store cannot return a stale object either.
final class OccurrenceDateZoneTests: XCTestCase {
    private func managerMethod() throws -> String {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        return try XCTUnwrap(SourcePins.body(of: "func occurrenceDateTimeZone(identifier: String) async -> TimeZone?", in: source),
                             "EventKitManager.occurrenceDateTimeZone(identifier:) is missing")
    }

    /// #270: access is ensured before the event is looked up.
    func testTheZoneIsReadAfterAccessIsEnsured() throws {
        let body = try managerMethod()
        let access = try XCTUnwrap(body.range(of: "try? await ensureCalendarAccess()"),
                                   "a denial must not be reported here; the write reports it")
        let lookup = try XCTUnwrap(body.range(of: "(id: identifier"))
        XCTAssertLessThan(access.lowerBound, lookup.lowerBound)
    }

    /// #271: the lookup is the one the write uses (`freshEventWithOrigin`, which refreshes the
    /// object; a stored object kept its old zone after an edit made elsewhere), without the
    /// edited-before refusal, since only the zone is needed and the write applies its own.
    func testTheZoneComesFromTheRefreshedEvent() throws {
        let body = try managerMethod()
        XCTAssertTrue(body.contains("freshEventWithOrigin(id: identifier, refuseWhenEditedBefore: false)?.event.timeZone"))
        XCTAssertFalse(body.contains("storedEvent("), "the stored object is not refreshed")
    }

    /// #270: `delete_event` takes the zone from the shared method, not from a lookup of its own.
    func testDeleteEventReadsTheZoneThroughTheSharedMethod() throws {
        let source = try SourcePins.source("Server.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "private func handleDeleteEvent(arguments:", in: source))
        let zone = try XCTUnwrap(body.range(of: "await eventKitManager.occurrenceDateTimeZone(identifier: eventId)"))
        let parse = try XCTUnwrap(body.range(of: "parseFlexibleDate("))
        XCTAssertLessThan(zone.lowerBound, parse.lowerBound)
    }

    /// `move_events_batch` reads the zone through `EventCopySource.eventTimeZone`, which now
    /// delegates, so the two tools cannot drift apart again.
    func testMoveEventsBatchSharesTheMethod() throws {
        let source = try SourcePins.source("EventCopySource.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func eventTimeZone(identifier: String) async -> TimeZone? {", in: source))
        XCTAssertTrue(body.contains("await occurrenceDateTimeZone(identifier: identifier)"))
        XCTAssertFalse(body.contains("ensureCalendarAccess"), "the access step lives in the shared method")
    }

    /// The old lookup is gone, so no caller can read the zone before access is ensured.
    func testNoCallerKeepsTheOldLookup() throws {
        var found: [String] = []
        for file in try SourceScan.swiftFiles() {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            if code.contains("getEventTimezone") { found.append(file.lastPathComponent) }
        }
        XCTAssertEqual(found, [])
    }
}
