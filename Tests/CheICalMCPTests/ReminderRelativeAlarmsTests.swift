import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #333: relative alarms on reminders. `alarms_minutes_offsets` (positive = minutes before the due
/// date) replaces or clears only the relative alarms; absolute-date alarms (what Reminders.app
/// shows as the date, #227) and the location alarm (#229) stay. A relative alarm needs a timed due
/// date: without one it never fires, and on a date-only reminder its firing was not measured on a
/// device (step 0, 2026-11-05), so both are refused. In-memory EventKit objects only.
final class ReminderRelativeAlarmsTests: XCTestCase {
    private let absolute = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminder() -> EKReminder { EKReminder(eventStore: SharedTestStore.store) }

    private func locationAlarm() -> EKAlarm {
        let structured = EKStructuredLocation(title: "Somewhere")
        structured.geoLocation = CLLocation(latitude: 25.04, longitude: 121.56)
        let alarm = EKAlarm()
        alarm.structuredLocation = structured
        alarm.proximity = .enter
        return alarm
    }

    func testReplaceWritesMinutesBeforeAsANegativeOffset() {
        let item = reminder()
        ReminderRelativeAlarms.replace(on: item, with: [15, 60])
        XCTAssertEqual(Set(item.alarms?.map(\.relativeOffset) ?? []), [-900, -3600])
        XCTAssertEqual(ReminderRelativeAlarms.storedMinutesBefore(item), [60, 15], "earliest first, as the read side")
    }

    func testReplaceKeepsAbsoluteAndLocationAlarms() {
        let item = reminder()
        item.addAlarm(EKAlarm(absoluteDate: absolute))
        item.addAlarm(locationAlarm())
        item.addAlarm(EKAlarm(relativeOffset: -600))
        ReminderRelativeAlarms.replace(on: item, with: [30])
        let alarms = item.alarms ?? []
        XCTAssertEqual(alarms.count, 3)
        XCTAssertEqual(alarms.compactMap(\.absoluteDate), [absolute])
        XCTAssertEqual(alarms.filter { $0.structuredLocation != nil }.count, 1)
        XCTAssertEqual(ReminderRelativeAlarms.storedMinutesBefore(item), [30], "the old relative alarm is replaced")
    }

    func testAnEmptyListClearsOnlyTheRelativeAlarms() {
        let item = reminder()
        item.addAlarm(EKAlarm(absoluteDate: absolute))
        item.addAlarm(locationAlarm())
        item.addAlarm(EKAlarm(relativeOffset: -600))
        item.addAlarm(EKAlarm(relativeOffset: -60))
        ReminderRelativeAlarms.replace(on: item, with: [])
        XCTAssertEqual(item.alarms?.count, 2)
        XCTAssertEqual(ReminderRelativeAlarms.storedMinutesBefore(item), [])
    }

    /// A negative value means after the due date; a value too large for `Int * 60` does not trap.
    func testNegativeAndHugeOffsets() {
        let item = reminder()
        ReminderRelativeAlarms.replace(on: item, with: [-10, Int.max])
        XCTAssertEqual(item.alarms?.count, 2)
        XCTAssertTrue(item.alarms?.contains { $0.relativeOffset == 600 } ?? false)
    }

