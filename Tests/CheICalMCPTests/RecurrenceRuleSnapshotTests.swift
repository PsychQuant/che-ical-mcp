import XCTest
import EventKit
@testable import CheICalMCP

/// #191 — value-snapshot roundtrip for EKRecurrenceRule (pure objects, no TCC;
/// CI-safe) + undo-stack failure-restore semantics.
final class RecurrenceRuleSnapshotTests: XCTestCase {

    func testDailyWithEndDateRoundtrip() {
        let end = Date(timeIntervalSince1970: 1_760_000_000)
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 2,
                                    end: EKRecurrenceEnd(end: end))
        let rebuilt = RecurrenceRuleSnapshot(from: rule).rebuild()
        XCTAssertEqual(rebuilt.frequency, .daily)
        XCTAssertEqual(rebuilt.interval, 2)
        XCTAssertEqual(rebuilt.recurrenceEnd?.endDate, end)
        XCTAssertNil(rebuilt.recurrenceEnd?.occurrenceCount == 0 ? nil : rebuilt.recurrenceEnd?.occurrenceCount)
    }

    func testWeeklyWithDaysAndCountRoundtrip() {
        let days = [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.friday)]
        let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                    daysOfTheWeek: days, daysOfTheMonth: nil,
                                    monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil,
                                    end: EKRecurrenceEnd(occurrenceCount: 5))
        let rebuilt = RecurrenceRuleSnapshot(from: rule).rebuild()
        XCTAssertEqual(rebuilt.frequency, .weekly)
        XCTAssertEqual(rebuilt.daysOfTheWeek?.map(\.dayOfTheWeek), [.monday, .friday])
        XCTAssertEqual(rebuilt.recurrenceEnd?.occurrenceCount, 5)
    }

    func testMonthlyWithDaysOfMonthNoEndRoundtrip() {
        let rule = EKRecurrenceRule(recurrenceWith: .monthly, interval: 3,
                                    daysOfTheWeek: nil, daysOfTheMonth: [1, 15, 31],
                                    monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: nil)
        let rebuilt = RecurrenceRuleSnapshot(from: rule).rebuild()
        XCTAssertEqual(rebuilt.frequency, .monthly)
        XCTAssertEqual(rebuilt.interval, 3)
        XCTAssertEqual(rebuilt.daysOfTheMonth, [1, 15, 31])
        XCTAssertNil(rebuilt.recurrenceEnd)
    }

    func testWeeksAndDaysOfYearRoundtrip() {
        let rule = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1,
                                    daysOfTheWeek: nil, daysOfTheMonth: nil,
                                    monthsOfTheYear: nil, weeksOfTheYear: [10, -2],
                                    daysOfTheYear: [100, 200], setPositions: nil, end: nil)
        let rebuilt = RecurrenceRuleSnapshot(from: rule).rebuild()
        XCTAssertEqual(rebuilt.weeksOfTheYear, [10, -2])
        XCTAssertEqual(rebuilt.daysOfTheYear, [100, 200])
    }

    func testYearlyWithSetPositionsRoundtrip() {
        let rule = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1,
                                    daysOfTheWeek: [EKRecurrenceDayOfWeek(.sunday, weekNumber: 2)],
                                    daysOfTheMonth: nil, monthsOfTheYear: [6],
                                    weeksOfTheYear: nil, daysOfTheYear: nil,
                                    setPositions: [1, -1], end: nil)
        let rebuilt = RecurrenceRuleSnapshot(from: rule).rebuild()
        XCTAssertEqual(rebuilt.monthsOfTheYear, [6])
        XCTAssertEqual(rebuilt.setPositions, [1, -1])
        XCTAssertEqual(rebuilt.daysOfTheWeek?.first?.weekNumber, 2)
    }

    /// Every other Monday and Sunday, weeks starting on Sunday (`WKST=SU`), as a rule written
    /// by another client reads back. See `setWeekStart(_:on:)` for how the test sets it.
    private func everyOtherWeekStartingSunday() throws -> EKRecurrenceRule {
        let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 2,
                                    daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.sunday)],
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: EKRecurrenceEnd(occurrenceCount: 6))
        try setWeekStart(1, on: rule)
        return rule
    }

    /// #253 verify #8: with an interval above 1 the week start decides which Sunday belongs
    /// to which week; the snapshot dropped it, so delete-undo rebuilt the rule with Monday.
    func testWeekStartRoundtrip() throws {
        let rule = try everyOtherWeekStartingSunday()
        XCTAssertEqual(rule.firstDayOfTheWeek, 1)

        let snapshot = RecurrenceRuleSnapshot(from: rule)
        let rebuilt = snapshot.rebuild()

        XCTAssertEqual(rebuilt.firstDayOfTheWeek, 1)
        XCTAssertEqual(RecurrenceRuleSnapshot(from: rebuilt), snapshot)
    }

    /// Equality decides whether update-undo rewrites the rules, so it must see the week start.
    func testRulesThatDifferOnlyInWeekStartAreNotEqual() throws {
        let sunday = try everyOtherWeekStartingSunday()
        let monday = try everyOtherWeekStartingSunday()
        try setWeekStart(2, on: monday)

        XCTAssertNotEqual(RecurrenceRuleSnapshot(from: sunday), RecurrenceRuleSnapshot(from: monday))
    }

    /// The rebuilt rule must be a fresh object — never the original reference
    /// (the stale-reference class behind the on-device 1010).
    func testRebuildProducesFreshObject() {
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        let rebuilt = RecurrenceRuleSnapshot(from: rule).rebuild()
        XCTAssertFalse(rule === rebuilt)
    }
}

