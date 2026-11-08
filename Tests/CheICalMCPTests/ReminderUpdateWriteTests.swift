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
        let reminder = EKReminder(eventStore: SharedTestStore.store)
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
            ReminderUpdateRequest(identifier: "r", due: .timed(date(10, 8, 10)), realignToDue: true), existingDue: nil))
        XCTAssertNoThrow(try ReminderUpdateWrite.checkRealign(
            ReminderUpdateRequest(identifier: "r"), existingDue: nil))
    }

    // MARK: - alarm read-back (PR #438 verify)

    private func timedReminder(alarms: [EKAlarm] = []) -> EKReminder {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = ReminderDateSync.timedDueComponents(for: date(10, 8, 9))
        alarms.forEach(reminder.addAlarm)
        return reminder
    }

    /// The date path tried the reload and it failed: nothing is confirmed, and it is not tried again.
    func testAFailedDateReloadReportsNoAlarms() throws {
        let reminder = timedReminder()
        let request = ReminderUpdateRequest(identifier: "r", due: .timed(date(10, 9, 9)), alarmOffsets: [15])
        var reloads = 0
        let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {},
                                                   reload: { reloads += 1; return false }, rollback: {})
        XCTAssertEqual(report?.aligned, false)
        XCTAssertEqual(report?.reread, false)
        let alarms = ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: report,
                                                       reload: { reloads += 1; return true })
        XCTAssertEqual(alarms, .init(stored: nil, listShowsAlarmTime: false))
        XCTAssertEqual(reloads, 1, "a report of a failed reload is not overruled by another try")
    }

    func testAConfirmedDateReloadReportsTheAlarmsWithoutReloadingAgain() throws {
        let reminder = timedReminder()
        let request = ReminderUpdateRequest(identifier: "r", due: .timed(date(10, 9, 9)), alarmOffsets: [15])
        let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {}, reload: { true }, rollback: {})
        XCTAssertEqual(report?.reread, true)
        let alarms = ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: report, reload: {
            XCTFail("already re-read")
            return false
        })
        XCTAssertEqual(alarms, .init(stored: [15], listShowsAlarmTime: true))
    }

    /// A due change on a reminder that keeps its alarm: the note follows the reload as well.
    func testADueOnlyUpdateJudgesTheListOnlyAfterTheReload() throws {
        let request = ReminderUpdateRequest(identifier: "r", due: .timed(date(10, 9, 9)))
        for (reloaded, shows) in [(true, true), (false, false)] {
            let reminder = timedReminder(alarms: [EKAlarm(relativeOffset: -900)])
            let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {}, reload: { reloaded }, rollback: {})
            let alarms = ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: report, reload: { true })
            XCTAssertEqual(alarms, .init(stored: nil, listShowsAlarmTime: shows), "reloaded: \(reloaded)")
        }
    }

    /// The leftover note counts alarms off the object, so not after a reload that failed.
    func testTheLeftoverNoteNeedsTheReload() throws {
        let request = ReminderUpdateRequest(identifier: "r", due: .day(DateComponents(year: 2026, month: 10, day: 19)))
        for (reloaded, expected) in [(true, ReminderRelativeAlarms.leftoverDateOnlyNote(1)), (false, nil)] {
            let reminder = timedReminder(alarms: [EKAlarm(relativeOffset: -900)])
            let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {}, reload: { reloaded }, rollback: {})
            XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(saved: reminder, request: request, dateSync: report), expected, "reloaded: \(reloaded)")
        }
        // `clear_due_date` has no reload to fail: the count stays, from the object, as documented.
        let clear = ReminderUpdateRequest(identifier: "r", clearDueDate: true)
        let reminder = timedReminder(alarms: [EKAlarm(relativeOffset: -900)])
        let report = try ReminderUpdateWrite.apply(clear, to: reminder, calendar: nil, save: {}, reload: { false }, rollback: {})
        XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(saved: reminder, request: clear, dateSync: report), ReminderRelativeAlarms.leftoverNoDueNote(1))
    }

    /// `clear_due_date` writes no due, so the date path does not reload; `[]` is still read back.
    func testClearingTheDueWithAnEmptyListIsReloadedHere() throws {
        let request = ReminderUpdateRequest(identifier: "r", clearDueDate: true, alarmOffsets: [])
        for (reloaded, stored) in [(true, [] as [Double]?), (false, nil)] {
            let reminder = timedReminder(alarms: [EKAlarm(relativeOffset: -900)])
            let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {}, reload: {
                XCTFail("the date path has nothing to re-read")
                return false
            }, rollback: {})
            XCTAssertNotNil(report, "a date sync that did not reload")
            XCTAssertNil(report?.reread)
            var reloads = 0
            let alarms = ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: report,
                                                           reload: { reloads += 1; return reloaded })
            XCTAssertEqual(alarms, .init(stored: stored, listShowsAlarmTime: false))
            XCTAssertEqual(reloads, 1)
        }
    }

    func testAnOffsetsOnlyUpdateReloadsHere() throws {
        let request = ReminderUpdateRequest(identifier: "r", alarmOffsets: [15])
        for (reloaded, expected) in [(true, ReminderUpdateWrite.AlarmReadBack(stored: [15], listShowsAlarmTime: true)),
                                     (false, .init(stored: nil, listShowsAlarmTime: false))] {
            let reminder = timedReminder()
            let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {}, reload: { true }, rollback: {})
            XCTAssertNil(report)
            XCTAssertEqual(ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: report, reload: { reloaded }), expected)
        }
    }

    /// The gate of the note: a reminder with an alarm off the due time, and a call that touches
    /// neither the alarms nor the due. No reload, nothing reported.
    func testATitleChangeNeitherReloadsNorReports() throws {
        for request in [ReminderUpdateRequest(identifier: "r", title: "Renamed"), ReminderUpdateRequest(identifier: "r", clearDueDate: true)] {
            let reminder = timedReminder(alarms: [EKAlarm(relativeOffset: -900)])
            let alarms = ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: nil, reload: {
                XCTFail("no reason to reload")
                return false
            })
            XCTAssertEqual(alarms, .init(stored: nil, listShowsAlarmTime: false))
        }
    }

    /// `[]` removes the relative alarms; an absolute alarm that stays can still set the list.
    func testAnEmptyListWithAnEarlierAbsoluteAlarmStillReportsTheList() throws {
        let reminder = timedReminder(alarms: [EKAlarm(absoluteDate: date(10, 8, 8))])
        let request = ReminderUpdateRequest(identifier: "r", alarmOffsets: [])
        let report = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil, save: {}, reload: { true }, rollback: {})
        XCTAssertEqual(ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: report, reload: { true }),
                       .init(stored: [], listShowsAlarmTime: true))
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

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", due: .timed(date(10, 8, 10))), to: reminder,
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
        let store = SharedTestStore.store
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
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.title = "Old"
        var saves = 0

        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", title: "New", realignToDue: true), to: reminder, calendar: nil,
            save: { saves += 1 }, reload: { true }, rollback: {}))

        XCTAssertEqual(reminder.title, "Old")
        XCTAssertEqual(saves, 0)
    }

    /// #486: a location trigger with clear_location_trigger is refused inside `apply` too, before
    /// anything is written; the clear used to win and the trigger was dropped.
    func testApplyRefusesALocationTriggerWithClearLocationTriggerBeforeWriting() {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.title = "Old"
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Home")
        reminder.addAlarm(location)
        var saves = 0
        let trigger = LocationTriggerInput(title: "Office", latitude: 25.04, longitude: 121.61, radius: 100, proximity: .enter)

        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", title: "New", locationTrigger: trigger, clearLocationTrigger: true),
            to: reminder, calendar: nil, save: { saves += 1 }, reload: { true }, rollback: {})) { error in
            XCTAssertEqual("\(error)", "\(ToolError.invalidParameter(ReminderUpdateWrite.locationTriggerBothMessage))")
        }

        XCTAssertEqual(reminder.title, "Old")
        XCTAssertEqual(reminder.alarms?.compactMap(\.structuredLocation?.title), ["Home"])
        XCTAssertEqual(saves, 0)
    }

    func testAReminderThatCannotBeReadBackAfterTheSaveIsNotAligned() throws {
        let reminder = divergedReminder()

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", realignToDue: true), to: reminder,
                                                   calendar: nil, save: {}, reload: { false }, rollback: {})

        XCTAssertEqual(report?.aligned, false)
    }

    // MARK: - PR #256 verify round 3

    /// The seam refuses `realign_to_due` with `clear_due_date` as the server layer does.
    func testApplyRefusesRealignWithClearDueDateBeforeWriting() {
        let reminder = divergedReminder()
        var saves = 0

        XCTAssertThrowsError(try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", clearDueDate: true, realignToDue: true), to: reminder, calendar: nil,
            save: { saves += 1 }, reload: { true }, rollback: {})) { error in
            XCTAssertTrue("\(error)".contains("Cannot specify both realign_to_due and clear_due_date"), "\(error)")
        }

        XCTAssertNotNil(reminder.dueDateComponents)
        XCTAssertEqual(saves, 0)
    }

    /// The reminder an update starts from, and the one `getReminder` reads notes and tags from, is
    /// re-read first (`refresh()`), so an edit made in Reminders.app is the base; `false` means it
    /// is gone, the #236 convention.
    func testFreshReminderReReadsBeforeHandingTheReminderOut() throws {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        var refreshed: [EKReminder] = []

        let fresh = try ReminderUpdateWrite.freshReminder(identifier: "r", lookup: { _ in reminder },
                                                         refresh: { refreshed.append($0); return true })

        XCTAssertTrue(fresh === reminder)
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertTrue(refreshed.first === reminder)
    }

    func testFreshReminderTreatsAFailedReReadAsNotFound() {
        let reminder = EKReminder(eventStore: SharedTestStore.store)

        XCTAssertThrowsError(try ReminderUpdateWrite.freshReminder(identifier: "gone", lookup: { _ in reminder },
                                                                   refresh: { _ in false })) { error in
            XCTAssertTrue("\(error)".contains("gone"), "\(error)")
        }
        XCTAssertThrowsError(try ReminderUpdateWrite.freshReminder(identifier: "missing", lookup: { _ in nil },
                                                                   refresh: { _ in XCTFail("nothing to refresh"); return true }))
    }

    // MARK: - date-only due (#267)

    private func day(_ m: Int, _ d: Int) -> DateComponents {
        DateComponents(year: 2026, month: m, day: d)
    }

    /// As Reminders.app makes a timed reminder: a start and an absolute alarm at the due.
    private func timedReminder() -> EKReminder {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = components(date(10, 18, 17))
        reminder.startDateComponents = components(date(10, 18, 17))
        reminder.addAlarm(EKAlarm(absoluteDate: date(10, 18, 17)))
        return reminder
    }

    // A bare date makes the reminder date-only: no time, no absolute alarm, one save (no #237
    // fallback, which is for timed dues), judged on the reminder read back.
    func testADayMakesTheReminderDateOnlyAndSavesOnce() throws {
        let reminder = timedReminder()
        var saves = 0
        var reloads = 0

        let report = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", due: .day(day(10, 19))), to: reminder,
                                                   calendar: nil, save: { saves += 1 }, reload: { reloads += 1; return true },
                                                   rollback: {})

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 1, aligned: true))
        XCTAssertEqual(reminder.dueDateComponents?.day, 19)
        XCTAssertNil(reminder.dueDateComponents?.hour)
        XCTAssertEqual(absoluteDates(reminder), [])
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(reloads, 1)
    }

    // realign_to_due has nothing to add to a bare date: the absolute alarms are removed either way.
    func testADayWithRealignToDueGivesTheSameResult() throws {
        let plain = timedReminder()
        let realigned = timedReminder()

        let plainReport = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", due: .day(day(10, 19))), to: plain,
                                                        calendar: nil, save: {}, reload: { true }, rollback: {})
        let realignedReport = try ReminderUpdateWrite.apply(
            ReminderUpdateRequest(identifier: "r", due: .day(day(10, 19)), realignToDue: true), to: realigned,
            calendar: nil, save: {}, reload: { true }, rollback: {})

        XCTAssertEqual(realignedReport, plainReport)
        XCTAssertNil(realigned.dueDateComponents?.hour)
        XCTAssertEqual(absoluteDates(realigned), [])
    }

    func testRealignWithADayAndNoExistingDueIsAccepted() {
        XCTAssertNoThrow(try ReminderUpdateWrite.checkRealign(
            ReminderUpdateRequest(identifier: "r", due: .day(day(10, 19)), realignToDue: true), existingDue: nil))
    }
}
