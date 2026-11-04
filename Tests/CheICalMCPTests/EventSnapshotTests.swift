import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #230: undo of `update_event` / `delete_event` restores alarms from `EventSnapshot.alarms`
/// through `AlarmSnapshot.restore`. The snapshot used to keep one `relativeOffset` per alarm,
/// so absolute, location and email alarms all came back as plain alarms at the event start.
final class EventSnapshotTests: XCTestCase {
    /// An `EKEvent` whose store was deallocated reads back no alarms, so the store lives
    /// as long as the test.
    private var store: EKEventStore { SharedTestStore.store }
    private let absoluteDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = "Review"
        event.startDate = absoluteDate.addingTimeInterval(86_400)
        event.endDate = event.startDate.addingTimeInterval(3600)
        return event
    }

    private func eventWithEveryKindOfAlarm() -> EKEvent {
        let event = makeEvent()
        event.addAlarm(EKAlarm(absoluteDate: absoluteDate))
        event.addAlarm(EKAlarm(relativeOffset: -900))
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        place.radius = 150
        let location = EKAlarm()
        location.structuredLocation = place
        location.proximity = .enter
        event.addAlarm(location)
        let email = EKAlarm(relativeOffset: -3600)
        email.emailAddress = "owner@example.com"
        event.addAlarm(email)
        return event
    }

    private func alarms(_ event: EKEvent) -> Set<AlarmSnapshot> {
        Set((event.alarms ?? []).map(AlarmSnapshot.init(from:)))
    }

    func testSnapshotKeepsAbsoluteLocationAndEmailAlarmsDistinct() {
        let snapshot = EventSnapshot(from: eventWithEveryKindOfAlarm())

        XCTAssertEqual(snapshot.alarms.count, 4)
        XCTAssertEqual(snapshot.alarms.compactMap(\.absoluteDate), [absoluteDate])
        XCTAssertEqual(snapshot.alarms.compactMap(\.location?.title), ["Office"])
        XCTAssertEqual(snapshot.alarms.compactMap(\.emailAddress), ["owner@example.com"])
    }

    /// Delete-undo recreates the event from the snapshot.
    func testRestoringOnANewEventRecreatesEveryAlarm() {
        let original = eventWithEveryKindOfAlarm()
        let snapshot = EventSnapshot(from: original)
        let recreated = makeEvent()

        AlarmSnapshot.restore(snapshot.alarms, to: recreated)

        XCTAssertEqual(alarms(recreated), alarms(original))
    }

    /// Update-undo after a change that did not touch the alarms leaves them alone.
    func testRestoringUnchangedAlarmsWritesNothing() {
        let event = eventWithEveryKindOfAlarm()
        let snapshot = EventSnapshot(from: event)
        event.title = "Renamed"

        XCTAssertFalse(AlarmSnapshot.restore(snapshot.alarms, to: event))
        XCTAssertEqual(alarms(event), Set(snapshot.alarms))
    }

    // MARK: - apply (#253 verify #4)

    /// Update-undo writes the snapshot back through `EventSnapshot.apply`, the same path
    /// `applySnapshot` takes; before, only `AlarmSnapshot.restore` was tested, so dropping the
    /// alarm write from the undo path left the suite green.
    func testApplyRestoresTheFieldsAndAlarmsOfAnUpdatedEvent() {
        let event = eventWithEveryKindOfAlarm()
        let snapshot = EventSnapshot(from: event)
        event.title = "Renamed"
        event.alarms?.forEach(event.removeAlarm)
        event.addAlarm(EKAlarm(relativeOffset: 0))

        snapshot.apply(to: event, calendar: event.calendar)

        XCTAssertEqual(event.title, "Review")
        XCTAssertEqual(event.alarms?.count, 4)
        XCTAssertEqual(alarms(event), Set(snapshot.alarms))
    }

    /// Delete-undo applies the snapshot to a new event.
    func testApplyOnANewEventRecreatesEveryAlarm() {
        let original = eventWithEveryKindOfAlarm()
        let snapshot = EventSnapshot(from: original)
        let recreated = EKEvent(eventStore: store)
        let calendar = EKCalendar(for: .event, eventStore: store)

        snapshot.apply(to: recreated, calendar: calendar)

        XCTAssertTrue(recreated.calendar === calendar)
        XCTAssertEqual(recreated.startDate, original.startDate)
        XCTAssertEqual(alarms(recreated), alarms(original))
    }

    func testApplyLeavesUnchangedAlarmObjectsInPlace() {
        let event = eventWithEveryKindOfAlarm()
        let before = event.alarms ?? []
        let snapshot = EventSnapshot(from: event)
        event.title = "Renamed"

        snapshot.apply(to: event, calendar: event.calendar)

        XCTAssertEqual(event.alarms?.count, before.count)
        XCTAssertTrue(before.allSatisfy { kept in event.alarms?.contains { $0 === kept } ?? false })
    }

    func testEventWithoutAlarmsRecordsNone() {
        XCTAssertEqual(EventSnapshot(from: makeEvent()).alarms, [])
    }

    // MARK: - An event without a calendar (#286)

    /// `EKEvent.calendar` is implicitly unwrapped. The snapshot read it directly and trapped while
    /// the undo record of a calendar-less event was built; the reminder side has been nil-safe
    /// since PR #277. The event is recorded with an empty identifier instead.
    func testAnEventWithoutACalendarIsRecordedWithAnEmptyIdentifier() {
        let event = EKEvent(eventStore: store)
        event.title = "Review"
        event.startDate = absoluteDate
        event.endDate = absoluteDate.addingTimeInterval(3600)
        XCTAssertNil(event.calendar as EKCalendar?, "the fixture must have no calendar")

        let snapshot = EventSnapshot(from: event)

        XCTAssertEqual(snapshot.calendarIdentifier, "")
        XCTAssertEqual(snapshot.calendarTitle, "")
        XCTAssertNil(snapshot.calendarSource)
        XCTAssertEqual(snapshot.title, "Review")
    }

    /// Its undo is refused like any other missing destination: an empty identifier matches no
    /// calendar, not even one whose identifier is empty too. Since #269 the refusal is
    /// `undoCalendarMissing` with the no-identifier wording: no retry, blocked until given up.
    func testTheUndoOfAnEventWithoutACalendarIsRefusedAsRecordedWithoutAnIdentifier() throws {
        let event = EKEvent(eventStore: store)
        event.title = "Review"
        event.startDate = absoluteDate
        event.endDate = absoluteDate.addingTimeInterval(3600)
        let snapshot = EventSnapshot(from: event)

        for kind in [EventRestoreKind.recreateDeleted, .recreateDeletedOccurrence, .revertUpdate] {
            XCTAssertThrowsError(try snapshot.resolveCalendar(in: [(id: "work", title: "Work"), (id: "", title: "")],
                                                              identifier: { $0.id }, for: kind)) { error in
                guard case EventKitError.undoCalendarMissing(let shown, let hasIdentifier, let thrownKind) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(shown, "Review")
                XCTAssertFalse(hasIdentifier)
                XCTAssertEqual(thrownKind, kind)
                let text = (error as? EventKitError)?.errorDescription ?? ""
                XCTAssertTrue(text.contains("was recorded without an identifier, so it cannot be found."), text)
                XCTAssertTrue(text.contains("until it is given up."), text)
                XCTAssertFalse(text.contains("Run undo again"), text)
                XCTAssertFalse(text.contains("is not available"), text)
            }
        }
    }

    /// A revert of the fix traps the test process in the value test above, which reads as a crash
    /// rather than a named failure, so this also pins the source: `EventSnapshot.init(from:)`
    /// reads the calendar through an optional only. It reads the source text (comments removed,
    /// whitespace collapsed), so it guards against a revert; renaming the parameter `event`
    /// turns it red with the behaviour unchanged, and the expected text needs updating then.
    func testTheSnapshotReadsTheCalendarThroughAnOptional() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/UndoManager.swift")
        let code = SourceScan.collapsingWhitespace(
            SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        let start = try XCTUnwrap(code.range(of: "init(from event: EKEvent,"))
        let end = try XCTUnwrap(code.range(of: "func resolveCalendar<T>(", range: start.upperBound..<code.endIndex))
        let body = String(code[start.upperBound..<end.lowerBound])

        XCTAssertFalse(body.contains("event.calendar."), body)
        XCTAssertTrue(body.contains("self.calendarIdentifier = event.calendar?.calendarIdentifier ?? \"\""), body)
        XCTAssertTrue(body.contains("self.calendarTitle = event.calendar?.title ?? \"\""), body)
        XCTAssertTrue(body.contains("self.calendarSource = event.calendar?.source?.title"), body)
    }
}