    func testTheDueStateAfterTheCall() {
        let timed = DateComponents(year: 2026, month: 12, day: 10, hour: 9, minute: 0)
        let day = DateComponents(year: 2026, month: 12, day: 10)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(of: nil), .none)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(of: day), .dateOnly)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(of: timed), .timed)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(requested: nil, clearDue: true, existing: timed), .none)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(requested: .day(day), clearDue: false, existing: timed), .dateOnly)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(requested: .timed(absolute), clearDue: false, existing: nil), .timed)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(requested: nil, clearDue: false, existing: day), .dateOnly)
        XCTAssertEqual(ReminderRelativeAlarms.dueState(requested: nil, clearDue: false, existing: nil), .none)
    }

    func testTheCheckRefusesAnAlarmThatCannotFireOrWasNotMeasured() {
        XCTAssertNoThrow(try ReminderRelativeAlarms.check(nil, due: .none))
        XCTAssertNoThrow(try ReminderRelativeAlarms.check([15], due: .timed))
        for due in [ReminderRelativeAlarms.DueState.none, .dateOnly, .timed] {
            XCTAssertNoThrow(try ReminderRelativeAlarms.check([], due: due), "clearing is always allowed")
        }
        XCTAssertThrowsError(try ReminderRelativeAlarms.check([15], due: .none)) { error in
            XCTAssertEqual((error as? ToolError).map { "\($0)" }, "\(ToolError.invalidParameter(ReminderRelativeAlarms.noDueMessage))")
        }
        XCTAssertThrowsError(try ReminderRelativeAlarms.check([240], due: .dateOnly)) { error in
            XCTAssertEqual((error as? ToolError).map { "\($0)" }, "\(ToolError.invalidParameter(ReminderRelativeAlarms.dateOnlyMessage))")
        }
        XCTAssertTrue(ReminderRelativeAlarms.noDueMessage.contains("due_date with a time"))
        XCTAssertTrue(ReminderRelativeAlarms.dateOnlyMessage.contains("date-only"))
        XCTAssertTrue(ReminderRelativeAlarms.dateOnlyMessage.contains("Nothing was written"))
    }

    func testDiffersComparesAsAMultiset() {
        XCTAssertFalse(ReminderRelativeAlarms.differs(requested: [15, 60], stored: [60, 15]))
        XCTAssertTrue(ReminderRelativeAlarms.differs(requested: [15, 15], stored: [15]))
        XCTAssertTrue(ReminderRelativeAlarms.differs(requested: [15], stored: [16]))
        XCTAssertFalse(ReminderRelativeAlarms.differs(requested: [], stored: []))
    }

    /// An alarm-only update and its undo: `apply` replaces the relative alarms and keeps the
    /// location alarm; the undo restores the recorded alarms (`AlarmSnapshot.restore`, as
    /// update-undo does), location alarm included.
    func testAnAlarmOnlyUpdateKeepsTheLocationAlarmAndItsUndoRestoresTheOldSet() throws {
        let item = reminder()
        item.dueDateComponents = DateComponents(year: 2026, month: 12, day: 10, hour: 9, minute: 0)
        item.addAlarm(locationAlarm())
        item.addAlarm(EKAlarm(relativeOffset: -600))
        let before = ReminderSnapshot(from: item)
        _ = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", alarmOffsets: [15]), to: item, calendar: nil,
                                          save: {}, reload: { true }, rollback: {})
        XCTAssertEqual(ReminderRelativeAlarms.storedMinutesBefore(item), [15])
        XCTAssertEqual(item.alarms?.filter { $0.structuredLocation != nil }.count, 1)
        _ = AlarmSnapshot.restore(before.alarms, to: item)
        XCTAssertEqual(ReminderRelativeAlarms.storedMinutesBefore(item), [10])
        XCTAssertEqual(item.alarms?.filter { $0.structuredLocation != nil }.count, 1)
    }

    /// The check runs before the first write: a refused update leaves the reminder untouched.
    func testApplyRefusesADateOnlyAlarmBeforeWriting() {
        let item = reminder()
        item.title = "Old"
        item.dueDateComponents = DateComponents(year: 2026, month: 12, day: 10)
        var saved = false
        XCTAssertThrowsError(try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", title: "New", alarmOffsets: [240]),
                                                           to: item, calendar: nil, save: { saved = true }, reload: { true }, rollback: {}))
        XCTAssertEqual(item.title, "Old")
        XCTAssertFalse(saved)
        XCTAssertEqual(item.alarms?.count ?? 0, 0)
    }

    /// Making a reminder date-only in the same call as adding an alarm is refused too.
    func testApplyJudgesTheDueTheReminderWillHave() {
        let item = reminder()
        item.dueDateComponents = DateComponents(year: 2026, month: 12, day: 10, hour: 9, minute: 0)
        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", due: .day(DateComponents(year: 2026, month: 12, day: 11)), alarmOffsets: [15]),
            to: item, calendar: nil, save: {}, reload: { true }, rollback: {}))
        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", clearDueDate: true, alarmOffsets: [15]),
            to: item, calendar: nil, save: {}, reload: { true }, rollback: {}))
    }

    /// One parser for the event and reminder tools: absent or null is nil, a present non-array is
    /// refused instead of ignored.
    func testTheSharedParser() throws {
        XCTAssertNil(try InputValidation.parseAlarmOffsets([:]))
        XCTAssertNil(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .null]))
        XCTAssertEqual(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .array([])]), [])
        XCTAssertEqual(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .array([.int(15), .int(-5)])]), [15, -5])
        XCTAssertThrowsError(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .string("15")]))
        XCTAssertThrowsError(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .object([:])]))
        XCTAssertThrowsError(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .array([.double(1.5)])]))
    }
}
