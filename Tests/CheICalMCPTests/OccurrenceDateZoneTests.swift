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
        return try XCTUnwrap(SourcePins.body(of: "func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone?", in: source),
                             "EventKitManager.occurrenceDateTimeZone(identifier:) is missing")
    }

    /// #270: access is ensured before the event is looked up. A failed check is thrown (verify
    /// LOW): with `try?` the zone came back nil and the date was read in the host zone; now the
    /// caller gets the same access error the write would report, before anything is parsed.
    func testTheZoneIsReadAfterAccessIsEnsured() throws {
        let body = try managerMethod()
        let access = try XCTUnwrap(body.range(of: "try await ensureCalendarAccess()"))
        XCTAssertFalse(body.contains("try?"), "an access failure must not turn into a host-zone date")
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

    /// #270: `delete_event` resolves occurrence_date through `OccurrenceDateInput.resolve` (tested
    /// on values in `OccurrenceDateInputTests`) with the shared zone lookup; it parses nothing
    /// itself, so it cannot read the date in the host zone. A supplement to the value tests.
    func testDeleteEventResolvesTheDateThroughTheSharedSteps() throws {
        let source = try SourcePins.source("Server.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "private func handleDeleteEvent(arguments:", in: source))
        XCTAssertTrue(body.contains("OccurrenceDateInput.resolve("))
        XCTAssertTrue(body.contains("try await self.eventKitManager.occurrenceDateTimeZone(identifier: eventId)"))
        XCTAssertFalse(body.contains("parseFlexibleDate("))
    }

    /// `move_events_batch` reads the zone through `EventCopySource.eventTimeZone`, which
    /// delegates, so the two tools cannot drift apart again; it resolves each date the same way.
    func testMoveEventsBatchSharesTheMethod() throws {
        let source = try SourcePins.source("EventCopySource.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func eventTimeZone(identifier: String) async throws -> TimeZone? {", in: source))
        XCTAssertTrue(body.contains("try await occurrenceDateTimeZone(identifier: identifier)"))
        XCTAssertFalse(body.contains("ensureCalendarAccess"), "the access step lives in the shared method")
        let server = try SourcePins.source("Server.swift")
        let move = try XCTUnwrap(SourcePins.body(of: "private func handleMoveEventsBatch(arguments:", in: server))
        XCTAssertTrue(move.contains("OccurrenceDateInput.resolve("))
        XCTAssertTrue(move.contains("try await self.eventCopySource.eventTimeZone(identifier:"))
    }

    /// The zone lookup resolves the event without the edited-before refusal and the write may
    /// resolve it with it; both pick the same stand-in, because the refusal only ever turns the
    /// pick into nil (verify LOW). So whenever the write resolves an event at all, the zone came
    /// from that event.
    func testTheRefusalOnlyEverRemovesThePick() {
        typealias C = FirstRemainingOccurrence.Candidate
        let id = "S"
        let t = { (h: Double) in Date(timeIntervalSince1970: 1_800_000_000 + h * 3600) }
        let sets: [[C]] = [
            [],
            [C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: true, start: t(2)),
             C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: true, start: t(1))],
            [C(eventIdentifier: id, isDetached: true, hasRecurrenceRules: false, start: t(0), slot: t(0)),
             C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: true, start: t(1))],
            [C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: true, start: t(1)),
             C(eventIdentifier: id + "/RID=1", isDetached: true, hasRecurrenceRules: false, start: t(5), slot: t(3))],
            [C(eventIdentifier: "other", isDetached: false, hasRecurrenceRules: true, start: t(0)),
             C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: false, start: t(1))],
            [C(eventIdentifier: "x", isDetached: true, hasRecurrenceRules: false, start: t(0), sameSeriesByExternalID: true),
             C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: true, start: t(4)),
             C(eventIdentifier: id, isDetached: false, hasRecurrenceRules: true, start: t(4))],
        ]
        for (n, candidates) in sets.enumerated() {
            let lenient = FirstRemainingOccurrence.pick(candidates, identifier: id, refuseWhenEditedBefore: false)
            let strict = FirstRemainingOccurrence.pick(candidates, identifier: id, refuseWhenEditedBefore: true)
            XCTAssertTrue(strict == nil || strict == lenient, "set \(n): \(String(describing: strict)) vs \(String(describing: lenient))")
        }
        // The sets do exercise the refusal: set 2 is refused, set 3 is not.
        XCTAssertNil(FirstRemainingOccurrence.pick(sets[2], identifier: id, refuseWhenEditedBefore: true))
        XCTAssertNotNil(FirstRemainingOccurrence.pick(sets[2], identifier: id, refuseWhenEditedBefore: false))
        XCTAssertEqual(FirstRemainingOccurrence.pick(sets[3], identifier: id, refuseWhenEditedBefore: true), 0)
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
