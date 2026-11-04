import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #270 round 3: `delete_event` through the `EventDeletionSource` seam. The date that reaches the
/// delete is checked, not just the call that computes it: a handler that resolved the date and
/// then passed a host-zone parse to the delete passed every earlier test.
private actor DeletionFake: EventDeletionSource {
    struct Delete: Equatable { let identifier: String; let span: EKSpan; let occurrenceDate: Date? }
    private(set) var deletes: [Delete] = []
    private(set) var seriesDeletes: [String] = []
    private(set) var lookups: [String] = []

    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? {
        lookups.append(identifier)
        if identifier == "denied" { throw EventKitError.accessDenied(type: "calendar") }
        return TestZones.eventZone(differingFromHostAt: TestZones.noonUTC("2026-12-06"))
    }
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws {
        deletes.append(Delete(identifier: identifier, span: span, occurrenceDate: occurrenceDate))
    }
    func deleteEventSeries(identifier: String) async throws {
        seriesDeletes.append(identifier)
    }
}

final class EventDeletionHandlerTests: XCTestCase {
    /// Midnight of Dec 6 in the event's zone (New York, or Tokyo on a host with New York's offset,
    /// round 4); a host-zone parse gives another instant on any host.
    private let newYorkMidnight: Date? = TestZones.midnight("2026-12-06",
        in: TestZones.eventZone(differingFromHostAt: TestZones.noonUTC("2026-12-06")))

    private func delete(_ fake: DeletionFake, _ args: [String: Value]) async throws {
        let server = try await CheICalMCPServer(eventDeletionSource: fake)
        _ = try await server.executeToolCall(name: "delete_event", arguments: args)
    }

    func testADateOnlyOccurrenceDateReachesTheDeleteInTheEventsZone() async throws {
        for (span, ekSpan) in [("this", EKSpan.thisEvent), ("future", EKSpan.futureEvents)] {
            let fake = DeletionFake()
            try await delete(fake, ["event_id": .string("ny-series"), "occurrence_date": .string("2026-12-06"),
                                    "span": .string(span)])
            let deletes = await fake.deletes
            XCTAssertEqual(deletes, [.init(identifier: "ny-series", span: ekSpan, occurrenceDate: newYorkMidnight)], span)
            let lookups = await fake.lookups
            XCTAssertEqual(lookups, ["ny-series"], span)
        }
    }

    /// Span all deletes the series with no date and does not look the zone up.
    func testSpanAllDeletesTheSeriesWithoutADate() async throws {
        let fake = DeletionFake()
        try await delete(fake, ["event_id": .string("ny-series"), "occurrence_date": .string("2026-12-06"), "span": .string("all")])
        let series = await fake.seriesDeletes
        let deletes = await fake.deletes
        let lookups = await fake.lookups
        XCTAssertEqual(series, ["ny-series"])
        XCTAssertEqual(deletes, [])
        XCTAssertEqual(lookups, [])
    }

    func testNoOccurrenceDatePassesNilWithoutALookup() async throws {
        let fake = DeletionFake()
        try await delete(fake, ["event_id": .string("one-off")])
        let deletes = await fake.deletes
        let lookups = await fake.lookups
        XCTAssertEqual(deletes, [.init(identifier: "one-off", span: .thisEvent, occurrenceDate: nil)])
        XCTAssertEqual(lookups, [])
    }

    /// The access error from the zone lookup reaches the caller, and nothing is deleted.
    func testAnAccessErrorReachesTheCallerBeforeAnyDelete() async throws {
        let fake = DeletionFake()
        do {
            try await delete(fake, ["event_id": .string("denied"), "occurrence_date": .string("2026-12-06")])
            XCTFail("the access error must surface")
        } catch let error as EventKitError {
            guard case .accessDenied = error else { return XCTFail("\(error)") }
        }
        let deletes = await fake.deletes
        let series = await fake.seriesDeletes
        XCTAssertEqual(deletes, [])
        XCTAssertEqual(series, [])
    }
}
