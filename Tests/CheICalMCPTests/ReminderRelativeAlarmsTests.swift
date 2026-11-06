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

    /// #433: the list shows the earliest time-based alarm of either kind. Only `[15]`, `[-15]`,
    /// `[15, 0]`, `[0]` and absolute alarms alone are among the measured rows; the rest is inferred.
    func testTheListTimeFollowsTheEarliestAlarmOfEitherKind() {
        let due = absolute
        let earlier = due.addingTimeInterval(-3600)
        func rel(_ minutes: Double) -> ReminderReadSnapshot.Alarm { .relative(seconds: -minutes * 60) }
        let cases: [(String, [ReminderReadSnapshot.Alarm], Bool)] = [
            ("[15]", [rel(15)], true),
            ("[-15]", [rel(-15)], true),
            ("[15, -15]", [rel(15), rel(-15)], true),
            ("[15, 0]", [rel(15), rel(0)], true),
            ("[-15, -60]", [rel(-15), rel(-60)], true),
            ("[0]", [rel(0)], false),
            ("[0, -15]", [rel(0), rel(-15)], false),
            ("none", [], false),
            ("[-15] + absolute at the due time", [rel(-15), .absolute(due)], false),
            ("[15] + earlier absolute", [rel(15), .absolute(earlier)], true),
            ("[0] + earlier absolute", [rel(0), .absolute(earlier)], true),
            ("absolute at the due time", [.absolute(due)], false),
            ("absolute after the due time", [.absolute(due.addingTimeInterval(900))], true),
            ("absolute earlier", [.absolute(earlier)], true),
            ("a non-finite offset is left out", [.relative(seconds: .infinity)], false)
        ]
        for (name, alarms, expected) in cases {
            XCTAssertEqual(ReminderRelativeAlarms.listShowsAlarmTime(due: due, alarms: alarms), expected, name)
        }
        XCTAssertFalse(ReminderRelativeAlarms.listShowsAlarmTime(due: nil, alarms: [rel(15)]), "no instant to compare with")
    }

    /// Read off the reminder: only a timed due, and a location alarm does not count.
    func testTheListTimeOnASavedReminder() {
        var timedDue = DateComponents(year: 2026, month: 12, day: 10, hour: 15, minute: 30)
        timedDue.timeZone = TimeZone(identifier: "Asia/Taipei")
        let item = reminder()
        item.dueDateComponents = timedDue
        item.addAlarm(locationAlarm())
        XCTAssertFalse(ReminderRelativeAlarms.listShowsAlarmTime(saved: item), "a location alarm is not time-based")
        item.addAlarm(EKAlarm(relativeOffset: -900))
        XCTAssertTrue(ReminderRelativeAlarms.listShowsAlarmTime(saved: item))
        let dated = reminder()
        dated.dueDateComponents = DateComponents(year: 2026, month: 12, day: 10)
        dated.addAlarm(EKAlarm(relativeOffset: -900))
        XCTAssertFalse(ReminderRelativeAlarms.listShowsAlarmTime(saved: dated), "date-only: not measured, the leftover note speaks")
        let undated = reminder()
        undated.addAlarm(EKAlarm(relativeOffset: -900))
        XCTAssertFalse(ReminderRelativeAlarms.listShowsAlarmTime(saved: undated))
    }

    /// The three mixed shapes on a reminder, read through the same path as the store. None of them
    /// is among the measured rows.
    func testMixedAlarmsOnASavedReminder() throws {
        var dueComponents = DateComponents(year: 2026, month: 12, day: 10, hour: 15, minute: 30)
        dueComponents.timeZone = TimeZone(identifier: "Asia/Taipei")
        let due = try XCTUnwrap(safeDateFromComponents(dueComponents))
        func saved(_ alarms: EKAlarm...) -> EKReminder {
            let item = reminder()
            item.dueDateComponents = dueComponents
            alarms.forEach(item.addAlarm)
            return item
        }
        let earlier = due.addingTimeInterval(-3600)
        XCTAssertFalse(ReminderRelativeAlarms.listShowsAlarmTime(
            saved: saved(EKAlarm(relativeOffset: 900), EKAlarm(absoluteDate: due))), "[-15] + absolute at the due time")
        XCTAssertTrue(ReminderRelativeAlarms.listShowsAlarmTime(
            saved: saved(EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: earlier))), "[15] + earlier absolute")
        XCTAssertTrue(ReminderRelativeAlarms.listShowsAlarmTime(
            saved: saved(EKAlarm(relativeOffset: 0), EKAlarm(absoluteDate: earlier))), "[0] + earlier absolute")
    }

    /// A timed due without a zone is read in the host zone, as `date_sync` and the read side read
    /// it, so an absolute alarm at that wall clock is at the due time.
    func testAFloatingDueIsComparedInTheHostZone() throws {
        let wall = DateComponents(year: 2026, month: 12, day: 10, hour: 15, minute: 30)
        let item = reminder()
        item.dueDateComponents = wall
        item.addAlarm(EKAlarm(absoluteDate: try XCTUnwrap(safeDateFromComponents(wall))))
        XCTAssertFalse(ReminderRelativeAlarms.listShowsAlarmTime(saved: item))
    }

    func testWhichUpdatesReportTheListTime() {
        func request(offsets: [Int]? = nil, due: ReminderDueInput? = nil, clear: Bool = false, realign: Bool = false) -> ReminderUpdateRequest {
            ReminderUpdateRequest(identifier: "r", due: due, clearDueDate: clear, realignToDue: realign, alarmOffsets: offsets)
        }
        XCTAssertTrue(ReminderRelativeAlarms.reportsListTime(request(offsets: [15])))
        XCTAssertTrue(ReminderRelativeAlarms.reportsListTime(request(due: .timed(absolute))))
        XCTAssertTrue(ReminderRelativeAlarms.reportsListTime(request(realign: true)))
        XCTAssertFalse(ReminderRelativeAlarms.reportsListTime(request()), "a title change says nothing")
        XCTAssertFalse(ReminderRelativeAlarms.reportsListTime(request(clear: true)), "no due, no list time to compare")
    }

    /// PR #438 verify: an offsets-only update did not reload, so `stored` was the list just written.
    func testAnOffsetsOnlyUpdateReadsTheAlarmsBack() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        XCTAssertTrue(code.contains("let alarmsReadBack = alarmOffsets == nil || dateSync != nil || reminder.refresh()"), "reload")
        XCTAssertTrue(code.contains("storedRelativeAlarms: alarmsReadBack ? alarmOffsets.map { _ in ReminderRelativeAlarms.storedMinutesBefore(reminder) } : nil"), "use")
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

    /// PR #415 verify round 1: offsets are bounded to one year in minutes, so the seconds can be
    /// computed without overflow on every tool that takes them.
    func testOffsetsAreBoundedToOneYear() throws {
        XCTAssertEqual(InputValidation.maxAlarmOffsetMinutes, 525_600)
        XCTAssertEqual(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .array([.int(525_600), .int(-525_600)])]), [525_600, -525_600])
        for bad in [525_601, -525_601, Int.max, Int.min] {
            XCTAssertThrowsError(try InputValidation.parseAlarmOffsets(["alarms_minutes_offsets": .array([.int(bad)])])) { error in
                XCTAssertTrue("\(error)".contains("525600"), "\(error)")
            }
        }
    }

    /// PR #415 verify round 1: an update that leaves relative alarms on a reminder without a timed
    /// due (a bare due_date or clear_due_date, no alarms_minutes_offsets) says so; nothing else does.
    func testLeftoverRelativeAlarmsAreNamed() {
        XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(requested: nil, dueTouched: true, dueAfter: .none, relativeCount: 2),
                       ReminderRelativeAlarms.leftoverNoDueNote(2))
        XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(requested: nil, dueTouched: true, dueAfter: .dateOnly, relativeCount: 1),
                       ReminderRelativeAlarms.leftoverDateOnlyNote(1))
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(requested: nil, dueTouched: true, dueAfter: .timed, relativeCount: 1))
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(requested: nil, dueTouched: true, dueAfter: .none, relativeCount: 0))
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(requested: nil, dueTouched: false, dueAfter: .dateOnly, relativeCount: 1),
                     "an update that does not touch the due adds no note")
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(requested: [], dueTouched: true, dueAfter: .none, relativeCount: 0))
        XCTAssertTrue(ReminderRelativeAlarms.leftoverNoDueNote(2).contains("alarms_minutes_offsets: []"))
        XCTAssertTrue(ReminderRelativeAlarms.leftoverDateOnlyNote(1).contains("date-only"))
    }

    /// PR #415 verify rounds 1-2: the #236 post-state guard on an alarm-only update and on a create
    /// with alarms. The recorded snapshot is compared with a separately built reminder holding the
    /// same values in new EventKit objects (what a later read gives), so the check is by value, not
    /// by object identity: equal values pass the guard; an alarm changed elsewhere is named. What a
    /// synced store returns is the release gate's job.
    func testThePostStateGuardComparesAlarmsByValue() throws {
        let due = DateComponents(year: 2026, month: 12, day: 10, hour: 9, minute: 0)
        let item = reminder()
        item.dueDateComponents = due
        item.addAlarm(locationAlarm())
        item.addAlarm(EKAlarm(relativeOffset: -600))
        let before = ReminderSnapshot(from: item)
        _ = try ReminderUpdateWrite.apply(ReminderUpdateRequest(identifier: "r", alarmOffsets: [15]), to: item, calendar: nil,
                                          save: {}, reload: { true }, rollback: {})
        let post = ReminderSnapshot(from: item)

        func readBack(_ offsets: [Int]) -> EKReminder {
            let copy = reminder()
            copy.dueDateComponents = due
            copy.addAlarm(locationAlarm())
            ReminderRelativeAlarms.replace(on: copy, with: offsets)
            return copy
        }
        let unchanged = readBack([15])
        XCTAssertFalse(unchanged === item)
        XCTAssertEqual(post.changedFields(in: ReminderSnapshot(from: unchanged), restoring: before), [])
        // Through the guard's own flow, as undo runs it.
        XCTAssertNoThrow(try UndoTargetCheck.check(
            .reminder(id: "r", title: "t", state: post, restoring: before), verb: .undo,
            lookup: { unchanged }, refresh: { _ in true },
            conflicts: { post.changedFields(in: ReminderSnapshot(from: $0), restoring: before) }))
        XCTAssertEqual(post.changedFields(in: ReminderSnapshot(from: readBack([20])), restoring: before), ["alarms"])
        XCTAssertThrowsError(try UndoTargetCheck.check(
            .reminder(id: "r", title: "t", state: post, restoring: before), verb: .undo,
            lookup: { readBack([20]) }, refresh: { _ in true },
            conflicts: { post.changedFields(in: ReminderSnapshot(from: $0), restoring: before) }))

        let created = reminder()
        created.dueDateComponents = due
        ReminderRelativeAlarms.replace(on: created, with: [15])
        let createdPost = ReminderSnapshot(from: created)
        let createdReadBack = reminder()
        createdReadBack.dueDateComponents = due
        ReminderRelativeAlarms.replace(on: createdReadBack, with: [15])
        XCTAssertEqual(createdPost.changedFields(in: ReminderSnapshot(from: createdReadBack), restoring: nil), [])
    }

    /// PR #415 verify round 2: an update that names its own alarms gets no leftover note.
    func testALeftoverNoteNeedsNoRequestedAlarms() {
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(requested: [15], dueTouched: true, dueAfter: .dateOnly, relativeCount: 1))
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(requested: [15], dueTouched: true, dueAfter: .none, relativeCount: 1))
    }

    /// PR #415 verify round 2: the note is read off the saved reminder and the request, the way
    /// `updateReminder` calls it (due state and relative alarms of the saved item; due touched by a
    /// bare date or `clear_due_date`).
    func testTheLeftoverNoteIsReadOffTheSavedReminder() {
        let dateOnly = reminder()
        dateOnly.dueDateComponents = DateComponents(year: 2026, month: 12, day: 11)
        dateOnly.addAlarm(EKAlarm(relativeOffset: -900))
        dateOnly.addAlarm(EKAlarm(absoluteDate: absolute))
        dateOnly.addAlarm(locationAlarm())
        let bareDay = ReminderUpdateRequest(identifier: "r", due: .day(DateComponents(year: 2026, month: 12, day: 11)))
        XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(saved: dateOnly, request: bareDay), ReminderRelativeAlarms.leftoverDateOnlyNote(1),
                       "only the relative alarm is counted")
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(saved: dateOnly, request: ReminderUpdateRequest(identifier: "r", title: "t")),
                     "an update that does not touch the due")
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(saved: dateOnly, request: ReminderUpdateRequest(
            identifier: "r", due: .day(DateComponents(year: 2026, month: 12, day: 11)), alarmOffsets: [])))

        let undated = reminder()
        undated.addAlarm(EKAlarm(relativeOffset: -900))
        undated.addAlarm(EKAlarm(relativeOffset: -60))
        XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(saved: undated, request: ReminderUpdateRequest(identifier: "r", clearDueDate: true)),
                       ReminderRelativeAlarms.leftoverNoDueNote(2))

        let timed = reminder()
        timed.dueDateComponents = DateComponents(year: 2026, month: 12, day: 11, hour: 9, minute: 0)
        timed.addAlarm(EKAlarm(relativeOffset: -900))
        XCTAssertNil(ReminderRelativeAlarms.leftoverNote(saved: timed, request: ReminderUpdateRequest(identifier: "r", due: .timed(absolute))))
        // PR #415 verify round 3: a timed due_date that the store keeps only as a day (the #237
        // fallback that did not take) is judged by what was saved, not by what was asked.
        let lostTime = reminder()
        lostTime.dueDateComponents = DateComponents(year: 2026, month: 12, day: 11)
        lostTime.addAlarm(EKAlarm(relativeOffset: -900))
        XCTAssertEqual(ReminderRelativeAlarms.leftoverNote(saved: lostTime, request: ReminderUpdateRequest(identifier: "r", due: .timed(absolute))),
                       ReminderRelativeAlarms.leftoverDateOnlyNote(1))
    }

    /// The store path builds the note through that helper, from the saved reminder and the request.
    func testUpdateReminderWiresTheLeftoverNote() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        XCTAssertEqual(code.components(separatedBy: "leftoverAlarmsNote: ReminderRelativeAlarms.leftoverNote(saved: reminder, request: request)").count - 1, 1)
        // PR #415 verify round 3: compared without whitespace, so a line break cannot hide a second call.
        let compact = code.filter { !$0.isWhitespace }
        XCTAssertFalse(compact.contains("ReminderRelativeAlarms.leftoverNote(requested:"), "no second, hand-wired computation")
    }
}
