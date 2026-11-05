import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #423: completing a repeating reminder that has a location trigger leaves a plain 0-minute
/// relative alarm on the next occurrence and on the completed copy (measured on iCloud,
/// 2026-11-05); the server writes no alarm on that path. `complete_reminder` reads the next
/// occurrence's relative alarms back after a reload and names any the store added. In-memory
/// EventKit objects only.
final class ReminderRolloverAlarmsTests: XCTestCase {
    private func reminder() -> EKReminder { EKReminder(eventStore: SharedTestStore.store) }

    func testAddedIsAMultisetDifference() {
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [15], after: [15, 0]), [0])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [], after: [0]), [0])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [15], after: [15]), [])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [0], after: [0, 0]), [0])
        XCTAssertEqual(ReminderRolloverAlarms.added(before: [15, 0], after: [0]), [], "a removed alarm is not 'added'")
    }

    /// Read after the reload: what the store holds, not the object as it was before.
    func testTheAlarmsAreReadAfterTheReload() {
        let item = reminder()
        item.addAlarm(EKAlarm(relativeOffset: -900))
        var reloaded = false
        let observed = ReminderRolloverAlarms.observe(before: [15], item: item, reload: {
            reloaded = true
            item.addAlarm(EKAlarm(relativeOffset: 0))   // the store's rollover alarm
            let location = EKAlarm()
            location.structuredLocation = EKStructuredLocation(title: "Somewhere")
            item.addAlarm(location)                     // a location alarm is not a relative one
            return true
        })
        XCTAssertTrue(reloaded)
        XCTAssertTrue(observed.readBack)
        XCTAssertEqual(observed.minutesBefore, [15, 0])
        XCTAssertEqual(observed.added, [0])
    }

    func testAFailedReloadClaimsNothing() {
        let observed = ReminderRolloverAlarms.observe(before: [15], item: reminder(), reload: { false })
        XCTAssertFalse(observed.readBack)
        XCTAssertEqual(observed.minutesBefore, [])
        XCTAssertEqual(observed.added, [])
        XCTAssertEqual(observed.nextOccurrenceFields["alarms_read_back"] as? Bool, false)
        XCTAssertNil(observed.nextOccurrenceFields["alarms_minutes_offsets"])
        XCTAssertEqual(observed.topLevelFields["alarms_read_back_note"] as? String, ReminderRolloverAlarms.unreadNote)
        XCTAssertNil(observed.topLevelFields["alarms_note"])
    }

    func testTheFields() {
        let added = ReminderRolloverAlarms(readBack: true, minutesBefore: [15, 0], added: [0])
        XCTAssertEqual(added.nextOccurrenceFields["alarms_minutes_offsets"] as? [Double], [15, 0])
        XCTAssertEqual(added.topLevelFields["alarms_note"] as? String, ReminderRolloverAlarms.note(added: [0]))
        let none = ReminderRolloverAlarms(readBack: true, minutesBefore: [15], added: [])
        XCTAssertEqual(none.nextOccurrenceFields["alarms_minutes_offsets"] as? [Double], [15])
        XCTAssertTrue(none.topLevelFields.isEmpty)
    }

    /// The note states only what was measured, and what was not checked.
    func testTheNoteWording() {
        let note = ReminderRolloverAlarms.note(added: [0])
        XCTAssertTrue(note.contains("minutes_before: 0"), note)
        XCTAssertTrue(note.contains("the server wrote no alarm"), note)
        XCTAssertTrue(note.contains("location trigger"), note)
        XCTAssertTrue(note.contains("not checked"), note)
        XCTAssertTrue(note.contains("alarms_minutes_offsets"), note)
        XCTAssertTrue(ReminderRolloverAlarms.note(added: [0, 0]).contains("2 relative alarms"))
        XCTAssertTrue(ReminderRolloverAlarms.unreadNote.contains("could not be re-read"))
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

    /// The store path observes the alarms with a reload, only for a confirmed rollover, and
    /// writes nothing more.
    func testCompleteReminderWiresTheObservation() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager+ReminderCompletion.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        XCTAssertTrue(code.contains("ReminderRolloverAlarms.observe(before: beforeRelativeAlarms, item: reminder, reload: { reminder.refresh() })"), code)
        XCTAssertTrue(code.contains("next.status == .confirmed"), code)
        let body = try XCTUnwrap(SourceScan.body(of: "func completeReminder(identifier: String, completed: Bool = true) async throws -> ReminderCompletionResult {", in: code))
        XCTAssertEqual(body.components(separatedBy: "eventStore.save(").count - 1, 1, "one save, as before")
        XCTAssertFalse(body.contains("addAlarm") || body.contains("removeAlarm"))
    }
}
