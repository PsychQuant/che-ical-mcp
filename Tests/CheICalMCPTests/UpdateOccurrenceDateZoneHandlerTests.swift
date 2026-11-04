import MCP
import XCTest
@testable import CheICalMCP

/// #383: `update_event` read an offset-less `occurrence_date` in the request's `timezone` (the zone
/// to set on the event), or in the host zone without one, while `updateEvent` searched in the
/// event's zone. The date is now read the way `delete_event` and `move_events_batch` read it since
/// #270 (`OccurrenceDateInput.resolve` with the shared zone lookup): in the event's current zone,
/// whatever `timezone` says. Driven through `FakeEventWriteSource`, whose lookup answers the zone
/// the test gives it.
final class UpdateOccurrenceDateZoneHandlerTests: XCTestCase {
    private let day = "2026-12-06"

    private func update(_ fake: FakeEventWriteSource, _ args: [String: Value]) async throws -> EventUpdateRequest {
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_event", arguments: args)
        let updates = await fake.updates
        return try XCTUnwrap(updates.last)
    }

    /// A zone that differs from both the host zone and `other` on the tested day, so a mutation that
    /// read the date in either of them fails on any host.
    private func zone(differingFromHostAnd other: TimeZone) -> TimeZone {
        let instant = TestZones.noonUTC(day)
        let candidates = ["Pacific/Auckland", "Europe/London", "Asia/Kolkata"].compactMap(TimeZone.init(identifier:))
        return candidates.first {
            $0.secondsFromGMT(for: instant) != TimeZone.current.secondsFromGMT(for: instant)
                && $0.secondsFromGMT(for: instant) != other.secondsFromGMT(for: instant)
        }!
    }

    func testADateOnlyOccurrenceDateIsReadInTheEventsZone() async throws {
        let eventZone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let fake = FakeEventWriteSource(occurrenceZone: eventZone)
        let request = try await update(fake, ["event_id": .string("series"), "title": .string("Renamed"),
                                              "occurrence_date": .string(day)])
        XCTAssertEqual(request.occurrenceDate, TestZones.midnight(day, in: eventZone))
        let lookups = await fake.zoneLookups
        XCTAssertEqual(lookups, ["series"])
    }

    /// The decision recorded in the #383 Diagnosis: `timezone` is the zone the event gets; the
    /// occurrence being named sits in the zone the event has now.
    func testTheGivenTimezoneDoesNotChangeTheZoneTheDateIsReadIn() async throws {
        let eventZone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let newZone = zone(differingFromHostAnd: eventZone)
        let fake = FakeEventWriteSource(occurrenceZone: eventZone)
        let request = try await update(fake, ["event_id": .string("series"), "timezone": .string(newZone.identifier),
                                              "occurrence_date": .string(day)])
        XCTAssertEqual(request.occurrenceDate, TestZones.midnight(day, in: eventZone))
        XCTAssertEqual(request.timezone?.identifier, newZone.identifier, "timezone is still the zone to set")
    }

    /// A floating event has no zone: the date is read in the host zone, which is also the zone
    /// `findOccurrence` searches in for it, even when `timezone` names another zone.
    func testAFloatingEventReadsTheDateInTheHostZone() async throws {
        let newZone = zone(differingFromHostAnd: TimeZone.current)
        let fake = FakeEventWriteSource(occurrenceZone: nil)
        let request = try await update(fake, ["event_id": .string("series"), "timezone": .string(newZone.identifier),
                                              "occurrence_date": .string(day)])
        XCTAssertEqual(request.occurrenceDate, TestZones.midnight(day, in: TimeZone.current))
    }

    func testAnExplicitOffsetIsUsedAsGivenWithoutALookup() async throws {
        let fake = FakeEventWriteSource(occurrenceZone: TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day)))
        let request = try await update(fake, ["event_id": .string("series"),
                                              "occurrence_date": .string("2026-12-06T09:30:00+08:00")])
        XCTAssertEqual(request.occurrenceDate, ISO8601DateFormatter().date(from: "2026-12-06T01:30:00Z"))
        let lookups = await fake.zoneLookups
        XCTAssertEqual(lookups, [])
    }

    /// Span all does not use the date (the whole series is updated from its master), so no zone is
    /// looked up; the value is still checked as a date.
    func testSpanAllDoesNotLookUpTheZone() async throws {
        let fake = FakeEventWriteSource(occurrenceZone: TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day)))
        let request = try await update(fake, ["event_id": .string("series"), "span": .string("all"),
                                              "occurrence_date": .string(day)])
        XCTAssertTrue(request.applyToAll)
        let lookups = await fake.zoneLookups
        XCTAssertEqual(lookups, [])
    }

    /// A call without occurrence_date runs no lookup.
    func testNoOccurrenceDateNoLookup() async throws {
        let fake = FakeEventWriteSource(occurrenceZone: TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day)))
        let request = try await update(fake, ["event_id": .string("e1"), "title": .string("Renamed")])
        XCTAssertNil(request.occurrenceDate)
        let lookups = await fake.zoneLookups
        XCTAssertEqual(lookups, [])
    }
}
