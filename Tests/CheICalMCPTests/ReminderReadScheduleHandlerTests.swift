import Foundation
import MCP
import XCTest
@testable import CheICalMCP

private actor ReminderScheduleFake: ReminderReadSource {
    let values: [ReminderReadSnapshot]
    init(_ values: [ReminderReadSnapshot]) { self.values = values }
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] { values }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] { values }
}

/// #231: both reminder read tools report the start date (`start`, `start_date`,
/// `start_date_local`) and the time-based alarms (`alarms`) next to the due date.
final class ReminderReadScheduleHandlerTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let tools: [(String, [String: Value])] = [("list_reminders", [:]),
                                                      ("search_reminders", ["keyword": .string("R")])]

    /// The `*_local` strings use the server's host-zone formatter, as `due_date_local` does.
    private func hostLocal(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func item(_ tool: String, _ args: [String: Value], _ snapshot: ReminderReadSnapshot) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(reminderReadSource: ReminderScheduleFake([snapshot]))
        let raw = try await server.executeToolCall(name: tool, arguments: args)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], tool)
        return try XCTUnwrap((json["reminders"] as? [[String: Any]])?.first, tool)
    }

    func testReminderWithoutStartOrAlarmsReportsNullStartAndEmptyAlarms() async throws {
        for (tool, args) in tools {
            let value = try await item(tool, args, ReminderReadSnapshot(id: "plain", title: "R"))
            XCTAssertTrue(value["start"] is NSNull, tool)
            XCTAssertNil(value["start_date"], tool)
            XCTAssertNil(value["start_date_local"], tool)
            XCTAssertEqual((value["alarms"] as? [Any])?.count, 0, "alarms is [] rather than absent: \(tool)")
        }
    }

    /// "Same shape as `due`": identical components give identical values.
    func testStartUsesTheSameShapeAndStringsAsDue() async throws {
        let components = DateComponents(timeZone: taipei, year: 2026, month: 10, day: 9, hour: 9, minute: 30)
        let snapshot = ReminderReadSnapshot(id: "start", title: "R", dueDateComponents: components,
                                            startDateComponents: components)
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let start = try XCTUnwrap(value["start"] as? [String: Any], tool)
            let due = try XCTUnwrap(value["due"] as? [String: Any], tool)
            XCTAssertEqual(start as NSDictionary, due as NSDictionary, tool)
            XCTAssertEqual(start["date"] as? String, "2026-10-09", tool)
            XCTAssertEqual(start["time"] as? String, "09:30:00", tool)
            XCTAssertEqual(start["timezone"] as? String, "Asia/Taipei", tool)
            XCTAssertEqual(start["date_time"] as? String, "2026-10-09T01:30:00Z", tool)
            XCTAssertEqual(value["start_date"] as? String, "2026-10-09T01:30:00Z", tool)
            XCTAssertEqual(value["start_date"] as? String, value["due_date"] as? String, tool)
            XCTAssertEqual(value["start_date_local"] as? String, value["due_date_local"] as? String, tool)
        }
    }

    /// A date-only start renders as a date-only due does: no time, no instant, and
    /// the legacy strings fall on host-local midnight.
    func testDateOnlyStartMirrorsADateOnlyDue() async throws {
        let components = DateComponents(year: 2026, month: 10, day: 9)
        let snapshot = ReminderReadSnapshot(id: "date-only", title: "R", dueDateComponents: components,
                                            startDateComponents: components)
        let midnight = try XCTUnwrap(Calendar.current.date(from: components))
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let start = try XCTUnwrap(value["start"] as? [String: Any], tool)
            let due = try XCTUnwrap(value["due"] as? [String: Any], tool)
            XCTAssertEqual(start as NSDictionary, due as NSDictionary, tool)
            XCTAssertEqual(start["date"] as? String, "2026-10-09", tool)
            XCTAssertTrue(start["time"] is NSNull, tool)
            XCTAssertTrue(start["date_time"] is NSNull, tool)
            XCTAssertEqual(value["start_date"] as? String, ISO8601DateFormatter().string(from: midnight), tool)
            XCTAssertEqual(value["start_date_local"] as? String, "2026-10-09T00:00:00", tool)
            XCTAssertEqual(value["start_date"] as? String, value["due_date"] as? String, tool)
            XCTAssertEqual(value["start_date_local"] as? String, value["due_date_local"] as? String, tool)
        }
    }

    /// Pins today's output, not the wanted one (#252). A start that EventKit fills in
    /// carries `nanosecond = 0`; the renderer shared with `due` prints that as `.000`,
    /// so the same wall time reads `10:00:00.000` on `start` and `10:00:00` on `due`.
    /// A fix for #252 has to change this test on purpose.
    func testStartWithNanosecondZeroRendersMillisecondsWhereDueDoesNot() async throws {
        let start = DateComponents(timeZone: taipei, year: 2026, month: 10, day: 9,
                                   hour: 10, minute: 0, second: 0, nanosecond: 0)
        let due = DateComponents(timeZone: taipei, year: 2026, month: 10, day: 9, hour: 10, minute: 0)
        let snapshot = ReminderReadSnapshot(id: "nanos", title: "R", dueDateComponents: due,
                                            startDateComponents: start)
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let renderedStart = try XCTUnwrap(value["start"] as? [String: Any], tool)
            let renderedDue = try XCTUnwrap(value["due"] as? [String: Any], tool)
            XCTAssertEqual(renderedStart["time"] as? String, "10:00:00.000", tool)
            XCTAssertEqual(renderedStart["date_time"] as? String, "2026-10-09T02:00:00.000Z", tool)
            XCTAssertEqual(renderedDue["time"] as? String, "10:00:00", tool)
            XCTAssertEqual(renderedDue["date_time"] as? String, "2026-10-09T02:00:00Z", tool)
            // The legacy strings drop sub-seconds, so these two agree.
            XCTAssertEqual(value["start_date"] as? String, value["due_date"] as? String, tool)
        }
    }

    func testStartWithoutADueDateIsStillReported() async throws {
        let start = DateComponents(timeZone: taipei, year: 2026, month: 10, day: 11, hour: 9, minute: 30)
        let snapshot = ReminderReadSnapshot(id: "start-only", title: "R", startDateComponents: start)
        let instant = Date(timeIntervalSince1970: 1_791_682_200)   // 2026-10-11T01:30:00Z
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            XCTAssertTrue(value["due"] is NSNull, tool)
            XCTAssertEqual((value["start"] as? [String: Any])?["date"] as? String, "2026-10-11", tool)
            XCTAssertEqual(value["start_date"] as? String, "2026-10-11T01:30:00Z", tool)
            XCTAssertEqual(value["start_date_local"] as? String, hostLocal(instant), tool)
        }
    }

    /// A floating start (no time zone) has no instant of its own, as with `due`.
    func testFloatingStartReportsNullTimeZoneAndInstant() async throws {
        let start = DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 30)
        let snapshot = ReminderReadSnapshot(id: "floating", title: "R", startDateComponents: start)
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let rendered = try XCTUnwrap(value["start"] as? [String: Any], tool)
            XCTAssertEqual(rendered["time"] as? String, "09:30:00", tool)
            XCTAssertTrue(rendered["timezone"] is NSNull, tool)
            XCTAssertTrue(rendered["date_time"] is NSNull, tool)
        }
    }

    /// The snapshot is passed in unsorted: the output order is the documented one
    /// (earliest first) however the snapshot was built, not only via `init(from:)`.
    func testRelativeAlarmsReportMinutesBeforeTheDueDate() async throws {
        let snapshot = ReminderReadSnapshot(id: "relative", title: "R",
                                            alarms: [.relative(seconds: -900), .relative(seconds: 600),
                                                     .relative(seconds: -90), .relative(seconds: 0)])
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let alarms = try XCTUnwrap(value["alarms"] as? [[String: Any]], tool)
            XCTAssertEqual(alarms.map { $0["kind"] as? String }, Array(repeating: "relative", count: 4), tool)
            XCTAssertEqual(alarms.map { $0["minutes_before"] as? Double }, [15, 1.5, 0, -10], tool)
            XCTAssertEqual(Set(alarms.flatMap(\.keys)), ["kind", "minutes_before"], tool)
        }
    }

    /// JSON has no NaN or infinity; `formatJSON` refuses such a payload, so one bad
    /// alarm failed the whole call for every reminder in it. It is left out of `alarms`.
    func testNonFiniteRelativeOffsetIsLeftOutOfAlarms() async throws {
        let snapshot = ReminderReadSnapshot(id: "nan", title: "R",
                                            alarms: [.relative(seconds: .nan), .relative(seconds: -900),
                                                     .relative(seconds: .infinity), .relative(seconds: -.infinity)])
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let alarms = try XCTUnwrap(value["alarms"] as? [[String: Any]], tool)
            XCTAssertEqual(alarms.map { $0["minutes_before"] as? Double }, [15], tool)
        }
    }

    /// `-0 / 60` is `-0.0`, which JSON would print as `-0`.
    func testAlarmAtTheDueTimeIsNotPrintedAsNegativeZero() async throws {
        let server = try await CheICalMCPServer(reminderReadSource: ReminderScheduleFake(
            [ReminderReadSnapshot(id: "zero", title: "R", alarms: [.relative(seconds: 0)])]))
        for (tool, args) in tools {
            let raw = try await server.executeToolCall(name: tool, arguments: args)
            XCTAssertNotNil(raw.range(of: #""minutes_before"\s*:\s*0(?![.0-9])"#, options: .regularExpression), "\(tool): \(raw)")
            XCTAssertNil(raw.range(of: #""minutes_before"\s*:\s*-0"#, options: .regularExpression), "\(tool): \(raw)")
        }
    }

    func testAbsoluteAlarmReportsUTCAndLocalStrings() async throws {
        let absolute = Date(timeIntervalSince1970: 1_791_615_600)   // 2026-10-10T07:00:00Z
        let snapshot = ReminderReadSnapshot(id: "absolute", title: "R",
                                            alarms: [.relative(seconds: -900), .absolute(absolute)])
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            let alarms = try XCTUnwrap(value["alarms"] as? [[String: Any]], tool)
            XCTAssertEqual(alarms.count, 2, tool)
            XCTAssertEqual(alarms[0]["kind"] as? String, "absolute", tool)
            XCTAssertEqual(alarms[0]["absolute_date"] as? String, "2026-10-10T07:00:00Z", tool)
            XCTAssertEqual(alarms[0]["absolute_date_local"] as? String, hostLocal(absolute), tool)
            XCTAssertNil(alarms[0]["minutes_before"], tool)
            XCTAssertEqual(alarms[1]["kind"] as? String, "relative", tool)
        }
    }

    func testLocationTriggerIsUnchangedNextToAlarms() async throws {
        let trigger = ReminderReadSnapshot.LocationTrigger(title: "Office", latitude: 25.04, longitude: 121.61,
                                                           radius: 100, proximity: "enter")
        let snapshot = ReminderReadSnapshot(id: "geo", title: "R", locationTrigger: trigger, alarms: [])
        for (tool, args) in tools {
            let value = try await item(tool, args, snapshot)
            XCTAssertEqual((value["location_trigger"] as? [String: Any])?["title"] as? String, "Office", tool)
            XCTAssertEqual((value["alarms"] as? [Any])?.count, 0, tool)
        }
    }
}
