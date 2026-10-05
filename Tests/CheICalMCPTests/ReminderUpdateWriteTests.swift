import EventKit
import XCTest
@testable import CheICalMCP

/// PR #256 verify round 1: the writes `update_reminder` makes to one loaded reminder, driven
/// through the closure seam with in-memory EventKit objects (no store, no TCC).
final class ReminderUpdateWriteTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func date(_ m: Int, _ d: Int, _ h: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = taipei
        return cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
    }

    private func components(_ date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = taipei
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.timeZone = taipei
        return c
    }

    private func absoluteDates(_ reminder: EKReminder) -> [Date] {
        (reminder.alarms ?? []).compactMap(\.absoluteDate).sorted()
    }

    /// As v1.17/v1.18 left it: due moved to Oct 8, start and alarm still on Oct 4.
    private func divergedReminder() -> EKReminder {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = components(date(10, 8, 10))
        reminder.startDateComponents = components(date(10, 4, 10))
        reminder.addAlarm(EKAlarm(absoluteDate: date(10, 4, 10)))
        return reminder
    }

    // MARK: - realign_to_due precondition

    func testRealignWithNoDueAnywhereIsRefused() {
        XCTAssertThrowsError(try ReminderUpdateWrite.checkRealign(
            ReminderUpdateRequest(identifier: "r", realignToDue: true), existingDue: nil)) { error in
            XCTAssertTrue("\(error)".contains("realign_to_due needs a due date"), "\(error)")
        }
    }

    func testRealignWithTheRemindersDueOrANewDueIsAccepted() {
        XCTAssertNoThrow(try ReminderUpdateWrite.checkRealign(
            ReminderUpdateRequest(identifier: "r", realignToDue: true), existingDue: DateComponents(year: 2026, month: 10, day: 8)))
        XCTAssertNoThrow(try ReminderUpdateWrite.checkRealign(
            ReminderUpdateRequest(identifier: "r", dueDate: date(10, 8, 10), realignToDue: true), existingDue: nil))
        XCTAssertNoThrow(try ReminderUpdateWrite.checkRealign(
            ReminderUpdateRequest(identifier: "r"), existingDue: nil))
    }

    // MARK: - plumbing

    func testRealignToDueAloneRealignsADivergedReminder() throws {
        let reminder = divergedReminder()

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", realignToDue: true), to: reminder,
                                                   calendar: nil, save: {}, reload: { true }, rollback: {})

        XCTAssertEqual(report?.aligned, true)
        XCTAssertEqual(absoluteDates(reminder), [date(10, 8, 10)])
    }

    func testTheSameDueWithoutRealignToDueMovesNothing() throws {
        let reminder = divergedReminder()

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", dueDate: date(10, 8, 10)), to: reminder,
                                                   calendar: nil, save: {}, reload: { true }, rollback: {})

        XCTAssertEqual(report?.aligned, false)
        XCTAssertEqual(absoluteDates(reminder), [date(10, 4, 10)])
    }

    func testAnUpdateThatLeavesTheDueAloneHasNoDateSync() throws {
        let reminder = divergedReminder()
        var saves = 0

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", title: "Renamed"), to: reminder,
                                                   calendar: nil, save: { saves += 1 }, reload: { true }, rollback: {})

        XCTAssertNil(report)
        XCTAssertEqual(reminder.title, "Renamed")
        XCTAssertEqual(saves, 1)
    }

    func testTheCalendarResolvedBeforehandIsApplied() throws {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        let list = EKCalendar(for: .reminder, eventStore: store)

        _ = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r"), to: reminder, calendar: list,
                                          save: {}, reload: { true }, rollback: {})

        XCTAssertTrue(reminder.calendar === list)
    }

    // MARK: - save, read-back, rollback

    /// Verify 4: a failed save discards the unsaved changes; the reminder object outlives the call
    /// in the server's store, and a later save would otherwise write them.
    func testAFailedSaveRollsBackAndRethrows() {
        let reminder = divergedReminder()
        var rolledBack = false

        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", realignToDue: true), to: reminder, calendar: nil,
            save: { throw NSError(domain: "test", code: 1) },
            reload: { XCTFail("nothing to read back after a failed save"); return true },
            rollback: { rolledBack = true }))

        XCTAssertTrue(rolledBack)
    }

    /// Verify 1: the date sync is judged on the reminder read back after the save.
    func testTheDateSyncIsJudgedOnTheReminderReadBackAfterTheSave() throws {
        let reminder = divergedReminder()
        var events: [String] = []

        let report = try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", realignToDue: true), to: reminder, calendar: nil,
            save: { events.append("save") },
            reload: { events.append("reload"); reminder.startDateComponents = self.components(self.date(10, 4, 10)); return true },
            rollback: { XCTFail("nothing to roll back") })

        XCTAssertEqual(events, ["save", "reload"])
        XCTAssertEqual(report?.aligned, false)
    }

    // MARK: - PR #256 verify round 2

    /// The no-due refusal holds inside `apply` as well, before anything is written.
    func testApplyRefusesRealignWithNoDueBeforeWriting() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "Old"
        var saves = 0

        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", title: "New", realignToDue: true), to: reminder, calendar: nil,
            save: { saves += 1 }, reload: { true }, rollback: {}))

        XCTAssertEqual(reminder.title, "Old")
        XCTAssertEqual(saves, 0)
    }

    func testAReminderThatCannotBeReadBackAfterTheSaveIsNotAligned() throws {
        let reminder = divergedReminder()

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", realignToDue: true), to: reminder,
                                                   calendar: nil, save: {}, reload: { false }, rollback: {})

        XCTAssertEqual(report?.aligned, false)
    }
}
