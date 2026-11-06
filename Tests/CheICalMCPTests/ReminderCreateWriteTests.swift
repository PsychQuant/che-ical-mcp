import EventKit
import XCTest
@testable import CheICalMCP

/// #308: a timed `create_reminder` (and each timed row of `create_reminders_batch`) is read back
/// after its save and returns `date_sync`, judged as `update_reminder` judges a timed write
/// (`ReminderDateSync.confirmSaved`, with the #237 fallback). `ReminderCreateWrite` is the
/// closure seam (#182): the store's save, re-read and rollback are passed in, so the read-back is
/// tested on in-memory reminders.
final class ReminderCreateWriteTests: XCTestCase {
    /// Not the host zone, so a zone taken from `.current` cannot pass for the written one.
    private let newYork = TimeZone(identifier: "America/New_York")!
    private var store: EKEventStore { SharedTestStore.store }

    private func newReminder() -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        return reminder
    }

    private func nineInNewYork() -> DateComponents {
        DateComponents(timeZone: newYork, year: 2026, month: 11, day: 20, hour: 9, minute: 0)
    }

    /// What a store that dropped the zone hands back: the same wall clock, floating.
    private func dropZone(_ reminder: EKReminder) {
        guard var due = reminder.dueDateComponents else { return }
        due.timeZone = nil
        due.calendar = nil
        reminder.timeZone = nil
        reminder.dueDateComponents = due
    }

    // MARK: - The timed write

    /// The write path is unchanged (a plain assignment of the zoned components, #134); what is new
    /// is the report the read-back judges.
    func testTheTimedWriteKeepsItsPathAndReturnsTheReportToJudge() {
        let reminder = newReminder()
        let components = nineInNewYork()

        let report = ReminderCreateWrite.writeTimedDue(reminder, components: components)

        XCTAssertEqual(reminder.dueDateComponents?.hour, 9)
        XCTAssertEqual(reminder.dueDateComponents?.timeZone, newYork)
        XCTAssertEqual(report.writtenDue, components)
        XCTAssertEqual(report.absoluteAlarmsShifted, 0)
        XCTAssertEqual(report.absoluteAlarmsRemoved, 0)
        // EventKit gives a reminder without a start one equal to a due written to it (#235).
        XCTAssertEqual(report.startDate, reminder.startDateComponents == nil ? .absent : .set)
        XCTAssertEqual(report.aligned, true)
    }

    // MARK: - The read-back

    func testATimedCreateThatReadsBackAsWrittenIsAligned() throws {
        let reminder = newReminder()
        let report = ReminderCreateWrite.writeTimedDue(reminder, components: nineInNewYork())
        var reloads = 0

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: [],
            save: { XCTFail("no second save") }, reload: { reloads += 1; return true },
            rollback: { XCTFail("nothing to roll back") }, log: { XCTFail("no fallback: \($0)") }))

        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(confirmed.aligned, true)
    }

    /// The #237 fallback runs on a new reminder too: the saved due lost its zone, so it is written
    /// around the start and saved a second time, and the log names `create_reminder`.
    func testATimedCreateWhoseDueLostItsZoneRunsTheFallback() throws {
        let reminder = newReminder()
        let report = ReminderCreateWrite.writeTimedDue(reminder, components: nineInNewYork())
        var saves = 0
        var reloads = 0
        var logged: [String] = []

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: [],
            save: { saves += 1 },
            reload: { reloads += 1; if reloads == 1 { self.dropZone(reminder) }; return true },
            rollback: { XCTFail("nothing to roll back") }, log: { logged.append($0) }))

        XCTAssertEqual(saves, 1, "the fallback is saved")
        XCTAssertEqual(reloads, 2, "and read back again")
        XCTAssertEqual(reminder.dueDateComponents?.timeZone, newYork)
        XCTAssertEqual(confirmed.aligned, true)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.allSatisfy { $0.hasPrefix("create_reminder: ") }, "\(logged)")
    }

    /// A failed second save is rolled back and reported, not thrown: the create itself is saved
    /// and recorded for undo.
    func testAFailedFallbackSaveIsRolledBackAndReportedNotThrown() throws {
        let reminder = newReminder()
        let report = ReminderCreateWrite.writeTimedDue(reminder, components: nineInNewYork())
        var rolledBack = false
        var logged: [String] = []

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: [],
            save: { throw NSError(domain: "test", code: 1) },
            reload: { self.dropZone(reminder); return true },
            rollback: { rolledBack = true }, log: { logged.append($0) }))

        XCTAssertTrue(rolledBack)
        XCTAssertEqual(confirmed.aligned, false)
        XCTAssertEqual(logged.count, 2)
        XCTAssertTrue(logged.allSatisfy { $0.hasPrefix("create_reminder: ") }, "\(logged)")
    }

    func testACreateThatCannotBeReReadIsNotAligned() throws {
        let reminder = newReminder()
        let report = ReminderCreateWrite.writeTimedDue(reminder, components: nineInNewYork())

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: [],
            save: { XCTFail("nothing written on state that was not re-read") }, reload: { false },
            rollback: {}, log: { _ in }))

        XCTAssertEqual(confirmed.aligned, false)
    }

    /// The date-only create (#301) goes through the same read-back and never saves again.
    func testADateOnlyCreateIsReadBackWithoutASecondSave() throws {
        let reminder = newReminder()
        let report = ReminderDateSync.setDueDay(reminder, to: DateComponents(year: 2026, month: 11, day: 20))

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: [],
            save: { XCTFail("a date-only write never runs the fallback") }, reload: { true },
            rollback: { XCTFail("nothing to roll back") }, log: { XCTFail("\($0)") }))

        XCTAssertEqual(confirmed.aligned, true)
    }

    /// Verify round 1: when the first save threw and a new store found the reminder with fields
    /// held differently (`store_differs` non-empty), the fallback is not run: no second save of an
    /// object whose first save threw (#261), nothing written, and the read-back judged as it is.
    func testAThrewButCommittedCreateWithDifferingFieldsIsNotSavedAgain() throws {
        let reminder = newReminder()
        let report = ReminderCreateWrite.writeTimedDue(reminder, components: nineInNewYork())
        var logged: [String] = []

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: ["due time zone"],
            save: { XCTFail("no second save after a first save that threw") },
            reload: { self.dropZone(reminder); return true },
            rollback: { XCTFail("nothing written, nothing to roll back") }, log: { logged.append($0) }))

        XCTAssertEqual(confirmed.aligned, false)
        XCTAssertNil(reminder.dueDateComponents?.timeZone, "the read-back is left as it is")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.allSatisfy { $0.hasPrefix("create_reminder: ") && $0.contains("not written again") }, "\(logged)")
    }

    /// With differing fields but a due that read back as written, there is nothing to fall back
    /// from: the read-back is judged as usual.
    func testAThrewButCommittedCreateWhoseDueReadsBackIsJudgedAsUsual() throws {
        let reminder = newReminder()
        let report = ReminderCreateWrite.writeTimedDue(reminder, components: nineInNewYork())

        let confirmed = try XCTUnwrap(ReminderCreateWrite.readBack(
            reminder, report: report, storeDiffers: ["title"],
            save: { XCTFail("no second save") }, reload: { true },
            rollback: { XCTFail() }, log: { XCTFail("\($0)") }))

        XCTAssertEqual(confirmed.aligned, true)
    }

    /// A create without a due date has nothing to judge and is not re-read.
    func testAnUndatedCreateIsNotReadBack() {
        let reminder = newReminder()

        XCTAssertNil(ReminderCreateWrite.readBack(reminder, report: nil, storeDiffers: [],
                                                  save: { XCTFail() }, reload: { XCTFail(); return true },
                                                  rollback: { XCTFail() }, log: { _ in XCTFail() }))
    }

    // MARK: - Wiring (source pins: the store path needs a real EKEventStore)

    /// `createReminder` writes the timed due through the seam, judges every dated create with real
    /// store closures after the save, and records the undo entry only after that, so
    /// `postWriteSnapshot` records what a fallback save left.
    func testCreateReminderReadsBackBeforeTheUndoRecord() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func createReminder(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = SourceScan.collapsingWhitespace(body)
        XCTAssertTrue(flat.contains("dateReport = ReminderCreateWrite.writeTimedDue(reminder, components: ReminderDateSync.timedDueComponents(for: due))"), flat)
        XCTAssertTrue(flat.contains("let dateSync = ReminderCreateWrite.readBack(reminder, report: dateReport, storeDiffers: storeDiffers, save: { try eventStore.save(reminder, commit: true) }, reload: { reminder.refresh() }, rollback: { reminder.rollback() })"), flat)
        let save = try XCTUnwrap(flat.range(of: "saveNewReminder("))
        let readBack = try XCTUnwrap(flat.range(of: "ReminderCreateWrite.readBack("))
        let snapshot = try XCTUnwrap(flat.range(of: "ReminderWriteSnapshot(from: reminder), isDuplicate: false"))
        let record = try XCTUnwrap(flat.range(of: "record(.createReminder("))
        XCTAssertLessThan(save.lowerBound, readBack.lowerBound, "judged after the save")
        XCTAssertLessThan(readBack.lowerBound, snapshot.lowerBound, "the response is read from the re-read reminder")
        XCTAssertLessThan(readBack.lowerBound, record.lowerBound, "the undo entry records what the read-back left")
    }
}
