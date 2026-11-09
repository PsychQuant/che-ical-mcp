import EventKit
import XCTest
@testable import CheICalMCP

/// The setters a date write calls on the write store's copy, in order (PR #507 round 4). Only the
/// outermost call is logged: EventKit's own setters call the others (a due write sets the start and
/// the zone again), which is not the order this server writes in.
private final class SetterLog {
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var depth = 0
    static func record(_ name: String, _ body: () -> Void) {
        if depth == 0 { calls.append(name) }
        depth += 1
        body()
        depth -= 1
    }
}

private final class RecordingReminder: EKReminder {
    override var startDateComponents: DateComponents? {
        get { super.startDateComponents }
        set { SetterLog.record(newValue == nil ? "start=nil" : "start") { super.startDateComponents = newValue } }
    }
    override var dueDateComponents: DateComponents? {
        get { super.dueDateComponents }
        set { SetterLog.record(newValue == nil ? "due=nil" : "due") { super.dueDateComponents = newValue } }
    }
    override var timeZone: TimeZone? {
        get { super.timeZone }
        set { SetterLog.record("zone") { super.timeZone = newValue } }
    }
}

/// PR #507 round 4.
final class ReminderWriteStoreRound4Tests: XCTestCase {
    private let store = SharedTestStore.store
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func list() -> EKCalendar {
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = "L"
        return c
    }

    private func zoned(day: Int, hour: Int) -> DateComponents {
        DateComponents(timeZone: taipei, year: 2026, month: 10, day: day, hour: hour, minute: 0)
    }

    // MARK: - MEDIUM 1: the #237 second save keeps its order on the copy

    /// A reminder whose date setters are logged: EventKit's factory initializer is not inherited, so
    /// a plain reminder is given the recording class (it adds no stored properties).
    private func recording() -> EKReminder {
        let r = EKReminder(eventStore: store)
        object_setClass(r, RecordingReminder.self)
        return r
    }

    func testTheRecordingReminderLogsItsSetters() {
        let r = recording()
        SetterLog.calls = []
        r.dueDateComponents = DateComponents(year: 2026, month: 10, day: 9)
        XCTAssertEqual(SetterLog.calls, ["due"])
    }

    /// The fallback's second save writes the copy in `writeDueAroundStart`'s order: clear the start,
    /// write the due, put the start back; the zone is not assigned on its own.
    func testTheSecondSaveWritesTheDueAroundTheStartOnTheCopy() throws {
        let l = list()
        let cached = EKReminder(eventStore: store)
        cached.calendar = l
        cached.startDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        cached.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        let before = ReminderFieldCopy.Values(cached)
        ReminderDateSync.writeDueAroundStart(cached, due: zoned(day: 8, hour: 10))
        let wanted = ReminderFieldCopy.Values(cached)
        let fields = ReminderFieldCopy.changed(from: before, to: wanted)

        let copy = recording()
        copy.calendar = l
        copy.startDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        copy.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        SetterLog.calls = []
        try ReminderFieldCopy.apply(wanted, fields: fields, to: copy, calendar: { _ in l }, dates: .dueAroundStart)
        XCTAssertEqual(SetterLog.calls, ["start=nil", "due", "start"])
        XCTAssertEqual(copy.dueDateComponents?.hour, 10)
        XCTAssertEqual(copy.startDateComponents?.hour, 0)
    }

