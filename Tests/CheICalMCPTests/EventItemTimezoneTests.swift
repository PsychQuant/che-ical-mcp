import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #386 (event-side sister of #241): every event dict reports `item_timezone`, the event's own
/// `EKEvent.timeZone` identifier, null when the event stores no zone (floating, all-day included).
/// `timezone` keeps its value: the event's zone, or the host zone when the event is floating, so on
/// its own it cannot tell a floating event from one stored in the host zone. Driven through
/// `formatEventDict` with `FakeFormattableEvent`.
final class EventItemTimezoneTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testAZonedEventReportsItsOwnZone() async throws {
        let server = try await CheICalMCPServer()
        let zone = TestZones.eventZone(differingFromHostAt: instant)
        let dict = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: zone))
        XCTAssertEqual(dict["item_timezone"] as? String, zone.identifier)
        XCTAssertEqual(dict["timezone"] as? String, zone.identifier, "timezone keeps its value")
    }

    func testAFloatingEventReportsNull() async throws {
        let server = try await CheICalMCPServer()
        let dict = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: nil))
        XCTAssertTrue(dict["item_timezone"] is NSNull, "\(String(describing: dict["item_timezone"]))")
        XCTAssertEqual(dict["timezone"] as? String, TimeZone.current.identifier, "timezone keeps its host-zone fallback")
    }

    /// An all-day event is stored without a zone (#190), so it reads like any floating event.
    func testAnAllDayEventReportsNull() async throws {
        let server = try await CheICalMCPServer()
        let dict = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: nil, formatIsAllDay: true))
        XCTAssertTrue(dict["item_timezone"] is NSNull)
    }

    /// The field qualifies `timezone`, which summary returns too.
    func testSummaryKeepsItemTimezone() async throws {
        let server = try await CheICalMCPServer()
        let zone = TestZones.eventZone(differingFromHostAt: instant)
        let dict = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: zone), detailLevel: "summary")
        XCTAssertEqual(dict["item_timezone"] as? String, zone.identifier)
    }

    /// `display_timezone` changes the `*_local` strings, not the event's own zone.
    func testDisplayTimezoneDoesNotChangeItemTimezone() async throws {
        let server = try await CheICalMCPServer()
        let zone = TestZones.eventZone(differingFromHostAt: instant)
        let display = TimeZone(identifier: "UTC")!
        let dict = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: zone), displayTimezone: display)
        XCTAssertEqual(dict["item_timezone"] as? String, zone.identifier)
    }

    func testFieldsSelectsItemTimezone() async throws {
        let server = try await CheICalMCPServer()
        XCTAssertTrue(InputValidation.validEventFields.contains("item_timezone"))
        let dict = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: nil), fields: ["item_timezone"])
        XCTAssertEqual(Set(dict.keys), ["id", "item_timezone"])
        XCTAssertTrue(dict["item_timezone"] is NSNull)
    }

    /// The JSON a client reads carries an explicit null, not a missing key.
    func testTheWireFormHasAnExplicitNull() async throws {
        let server = try await CheICalMCPServer()
        let json = try formatJSON(server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: nil), fields: ["item_timezone"]))
        XCTAssertTrue(json.contains("\"item_timezone\" : null") || json.contains("\"item_timezone\":null"), json)
    }
}