/// #191 — a failed undo/redo must NOT consume the entry.
///
/// Shared-singleton note (R2): CalendarUndoManager has no clear API and probe
/// entries cannot be "executed away" without EventKit, so each test leaves its
/// uniquely-named probe on a stack. That is harmless — no other test asserts
/// an empty stack, and maxStackSize (50) evicts old entries — and each test
/// finds its OWN probe by id rather than assuming absolute stack state.
final class UndoFailureRestoreTests: XCTestCase {

    private func probeId(_ tag: String) -> String { "restore-probe-191-\(tag)-\(UUID().uuidString.prefix(8))" }

    func testRestoreFailedUndoPutsRecordBackExactlyOnce() async {
        let mgr = CalendarUndoManager.shared
        let id = probeId("undo")
        await mgr.record(.createEvent(id: id, title: "t", created: UndoSnapshotFixtures.event(title: "t")))
        guard let record = await mgr.popUndo() else { return XCTFail("expected a record") }
        await mgr.restoreFailedUndo(record)
        // back on top of the undo stack…
        guard let again = await mgr.popUndo() else { return XCTFail("record must be back on the undo stack") }
        guard case .createEvent(let gotId, _, _) = again.operation, gotId == id else {
            return XCTFail("wrong record restored")
        }
        // …and exactly once: the next undo entry (if any) must not be the same probe.
        if let next = await mgr.popUndo() {
            if case .createEvent(let dupId, _, _) = next.operation {
                XCTAssertNotEqual(dupId, id, "restore must not duplicate the entry")
            }
            await mgr.restoreFailedUndo(next)   // put the unrelated entry back untouched
        }
    }

    func testRestoreFailedRedoPutsRecordBack() async {
        let mgr = CalendarUndoManager.shared
        let id = probeId("redo")
        await mgr.record(.createEvent(id: id, title: "t", created: UndoSnapshotFixtures.event(title: "t")))
        guard let undoRec = await mgr.popUndo() else { return XCTFail("expected a record") }
        _ = undoRec   // probe now sits on the redo stack
        guard let redoRec = await mgr.popRedo() else { return XCTFail("expected a redo record") }
        await mgr.restoreFailedRedo(redoRec)
        guard let again = await mgr.popRedo() else { return XCTFail("record must be back on the redo stack") }
        if case .createEvent(let gotId, _, _) = again.operation {
            XCTAssertEqual(gotId, id)
        } else {
            XCTFail("wrong record restored")
        }
    }
}