    /// The first save keeps `restore`'s order, which writes the start before the due.
    func testTheFirstSaveKeepsTheRestoreOrder() throws {
        let l = list()
        let cached = EKReminder(eventStore: store)
        cached.calendar = l
        let before = ReminderFieldCopy.Values(cached)
        cached.dueDateComponents = DateComponents(year: 2026, month: 10, day: 9)
        let wanted = ReminderFieldCopy.Values(cached)
        let copy = recording()
        copy.calendar = l
        SetterLog.calls = []
        try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: copy, calendar: { _ in l })
        XCTAssertEqual(SetterLog.calls.first, "due")
        XCTAssertFalse(SetterLog.calls.contains("start=nil") && SetterLog.calls.firstIndex(of: "start=nil")! < SetterLog.calls.firstIndex(of: "due")!)
    }

    /// `confirmSaved` makes its second save through `saveAgain` when one is given.
    func testTheSecondSaveGoesThroughSaveAgain() {
        let reminder = EKReminder(eventStore: store)
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 7)
        var due = DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 0)
        due.timeZone = .current
        let report = ReminderDateSync.setDue(reminder, to: Calendar.current.date(from: due)!)
        var log: [String] = []
        var reloads = 0
        _ = ReminderDateSync.confirmSaved(reminder, report: report,
                                          save: { log.append("save") },
                                          saveAgain: { log.append("saveAgain") },
                                          reload: { reloads += 1; if reloads == 1 { reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8) }; return true },
                                          rollback: {}, log: { _ in })
        XCTAssertEqual(log, ["saveAgain"])
    }

    // MARK: - LOW: a due change does not force the zone

    func testADueChangeDoesNotNameTheZone() {
        XCTAssertFalse(ReminderUpdateWrite.requestedFields(ReminderUpdateRequest(identifier: "r", clearDueDate: true)).contains(.timeZone))
        XCTAssertFalse(ReminderUpdateWrite.requestedFields(ReminderUpdateRequest(identifier: "r", due: .day(DateComponents(year: 2027, month: 3, day: 1)))).contains(.timeZone))
    }

    // MARK: - LOW: complete_reminder refuses a copy at another occurrence

    private func occurrence(due day: Int, repeats: Bool = true) -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(id: "R", title: "T", calendarID: "C", sourceID: "S", isCompleted: false, hasRecurrence: repeats,
                                   due: ReminderDueValue(components: DateComponents(year: 2026, month: 11, day: day, hour: 9, minute: 0)),
                                   rules: repeats ? [ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))] : nil,
                                   completionDate: nil)
    }

    func testACompletionOfACopyAtAnotherOccurrenceIsRefused() {
        XCTAssertThrowsError(try ReminderCompletionWrite.checkSameOccurrence(read: occurrence(due: 9), copy: occurrence(due: 16))) { error in
            guard case .completionOccurrenceMoved = error as? EventKitError else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try ReminderCompletionWrite.checkSameOccurrence(read: occurrence(due: 9), copy: occurrence(due: 9)))
        XCTAssertNoThrow(try ReminderCompletionWrite.checkSameOccurrence(read: occurrence(due: 9, repeats: false), copy: occurrence(due: 16, repeats: false)),
                         "a one-off reminder has no occurrence to move on")
        let text = EventKitError.completionOccurrenceMoved.errorDescription ?? ""
        XCTAssertTrue(text.hasPrefix("Nothing was written"), text)
    }

    /// The check runs after the baseline and before the write: a refusal writes and saves nothing.
    func testACheckThatRefusesStopsBeforeTheWrite() {
        struct Refused: Error {}
        var log: [String] = []
        XCTAssertThrowsError(try ExistingReminderSave.commit(
            lookup: { log.append("lookup"); return "copy" },
            baseline: { _ -> String in log.append("baseline"); return "b" },
            check: { _ in log.append("check"); throw Refused() },
            write: { _ in log.append("write") },
            save: { _ in log.append("save") }))
        XCTAssertEqual(log, ["lookup", "baseline", "check"])
    }

    // MARK: - LOW: a removal takes its snapshot and its completed check from the copy

    func testARemovalSnapshotsTheCopyAndSkipsAnUncompletedOne() throws {
        var log: [String] = []
        let removed = try ExistingReminderSave.removal(
            lookup: { log.append("lookup"); return "copy" },
            snapshot: { item -> String in log.append("snapshot"); return "snap of \(item)" },
            skip: { _ in false },
            remove: { _ in log.append("remove") })
        XCTAssertEqual(removed, "snap of copy")
        XCTAssertEqual(log, ["lookup", "snapshot", "remove"])

        log = []
        let skipped = try ExistingReminderSave.removal(
            lookup: { log.append("lookup"); return "copy" },
            snapshot: { _ -> String in log.append("snapshot"); return "s" },
            skip: { _ in true },
            remove: { _ in log.append("remove") })
        XCTAssertNil(skipped)
        XCTAssertEqual(log, ["lookup", "snapshot"], "a skipped row removes nothing")
    }

    func testTheDeletePathsUseTheCopy() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(manager.contains("guard let snapshot = try commitReminderRemoval(reminder, onlyCompleted: onlyCompleted) else { failures.append((id, \"Reminder is no longer completed\")) continue }"))
        XCTAssertTrue(manager.contains("let snapshot = try removeExistingReminder(reminder, handler: \"deleteReminder\")"))
        XCTAssertFalse(manager.contains("isCompleted: reminder.isCompleted, onlyCompleted: onlyCompleted"))
        let save = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/ExistingReminderSave.swift")))
        XCTAssertTrue(save.contains("skip: { BatchDeleteFilter.shouldSkipUncompleted(isCompleted: $0.isCompleted, onlyCompleted: onlyCompleted) }"))
    }

    func testCompleteReminderChecksTheCopysOccurrence() throws {
        let completion = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager+ReminderCompletion.swift")))
        XCTAssertTrue(completion.contains("requested: ReminderCompletionWrite.requestedFields, occurrence: before)"))
        let save = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/ExistingReminderSave.swift")))
        XCTAssertTrue(save.contains("check: { before in if let occurrence { try ReminderCompletionWrite.checkSameOccurrence(read: occurrence, copy: before.1) } }"))
    }

    // MARK: - INFO 6: complete_reminder's description names the read-back error

    func testCompleteReminderDescriptionNamesTheReadBackError() throws {
        let server = try SourcePins.source("Server.swift")
        let start = try XCTUnwrap(server.range(of: "name: \"complete_reminder\","))
        let description = server[start.upperBound...].prefix(3000)
        XCTAssertTrue(description.contains("a save that lands but cannot be read back answers writeStoreReadBackFailed and keeps its undo record"))
    }
}
