import EventKit
import XCTest
@testable import CheICalMCP

/// #240: the `alarms` list is built by one helper for reminders (#231) and events, so the keys,
/// the sign of `minutes_before`, the order and the non-finite filter cannot drift between them.
final class AlarmReadOutputTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_800_000_000)
    private let late = Date(timeIntervalSince1970: 1_800_086_400)

    private func list(_ alarms: [ReminderReadSnapshot.Alarm]) -> [[String: Any]] {
        AlarmReadOutput.dictionaries(alarms, absolute: { "utc:\($0.timeIntervalSince1970)" },
                                     absoluteLocal: { "local:\($0.timeIntervalSince1970)" })
    }

    /// EventKit stores "15 minutes before" as `relativeOffset` -900; the output says 15.
    func testARelativeAlarmReadsAsMinutesBefore() {
        XCTAssertEqual(list([.relative(seconds: -900)]).first?["minutes_before"] as? Double, 15)
        XCTAssertEqual(list([.relative(seconds: -900)]).first?["kind"] as? String, "relative")
        XCTAssertEqual(list([.relative(seconds: 600)]).first?["minutes_before"] as? Double, -10, "after the start is negative")
        let zero = list([.relative(seconds: 0)]).first?["minutes_before"] as? Double
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero?.sign, .plus, "-0 is written as 0")
        XCTAssertEqual(Set(list([.relative(seconds: -900)]).first?.keys.map { $0 } ?? []), ["kind", "minutes_before"])
    }

    func testAnAbsoluteAlarmUsesBothFormatters() throws {
        let item = try XCTUnwrap(list([.absolute(early)]).first)
        XCTAssertEqual(item["kind"] as? String, "absolute")
        XCTAssertEqual(item["absolute_date"] as? String, "utc:\(early.timeIntervalSince1970)")
        XCTAssertEqual(item["absolute_date_local"] as? String, "local:\(early.timeIntervalSince1970)")
        XCTAssertEqual(Set(item.keys), ["kind", "absolute_date", "absolute_date_local"])
    }

    /// Absolute alarms by date first, then relative alarms earliest first; a non-finite offset is
    /// left out (JSON cannot encode it).
    func testTheOrderAndTheNonFiniteFilter() {
        let output = list([.relative(seconds: -60), .absolute(late), .relative(seconds: .infinity),
                           .absolute(early), .relative(seconds: -900), .relative(seconds: .nan)])
        XCTAssertEqual(output.map { $0["kind"] as? String }, ["absolute", "absolute", "relative", "relative"])
        XCTAssertEqual(output.compactMap { $0["absolute_date"] as? String },
                       ["utc:\(early.timeIntervalSince1970)", "utc:\(late.timeIntervalSince1970)"])
        XCTAssertEqual(output.compactMap { $0["minutes_before"] as? Double }, [15, 1])
    }

    /// A location alarm reads back with `absoluteDate` nil and `relativeOffset` 0; it is set aside
    /// before the absolute / relative split, so it never shows as a 0-minute alarm.
    func testLocationAlarmsAreSetAside() {
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Somewhere")
        location.proximity = .enter
        let alarms = AlarmReadOutput.timeBased([EKAlarm(relativeOffset: -900), location, EKAlarm(absoluteDate: early)])
        XCTAssertEqual(Set(alarms.map { "\($0)" }), Set([ReminderReadSnapshot.Alarm.relative(seconds: -900), .absolute(early)].map { "\($0)" }))
        XCTAssertEqual(alarms.count, 2)
        XCTAssertEqual(AlarmReadOutput.timeBased(nil), [])
    }

    /// An `EKEvent` hands its own alarms to the formatter through the same mapping.
    func testAnEventsAlarmsFragmentUsesTheSharedMapping() {
        let event = EKEvent(eventStore: SharedTestStore.store)
        event.addAlarm(EKAlarm(relativeOffset: -1800))
        event.addAlarm(EKAlarm(absoluteDate: early))
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Somewhere")
        event.addAlarm(location)
        XCTAssertEqual(ReminderReadSnapshot.Alarm.listed(event.alarmsFragment), [.absolute(early), .relative(seconds: -1800)])
    }

    /// The reminder side reads through the helper too (its output is pinned by the #231 tests).
    func testTheReminderSideUsesTheHelper() throws {
        let read = try String(contentsOf: SourceScan.sourcesDirectory().appendingPathComponent("ReminderReadSource.swift"), encoding: .utf8)
        XCTAssertTrue(read.contains("AlarmReadOutput.timeBased(reminder.alarms)"))
        let server = try String(contentsOf: SourceScan.sourcesDirectory().appendingPathComponent("Server.swift"), encoding: .utf8)
        let body = try XCTUnwrap(SourceScan.body(of: "private func reminderScheduleFields(", in: server))
        XCTAssertTrue(body.contains("AlarmReadOutput.dictionaries("), body)
        XCTAssertFalse(body.contains("minutes_before"), "the mapping lives in one place")
    }
}
