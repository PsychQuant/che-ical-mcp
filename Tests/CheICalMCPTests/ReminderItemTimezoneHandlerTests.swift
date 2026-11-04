import Foundation
import MCP
import XCTest
@testable import CheICalMCP

private actor ReminderItemZoneFake: ReminderReadSource {
    let values: [ReminderReadSnapshot]
    init(_ values: [ReminderReadSnapshot]) { self.values = values }
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] { values }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] { values }
}

/// #241: `list_reminders` and `search_reminders` report the reminder's own zone as
/// `item_timezone` (null when floating); `timezone` stays the zone of the `*_local` strings.
final class ReminderItemTimezoneHandlerTests: XCTestCase {
    private let tools: [(String, [String: Value])] = [("list_reminders", [:]),
                                                      ("search_reminders", ["keyword": .string("R")])]

    /// A zone that differs from the host, so a host-zone fallback cannot pass the test.
    private var nonHostZone: TimeZone {
        let newYork = TimeZone(identifier: "America/New_York")!
        return TimeZone.current.secondsFromGMT() == newYork.secondsFromGMT()
            ? TimeZone(identifier: "Asia/Tokyo")! : newYork
    }

    private func item(_ tool: String, _ args: [String: Value], _ snapshot: ReminderReadSnapshot) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(reminderReadSource: ReminderItemZoneFake([snapshot]))
        let raw = try await server.executeToolCall(name: tool, arguments: args)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], tool)
        return try XCTUnwrap((json["reminders"] as? [[String: Any]])?.first, tool)
    }

    func testFloatingReminderReportsNullItemTimezone() async throws {
        let snapshot = ReminderReadSnapshot(id: "floating", title: "R",
                                            dueDateComponents: DateComponents(year: 2026, month: 12, day: 1, hour: 9, minute: 0))
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            XCTAssertTrue(value.keys.contains("item_timezone"), "item_timezone is present even when floating: \(tool)")
            XCTAssertTrue(value["item_timezone"] is NSNull, tool)
        }
    }

    func testZonedReminderReportsItsOwnZoneAsItemTimezone() async throws {
        let zone = nonHostZone
        let snapshot = ReminderReadSnapshot(id: "zoned", title: "R", timeZone: zone)
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            XCTAssertEqual(value["item_timezone"] as? String, zone.identifier, tool)
        }
    }

    /// `timezone` keeps naming the zone of the `*_local` strings (the host zone).
    func testTimezoneStaysTheHostZoneWhateverTheItemZone() async throws {
        let snapshot = ReminderReadSnapshot(id: "zoned", title: "R", timeZone: nonHostZone)
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            XCTAssertEqual(value["timezone"] as? String, TimeZone.current.identifier, tool)
        }
    }
}
