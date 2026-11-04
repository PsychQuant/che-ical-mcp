import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #240: the event read tools (`list_events`, `list_events_quick`, `search_events`) report the
/// event's time-based alarms as `alarms`, in the reminder shape (#231). Driven through
/// `formatEventDict` with `FakeFormattableEvent`.
final class EventAlarmsReadTests: XCTestCase {
    private let absolute = Date(timeIntervalSince1970: 1_800_000_000)

    func testStandardOutputListsTheAlarms() async throws {
        let server = try await CheICalMCPServer()
        let dict = server.formatEventDict(FakeFormattableEvent(alarmsFragment: [.relative(seconds: -900), .absolute(absolute)]))
        let alarms = try XCTUnwrap(dict["alarms"] as? [[String: Any]])
        XCTAssertEqual(alarms.map { $0["kind"] as? String }, ["absolute", "relative"])
        XCTAssertEqual(alarms.last?["minutes_before"] as? Double, 15, "alarms_minutes_offsets [15] reads back as 15")
    }

    func testAnEventWithoutAlarmsListsAnEmptyArray() async throws {
        let server = try await CheICalMCPServer()
        let dict = server.formatEventDict(FakeFormattableEvent(alarmsFragment: []))
        XCTAssertEqual((dict["alarms"] as? [[String: Any]])?.count, 0)
    }

    func testSummaryLeavesAlarmsOut() async throws {
        let server = try await CheICalMCPServer()
        let dict = server.formatEventDict(FakeFormattableEvent(), detailLevel: "summary")
        XCTAssertNil(dict["alarms"])
    }

    func testFieldsCanSelectAlarms() async throws {
        let fields = try XCTUnwrap(InputValidation.parseFieldsFilter(["fields": .array([.string("alarms")])]))
        let server = try await CheICalMCPServer()
        let dict = server.formatEventDict(FakeFormattableEvent(), detailLevel: "summary", fields: fields)
        XCTAssertEqual(Set(dict.keys), ["id", "alarms"])
    }

    /// `absolute_date_local` is in the zone of the event's other `*_local` strings:
    /// `display_timezone` when given, otherwise the event's zone.
    func testAbsoluteLocalFollowsTheEventsLocalZone() async throws {
        let server = try await CheICalMCPServer()
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func local(_ dict: [String: Any]) -> String? { (dict["alarms"] as? [[String: Any]])?.first?["absolute_date_local"] as? String }
        let inEventZone = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: tokyo, alarmsFragment: [.absolute(absolute)]))
        XCTAssertEqual(local(inEventZone), DateFormatter.machineReadable("yyyy-MM-dd'T'HH:mm:ss", zone: tokyo).string(from: absolute))
        let inDisplay = server.formatEventDict(FakeFormattableEvent(formatSourceTimeZone: tokyo, alarmsFragment: [.absolute(absolute)]),
                                               displayTimezone: newYork)
        XCTAssertEqual(local(inDisplay), DateFormatter.machineReadable("yyyy-MM-dd'T'HH:mm:ss", zone: newYork).string(from: absolute))
        XCTAssertEqual((inDisplay["alarms"] as? [[String: Any]])?.first?["absolute_date"] as? String,
                       inDisplay["start_date"].map { _ in ISO8601DateFormatter().string(from: absolute) },
                       "absolute_date is UTC like start_date")
    }
}
