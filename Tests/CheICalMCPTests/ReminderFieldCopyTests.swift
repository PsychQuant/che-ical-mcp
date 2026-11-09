import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #459: what a write of an existing reminder or list copies onto the write store's object. Only
/// the fields this call changed are written (PR #507 round 1): the change is found by comparing the
/// caller's object with what it held before the call (`rollback()`), never with the write store's
/// copy, whose untouched fields may be newer. In-memory items on the shared test store (#283).
final class ReminderFieldCopyTests: XCTestCase {
    private let store = SharedTestStore.store

    private func list(_ title: String) -> EKCalendar {
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = title
        return c
    }

    private func reminder(in calendar: EKCalendar) -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.calendar = calendar
        return r
    }

    private func due(_ day: Int, hour: Int? = 9) -> DateComponents {
        var c = DateComponents(); c.year = 2027; c.month = 3; c.day = day; c.hour = hour; c.minute = hour == nil ? nil : 0
        c.timeZone = TimeZone(identifier: "Asia/Taipei")
        return c
    }

    private typealias Values = ReminderFieldCopy.Values

    func testTheFieldListIsClosed() {
        XCTAssertEqual(ReminderFieldCopy.fields, ["title", "location", "notes", "url", "timeZone", "startDateComponents",
                                                  "dueDateComponents", "priority", "isCompleted", "completionDate",
                                                  "alarms", "recurrenceRules", "calendar"])
        XCTAssertEqual(ListFieldCopy.fields, ["title", "cgColor"])
    }

    /// The round-1 HIGH root: an untouched field whose stored value is newer than the caller's
    /// cached one is never written back.
    func testOnlyTheFieldsTheCallChangedAreWritten() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.title = "old title"; cached.notes = "old notes"
        let before = Values(cached)
        cached.notes = "new notes"
        let wanted = Values(cached)
        let changed = ReminderFieldCopy.changed(from: before, to: wanted)
        XCTAssertEqual(changed, [.notes])

        let stored = reminder(in: a)
        stored.title = "renamed elsewhere"; stored.notes = "old notes"
        try ReminderFieldCopy.apply(wanted, fields: changed, to: stored, calendar: { _ in a })
        XCTAssertEqual(stored.title, "renamed elsewhere", "an untouched field keeps its stored value")
        XCTAssertEqual(stored.notes, "new notes")
    }

    func testEveryScalarFieldIsWrittenWhenChanged() throws {
        let a = list("A"), b = list("B")
        let cached = reminder(in: a)
        let before = Values(cached)
        cached.title = "new title"; cached.location = "Room 1"; cached.notes = "n"
        cached.url = URL(string: "https://example.invalid/x")
        cached.priority = 1
        cached.isCompleted = true
        let done = Date(timeIntervalSince1970: 1_800_000_000)
        cached.completionDate = done
        cached.calendar = b
        let wanted = Values(cached)
        let target = reminder(in: a)
        try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: target,
                                    calendar: { $0 == b.calendarIdentifier ? b : nil })
        XCTAssertEqual(target.title, "new title")
        XCTAssertEqual(target.location, "Room 1")
        XCTAssertEqual(target.notes, "n")
        XCTAssertEqual(target.url, cached.url)
        XCTAssertEqual(target.priority, 1)
        XCTAssertTrue(target.isCompleted)
        XCTAssertEqual(target.completionDate, done)
        XCTAssertTrue(target.calendar === b, "the list is looked up on the write store by identifier")
    }

    func testClearedValuesAreCleared() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.notes = "old"; cached.location = "old"
        let before = Values(cached)
        cached.notes = nil; cached.location = nil
        let target = reminder(in: a)
        target.notes = "old"; target.location = "old"
        let wanted = Values(cached)
        try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: target, calendar: { _ in a })
        XCTAssertNil(target.notes)
        XCTAssertTrue(target.location == nil || target.location == "")
    }

    /// Round-1 MEDIUM 4, the update-undo arm: the stored reminder has start == due from the update,
    /// and the undo restores no start and the old due. Written in `ReminderDateSync.restore`'s order,
    /// the absent start is cleared after the due, so EventKit's start = due does not stay.
    func testAStartEqualToTheDueIsClearedAfterTheDue() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.startDateComponents = due(12); cached.dueDateComponents = due(12)
        let before = Values(cached)
        // As `ReminderSnapshot.apply` writes it: assigned in the other order, EventKit would give
        // the caller's object start = due too.
        ReminderDateSync.restore(cached, start: nil, due: due(10))
        XCTAssertNil(cached.startDateComponents)
        let wanted = Values(cached)
        let target = reminder(in: a)
        target.startDateComponents = due(12); target.dueDateComponents = due(12)
        let fields = ReminderFieldCopy.changed(from: before, to: wanted)
        XCTAssertTrue(fields.isSuperset(of: [.startDateComponents, .dueDateComponents]))
        try ReminderFieldCopy.apply(wanted, fields: fields, to: target, calendar: { _ in a })
        XCTAssertNil(target.startDateComponents)
        XCTAssertEqual(target.dueDateComponents?.day, 10)
    }

    /// Only the due changed: the start written with it is the stored one, not the cached one.
    func testADueChangeKeepsTheStoredStart() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.startDateComponents = due(1); cached.dueDateComponents = due(10)
        let before = Values(cached)
        cached.dueDateComponents = due(11)
        let wanted = Values(cached)
        let target = reminder(in: a)
        target.startDateComponents = due(3); target.dueDateComponents = due(10)
        try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: target, calendar: { _ in a })
        XCTAssertEqual(target.dueDateComponents?.day, 11)
        XCTAssertEqual(target.startDateComponents?.day, 3, "the start the call did not touch is the stored one")
    }

    /// Round-1 MEDIUM 2 and 5: alarms go through `AlarmSnapshot.restore` against the target's own
    /// alarms, so an alarm equal to a wanted one stays the same object (what no snapshot rebuilds, a
    /// procedure alarm's URL, survives; `EKAlarm.url` cannot be set from Swift on macOS, so object
    /// identity stands in for it), and no alarm object of the long-lived store is put on the target.
    func testAlarmsGoThroughTheMultisetRestore() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.addAlarm(EKAlarm(relativeOffset: -900)); cached.addAlarm(EKAlarm(relativeOffset: -60))
        let before = Values(cached)
        for alarm in cached.alarms ?? [] where alarm.relativeOffset == -60 { cached.removeAlarm(alarm) }
        let place = EKStructuredLocation(title: "Place")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.56)
        place.radius = 150
        let geo = EKAlarm(); geo.structuredLocation = place; geo.proximity = .leave
        cached.addAlarm(geo)
        let wanted = Values(cached)
        XCTAssertEqual(ReminderFieldCopy.changed(from: before, to: wanted), [.alarms])

        let target = reminder(in: a)
        let kept = EKAlarm(relativeOffset: -900)   // stands in for a procedure alarm with a URL
        target.addAlarm(kept); target.addAlarm(EKAlarm(relativeOffset: -60))
        try ReminderFieldCopy.apply(wanted, fields: [.alarms], to: target, calendar: { _ in a })
        let alarms = try XCTUnwrap(target.alarms)
        XCTAssertEqual(alarms.count, 2)
        XCTAssertTrue(alarms.contains { $0 === kept }, "the unchanged alarm stays the same object")
        XCTAssertFalse(alarms.contains { $0 === geo }, "no alarm object of the caller's store is put on the target")
        XCTAssertEqual(alarms.first { $0.structuredLocation != nil }?.proximity, .leave)
    }

    func testEqualAlarmsAndRulesAreNotFieldsThatChanged() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.dueDateComponents = due(10)
        cached.addAlarm(EKAlarm(relativeOffset: -900))
        cached.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        let before = Values(cached)
        cached.title = "only the title"
        XCTAssertEqual(ReminderFieldCopy.changed(from: before, to: Values(cached)), [.title])
    }

    func testRulesAreCopiedAsNewObjectsWithTheSameValues() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.dueDateComponents = due(10)
        let before = Values(cached)
        let days = [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.thursday)]
        cached.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, daysOfTheWeek: days, daysOfTheMonth: nil,
                                                  monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                                  end: EKRecurrenceEnd(occurrenceCount: 5)))
        let wanted = Values(cached)
        let target = reminder(in: a)
        target.dueDateComponents = due(10)
        try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: target, calendar: { _ in a })
        let rule = try XCTUnwrap(target.recurrenceRules?.first)
        XCTAssertFalse(rule === cached.recurrenceRules?.first)
        XCTAssertEqual(ReminderFieldCopy.ruleSignature(rule), ReminderFieldCopy.ruleSignature(try XCTUnwrap(cached.recurrenceRules?.first)))
        XCTAssertEqual(rule.recurrenceEnd?.occurrenceCount, 5)
        XCTAssertEqual(rule.interval, 2)
    }

    func testARemovedRuleIsRemoved() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.dueDateComponents = due(10)
        cached.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let before = Values(cached)
        for rule in cached.recurrenceRules ?? [] { cached.removeRecurrenceRule(rule) }
        let target = reminder(in: a)
        target.dueDateComponents = due(10)
        target.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let wanted = Values(cached)
        try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: target, calendar: { _ in a })
        XCTAssertTrue(target.recurrenceRules?.isEmpty ?? true)
    }

    func testAListTheWriteStoreCannotSeeIsAStoreErrorAndNothingIsCopied() {
        let a = list("A"), b = list("B")
        let cached = reminder(in: a)
        let before = Values(cached)
        cached.calendar = b; cached.title = "changed"
        let target = reminder(in: a)
        let wanted = Values(cached)
        XCTAssertThrowsError(try ReminderFieldCopy.apply(wanted, fields: ReminderFieldCopy.changed(from: before, to: wanted), to: target,
                                                          calendar: { _ in nil })) { error in
            guard case .writeStoreLookupFailed(let kind) = error as? EventKitError else { return XCTFail("\(error)") }
            XCTAssertEqual(kind, "reminder list")
        }
        XCTAssertNotEqual(target.title, "changed", "the lookup comes first, before any field is written")
    }

    /// Round-1 MEDIUM 6: a rename writes the title only; a color changed elsewhere survives.
    func testAListWritesOnlyTheFieldThatChanged() {
        let cached = list("Old name")
        cached.cgColor = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let before = ListFieldCopy.Values(cached)
        cached.title = "New name"
        let wanted = ListFieldCopy.Values(cached)
        let stored = list("Old name")
        stored.cgColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        ListFieldCopy.apply(wanted, fields: ListFieldCopy.changed(from: before, to: wanted), to: stored)
        XCTAssertEqual(stored.title, "New name")
        XCTAssertEqual(stored.cgColor, CGColor(red: 1, green: 0, blue: 0, alpha: 1), "the color changed elsewhere is kept")
    }

    // MARK: - PR #507 round 2: a field the request names is always written

    /// A/B/A: the cache holds A, another store wrote B, the request sets A again. Taken only from
    /// the difference, the title would not be written and B would stay; named by the request, A is.
    func testATitleTheRequestNamesIsWrittenEvenWhenTheCacheAlreadyHoldsIt() throws {
        let a = list("A")
        let cached = reminder(in: a)
        cached.title = "A"; cached.notes = "cached notes"
        let before = Values(cached)
        cached.title = "A"
        let wanted = Values(cached)
        XCTAssertTrue(ReminderFieldCopy.changed(from: before, to: wanted).isEmpty)
        let stored = reminder(in: a)
        stored.title = "B"; stored.notes = "notes changed elsewhere"
        let fields = ReminderFieldCopy.changed(from: before, to: wanted).union([.title])
        try ReminderFieldCopy.apply(wanted, fields: fields, to: stored, calendar: { _ in a })
        XCTAssertEqual(stored.title, "A")
        XCTAssertEqual(stored.notes, "notes changed elsewhere", "a field the request does not name keeps the stored value")
    }

    /// The same for a list's color.
    func testAColorTheRequestNamesIsWrittenEvenWhenTheCacheAlreadyHoldsIt() {
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1), red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let cached = list("Name")
        cached.cgColor = blue
        let before = ListFieldCopy.Values(cached)
        cached.cgColor = blue
        let wanted = ListFieldCopy.Values(cached)
        let stored = list("Renamed elsewhere")
        stored.cgColor = red
        ListFieldCopy.apply(wanted, fields: ListFieldCopy.changed(from: before, to: wanted).union([.cgColor]), to: stored)
        XCTAssertEqual(stored.cgColor, blue)
        XCTAssertEqual(stored.title, "Renamed elsewhere")
    }

    /// What `update_reminder` names, by the fields each argument writes or derives.
    func testTheFieldsAnUpdateRequestNames() {
        func named(_ r: ReminderUpdateRequest) -> Set<ReminderFieldCopy.Field> { ReminderUpdateWrite.requestedFields(r) }
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r")), [])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", title: "t")), [.title])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", notes: "n")), [.notes])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", priority: 1)), [.priority])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", calendarName: "L")), [.calendar])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", due: .day(DateComponents(year: 2027, month: 3, day: 1)))),
                       [.dueDateComponents, .startDateComponents, .timeZone, .alarms])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", clearDueDate: true)), [.dueDateComponents, .startDateComponents, .timeZone, .alarms])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", realignToDue: true)), [.startDateComponents, .alarms])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", alarmOffsets: [15])), [.alarms])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", clearLocationTrigger: true)), [.alarms])
        XCTAssertEqual(named(ReminderUpdateRequest(identifier: "r", clearRecurrence: true)), [.recurrenceRules])
    }

    func testACompletionNamesItsTwoFields() {
        XCTAssertEqual(ReminderCompletionWrite.requestedFields, [.isCompleted, .completionDate])
    }
}
