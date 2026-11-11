import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #423: completing a repeating reminder that has a location trigger leaves a plain 0-minute
/// relative alarm on the next occurrence and on the completed copy (measured on iCloud,
/// 2026-11-05); the server writes no alarm on that path. `complete_reminder` reads the next
/// occurrence's relative alarms back after a reload and names any that appeared. In-memory
/// EventKit objects only.
final class ReminderRolloverAlarmsTests: XCTestCase {
    private func reminder() -> EKReminder { EKReminder(eventStore: SharedTestStore.store) }

    private static let weekly = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))

    private func snap(day: Int, id: String = "r", completed: Bool = false,
                      rule: ReminderRecurrenceRuleValue = weekly) -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(id: id, title: "Repeat", calendarID: "list", sourceID: "source", isCompleted: completed,
                                   hasRecurrence: true, due: ReminderDueValue(components: DateComponents(year: 2026, month: 12, day: day)),
                                   rules: [rule], completionDate: nil)
    }

    /// A rollover from the 10th to the 17th, as `completeReminder` observes it.
    private var rollover: ReminderNextOccurrence {
        .evaluate(before: snap(day: 10), observed: snap(day: 17), requestedCompleted: true)
    }

    func testAddedIsAMultisetDifference() {
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [15], after: [15, 0]), [0])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [], after: [0]), [0])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [15], after: [15]), [])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [0], after: [0, 0]), [0])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [15, 0], after: [0]), [], "a removed alarm is not 'added'")
    }

    /// Read after the reload: what the store holds, not the object as it was before.
    func testTheAlarmsAreReadAfterTheReload() throws {
        let item = reminder()
        item.addAlarm(EKAlarm(relativeOffset: -900))
        var reloaded = false
        let observed = try XCTUnwrap(ReminderRolloverAlarms.observe(before: [15], next: rollover, item: item, reload: {
            reloaded = true
            item.addAlarm(EKAlarm(relativeOffset: 0))   // the store's rollover alarm
            let location = EKAlarm()
            location.structuredLocation = EKStructuredLocation(title: "Somewhere")
            item.addAlarm(location)                     // a location alarm is not a relative one
            return self.snap(day: 17)
        }))
        XCTAssertTrue(reloaded)
        XCTAssertTrue(observed.readBack)
        XCTAssertEqual(observed.minutesBefore, [15, 0])
        XCTAssertEqual(observed.added, [0])
    }

    func testAFailedReloadClaimsNothing() throws {
        let observed = try XCTUnwrap(ReminderRolloverAlarms.observe(before: [15], next: rollover, item: reminder(), reload: { nil }))
        XCTAssertFalse(observed.readBack)
        XCTAssertEqual(observed.minutesBefore, [])
        XCTAssertEqual(observed.added, [])
        XCTAssertEqual(observed.nextOccurrenceFields["alarms_read_back"] as? Bool, false)
        XCTAssertNil(observed.nextOccurrenceFields["alarms_minutes_offsets"])
        XCTAssertEqual(observed.topLevelFields["alarms_read_back_note"] as? String, ReminderRolloverAlarms.unreadNote)
        XCTAssertNil(observed.topLevelFields["alarms_note"])
    }

    /// PR #425 verify: what the reload finds is not the occurrence `next_occurrence` names (another
    /// writer completed, moved or re-ruled it), so its alarms are not merged into that occurrence.
    func testAnOccurrenceThatChangedDuringTheReloadClaimsNothing() throws {
        let otherRule = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let changed: [(String, ReminderCompletionSnapshot)] = [
            ("advanced to the next due", snap(day: 24)),
            ("completed in place", snap(day: 17, completed: true)),
            ("another identifier", snap(day: 17, id: "other")),
            ("another rule", snap(day: 17, rule: otherRule))
        ]
        for (name, reloaded) in changed {
            let item = reminder()
            let observed = try XCTUnwrap(ReminderRolloverAlarms.observe(before: [15], next: rollover, item: item, reload: {
                item.addAlarm(EKAlarm(relativeOffset: -1800))
                return reloaded
            }), name)
            XCTAssertFalse(observed.readBack, name)
            XCTAssertEqual(observed.minutesBefore, [], name)
            XCTAssertEqual(observed.added, [], name)
            XCTAssertEqual(observed.topLevelFields["alarms_read_back_note"] as? String, ReminderRolloverAlarms.unreadNote, name)
            XCTAssertNil(observed.topLevelFields["alarms_note"], name)
        }
    }

    /// Only a confirmed rollover is observed: nothing is reloaded and the response is unchanged
    /// for a reminder that does not repeat, a reopen, or an unknown next occurrence.
    func testOnlyAConfirmedRolloverIsObserved() {
        let outcomes: [(String, ReminderNextOccurrence)] = [
            ("not applicable", .notApplicable),
            ("identity changed", .evaluate(before: snap(day: 10), observed: snap(day: 17, id: "other"), requestedCompleted: true)),
            ("reopened", .evaluate(before: snap(day: 10), observed: snap(day: 17), requestedCompleted: false)),
            ("due not advanced", .evaluate(before: snap(day: 10), observed: snap(day: 10), requestedCompleted: true))
        ]
        for (name, next) in outcomes {
            XCTAssertNotEqual(next.status, .confirmed, name)
            var reloaded = false
            let observed = ReminderRolloverAlarms.observe(before: [15], next: next, item: reminder(), reload: {
                reloaded = true
                return self.snap(day: 17)
            })
            XCTAssertNil(observed, name)
            XCTAssertFalse(reloaded, name)
        }
    }

    func testTheFields() {
        let added = ReminderRolloverAlarms(readBack: true, minutesBefore: [15, 0], added: [0])
        XCTAssertEqual(added.nextOccurrenceFields["alarms_minutes_offsets"] as? [Double], [15, 0])
        XCTAssertEqual(added.topLevelFields["alarms_note"] as? String, ReminderRolloverAlarms.note(added: [0]))
        let none = ReminderRolloverAlarms(readBack: true, minutesBefore: [15], added: [])
        XCTAssertEqual(none.nextOccurrenceFields["alarms_minutes_offsets"] as? [Double], [15])
        XCTAssertTrue(none.topLevelFields.isEmpty)
    }

    /// The note states what was observed and what was verified. A read-back cannot tell who wrote
    /// the alarm, and the save that rolled the reminder over is this call's, so it neither says the
    /// store added this one nor that this call wrote none (PR #425 verify rounds 1 and 2).
    func testTheNoteWording() {
        let note = ReminderRolloverAlarms.note(added: [0])
        XCTAssertTrue(note.contains("(minutes_before: 0)"), note)
        XCTAssertTrue(note.contains("appeared"), note)
        XCTAssertTrue(note.contains("not there before this completion"), note)
        XCTAssertTrue(note.contains("This call sets only the completion fields"), note)
        XCTAssertFalse(note.contains("The store added"), note)
        XCTAssertFalse(note.contains("wrote no alarm"), note)
        XCTAssertTrue(note.contains("another app or a sync"), note)
        XCTAssertTrue(note.contains("location trigger"), note)
        XCTAssertTrue(note.contains("not checked"), note)
        XCTAssertTrue(note.contains("alarms_minutes_offsets"), note)
        let two = ReminderRolloverAlarms.note(added: [0, 0])
        XCTAssertTrue(two.contains("2 relative alarms"), two)
        XCTAssertTrue(two.contains("were not there before this completion"), two)
        XCTAssertTrue(ReminderRolloverAlarms.unreadNote.contains("could not be re-read"))
        XCTAssertTrue(ReminderRolloverAlarms.unreadNote.contains("changed"), ReminderRolloverAlarms.unreadNote)
        XCTAssertTrue(ReminderRolloverAlarms.unreadNote.contains("list_reminders"), ReminderRolloverAlarms.unreadNote)
    }

    /// The offsets come from a re-read, so another app or a sync can have written any value; the
    /// write side's range says nothing about them (PR #425 verify round 2: `Int(value)` trapped).
    func testTheNoteFormatsAnyOffset() {
        XCTAssertTrue(ReminderRolloverAlarms.note(added: [1.5]).contains("(minutes_before: 1.5)"))
        XCTAssertTrue(ReminderRolloverAlarms.note(added: [-5]).contains("(minutes_before: -5)"))
        XCTAssertTrue(ReminderRolloverAlarms.note(added: [-0.0]).contains("(minutes_before: 0)"))
        XCTAssertTrue(ReminderRolloverAlarms.note(added: [1e300]).contains("(minutes_before: \(1e300))"))
        for value in [Double(Int.max), -Double(Int.max) * 2, Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
            XCTAssertTrue(ReminderRolloverAlarms.note(added: [value]).contains("minutes_before: "), "\(value)")
        }
    }

    /// The response carries them: next_occurrence.alarms_minutes_offsets and a top-level alarms_note.
    func testTheCompletionResultCarriesThem() throws {
        let rule = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        func snap(day: Int) -> ReminderCompletionSnapshot {
            ReminderCompletionSnapshot(id: "r", title: "Repeat", calendarID: "list", sourceID: "source", isCompleted: false,
                                       hasRecurrence: true, due: ReminderDueValue(components: DateComponents(year: 2026, month: 12, day: day)),
                                       rules: [rule], completionDate: nil)
        }
        var result = ReminderCompletionResult(before: snap(day: 10), afterSave: snap(day: 17), requestedCompleted: true,
                                              nextOccurrence: .evaluate(before: snap(day: 10), observed: snap(day: 17), requestedCompleted: true))
        XCTAssertNil(result.dictionary["alarms_note"])
        result.rolloverAlarms = ReminderRolloverAlarms(readBack: true, minutesBefore: [0], added: [0])
        let dict = result.dictionary
        XCTAssertEqual((dict["next_occurrence"] as? [String: Any])?["alarms_minutes_offsets"] as? [Double], [0])
        XCTAssertEqual(dict["alarms_note"] as? String, ReminderRolloverAlarms.note(added: [0]))
        XCTAssertEqual((dict["next_occurrence"] as? [String: Any])?["status"] as? String, "confirmed", "the existing keys stay")
    }

    /// The store path observes the alarms with a reload and writes nothing more.
    func testCompleteReminderWiresTheObservation() throws {
        let code = try Self.managerCode()
        XCTAssertTrue(code.contains("ReminderRolloverAlarms.observe(before: beforeRelativeAlarms, next: next, item: reminder, reload: { reminder.refresh() ? ReminderCompletionSnapshot(from: reminder) : nil })"), code)
        let body = try Self.completeReminderBody(code)
        XCTAssertEqual(body.components(separatedBy: "savedOrUnread(").count - 1, 1, "one save, as before")
        Self.assertNoAlarmWrite(body, "completeReminder")
    }

    /// PR #425 verify: `before`, the save and the reload sit in one stretch with no suspension point,
    /// so no other call of this server can write to the reminder between them. `CalendarUndoManager`
    /// is another actor, so awaiting it lets this actor be re-entered.
    func testTheObservationComesBeforeAnySuspensionPoint() throws {
        let body = try Self.completeReminderBody(try Self.managerCode())
        let start = try XCTUnwrap(body.range(of: "let beforeRelativeAlarms"))
        let observe = try XCTUnwrap(body.range(of: "ReminderRolloverAlarms.observe("))
        let stretch = body[start.lowerBound..<observe.lowerBound]
        XCTAssertTrue(stretch.contains("savedOrUnread("), String(stretch))
        XCTAssertFalse(stretch.contains("await"), String(stretch))
        let mark = try XCTUnwrap(body.range(of: "markNeedsRefresh()"))
        let record = try XCTUnwrap(body.range(of: "CalendarUndoManager.shared.record("))
        XCTAssertLessThan(observe.lowerBound, mark.lowerBound)
        XCTAssertLessThan(observe.lowerBound, record.lowerBound)
    }

    /// Option (1) of the #423 diagnosis: this path reports and never writes. The observation holds
    /// no alarm write and no save either, and the write it follows sets only the completion fields.
    func testTheObservationWritesNothing() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/ReminderRolloverAlarms.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        Self.assertNoAlarmWrite(code, "ReminderRolloverAlarms.swift")
        XCTAssertFalse(code.contains("save("), code)
    }

    /// PR #425 verify round 2: "this call sets only the completion fields" is a claim about the
    /// function that does the write, so the guard has to reach it.
    func testTheCompletionWriteSetsOnlyTheCompletionFields() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("ReminderCompletion.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        let write = try XCTUnwrap(SourceScan.body(of: "struct ReminderCompletionWrite: Equatable, Sendable {", in: code))
        Self.assertNoAlarmWrite(write, "ReminderCompletionWrite")
        let apply = try XCTUnwrap(SourceScan.body(of: "func apply(to reminder: EKReminder) {", in: write))
        let assigned = apply.matches(of: try Regex(#"reminder\.(\w+) ="#)).compactMap { $0[1].substring.map(String.init) }
        XCTAssertEqual(Set(assigned), ["isCompleted", "completionDate"], apply)
    }

    private static func managerCode() throws -> String {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager+ReminderCompletion.swift")
        return SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
    }

    private static func completeReminderBody(_ code: String) throws -> String {
        try XCTUnwrap(SourceScan.body(of: "func completeReminder(identifier: String, completed: Bool = true) async throws -> ReminderCompletionResult {", in: code))
    }

    private static func assertNoAlarmWrite(_ code: String, _ place: String) {
        for form in ["addAlarm", "removeAlarm", "ReminderRelativeAlarms.replace", ".alarms?."] {
            XCTAssertFalse(code.contains(form), "\(place): \(form)")
        }
        XCTAssertNil(code.range(of: #"\.alarms\s*=[^=]"#, options: .regularExpression), place)
    }
}
