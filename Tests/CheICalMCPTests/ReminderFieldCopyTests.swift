import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #459: the fields a write of an existing reminder or list copies onto the write store's object.
/// In-memory items on the shared test store (#283); nothing is fetched or saved.
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

    func testTheFieldListIsClosed() {
        XCTAssertEqual(ReminderFieldCopy.fields, ["title", "location", "notes", "url", "timeZone", "startDateComponents",
                                                  "dueDateComponents", "priority", "isCompleted", "completionDate",
                                                  "alarms", "recurrenceRules", "calendar"])
        XCTAssertEqual(ListFieldCopy.fields, ["title", "cgColor"])
    }

    func testEveryScalarFieldIsCopied() throws {
        let a = list("A"), b = list("B")
        let source = reminder(in: b), target = reminder(in: a)
        source.title = "new title"; source.location = "Room 1"; source.notes = "n"
        source.url = URL(string: "https://example.invalid/x")
        source.timeZone = TimeZone(identifier: "Asia/Tokyo")
        source.startDateComponents = due(1); source.dueDateComponents = due(10)
        source.priority = 1
        source.isCompleted = true
        let done = Date(timeIntervalSince1970: 1_800_000_000)
        source.completionDate = done
        try ReminderFieldCopy.apply(from: source, to: target, calendar: { $0 == b.calendarIdentifier ? b : nil })
        XCTAssertEqual(target.title, "new title")
        XCTAssertEqual(target.location, "Room 1")
        XCTAssertEqual(target.notes, "n")
        XCTAssertEqual(target.url, source.url)
        XCTAssertEqual(target.timeZone, source.timeZone)
        XCTAssertEqual(target.startDateComponents, source.startDateComponents)
        XCTAssertEqual(target.dueDateComponents, source.dueDateComponents)
        XCTAssertEqual(target.priority, 1)
        XCTAssertTrue(target.isCompleted)
        XCTAssertEqual(target.completionDate, done)
        XCTAssertTrue(target.calendar === b, "the list is looked up on the write store by identifier")
    }

    func testClearedValuesAreCleared() throws {
        let a = list("A")
        let source = reminder(in: a), target = reminder(in: a)
        target.notes = "old"; target.dueDateComponents = due(10); target.location = "old"
        source.notes = nil; source.dueDateComponents = nil; source.location = nil
        try ReminderFieldCopy.apply(from: source, to: target, calendar: { _ in a })
        XCTAssertNil(target.notes)
        XCTAssertNil(target.dueDateComponents)
        XCTAssertTrue(target.location == nil || target.location == "")
    }

    func testAlarmsAreCopiedAsNewObjectsWithTheSameValues() throws {
        let a = list("A")
        let source = reminder(in: a), target = reminder(in: a)
        source.addAlarm(EKAlarm(relativeOffset: -900))
        source.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))
        let place = EKStructuredLocation(title: "Place")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.56)
        place.radius = 150
        let geo = EKAlarm(); geo.structuredLocation = place; geo.proximity = .leave
        source.addAlarm(geo)
        try ReminderFieldCopy.apply(from: source, to: target, calendar: { _ in a })
        let copied = try XCTUnwrap(target.alarms)
        XCTAssertEqual(copied.map(ReminderFieldCopy.alarmSignature).sorted(), try XCTUnwrap(source.alarms).map(ReminderFieldCopy.alarmSignature).sorted())
        for c in copied {
            XCTAssertFalse(try XCTUnwrap(source.alarms).contains { $0 === c }, "an alarm object of the long-lived store is never put on the write store's object")
        }
        let copiedGeo = try XCTUnwrap(copied.first { $0.structuredLocation != nil })
        XCTAssertEqual(copiedGeo.proximity, .leave)
        XCTAssertEqual(copiedGeo.structuredLocation?.radius, 150)
    }

    func testEqualAlarmsAndRulesAreLeftAsTheyAre() throws {
        let a = list("A")
        let source = reminder(in: a), target = reminder(in: a)
        source.addAlarm(EKAlarm(relativeOffset: -900)); target.addAlarm(EKAlarm(relativeOffset: -900))
        source.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        target.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        source.dueDateComponents = due(10); target.dueDateComponents = due(10)
        let alarmBefore = try XCTUnwrap(target.alarms?.first)
        let ruleBefore = try XCTUnwrap(target.recurrenceRules?.first)
        try ReminderFieldCopy.apply(from: source, to: target, calendar: { _ in a })
        XCTAssertTrue(target.alarms?.first === alarmBefore)
        XCTAssertTrue(target.recurrenceRules?.first === ruleBefore)
    }

    func testRulesAreCopiedAsNewObjectsWithTheSameValues() throws {
        let a = list("A")
        let source = reminder(in: a), target = reminder(in: a)
        source.dueDateComponents = due(10); target.dueDateComponents = due(10)
        let days = [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.thursday)]
        source.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, daysOfTheWeek: days, daysOfTheMonth: nil,
                                                  monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                                  end: EKRecurrenceEnd(occurrenceCount: 5)))
        try ReminderFieldCopy.apply(from: source, to: target, calendar: { _ in a })
        let rule = try XCTUnwrap(target.recurrenceRules?.first)
        XCTAssertFalse(rule === source.recurrenceRules?.first)
        XCTAssertEqual(ReminderFieldCopy.ruleSignature(rule), ReminderFieldCopy.ruleSignature(try XCTUnwrap(source.recurrenceRules?.first)))
        XCTAssertEqual(rule.recurrenceEnd?.occurrenceCount, 5)
        XCTAssertEqual(rule.interval, 2)
    }

    func testARemovedRuleIsRemoved() throws {
        let a = list("A")
        let source = reminder(in: a), target = reminder(in: a)
        target.dueDateComponents = due(10); source.dueDateComponents = due(10)
        target.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        try ReminderFieldCopy.apply(from: source, to: target, calendar: { _ in a })
        XCTAssertTrue(target.recurrenceRules?.isEmpty ?? true)
    }

    func testAListTheWriteStoreCannotSeeIsAStoreErrorAndNothingIsCopied() {
        let a = list("A"), b = list("B")
        let source = reminder(in: b), target = reminder(in: a)
        source.title = "changed"
        XCTAssertThrowsError(try ReminderFieldCopy.apply(from: source, to: target, calendar: { _ in nil })) { error in
            guard case .writeStoreLookupFailed(let kind) = error as? EventKitError else { return XCTFail("\(error)") }
            XCTAssertEqual(kind, "reminder list")
        }
        XCTAssertNotEqual(target.title, "changed", "the lookup comes first, before any field is written")
    }

    func testAListCopiesItsTitleAndColor() {
        let source = list("New name"), target = list("Old name")
        source.cgColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        ListFieldCopy.apply(from: source, to: target)
        XCTAssertEqual(target.title, "New name")
        XCTAssertEqual(target.cgColor, source.cgColor)
    }
}
