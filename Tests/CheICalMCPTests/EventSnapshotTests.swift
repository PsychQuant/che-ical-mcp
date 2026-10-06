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
    private let store = EKEventStore()
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
}
