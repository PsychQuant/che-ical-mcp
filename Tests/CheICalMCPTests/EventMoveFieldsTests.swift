import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #226: when a move falls back to copy + delete, the response lists the fields the source
/// had that the copy did not keep — only the ones the source actually had.
final class EventMoveFieldsTests: XCTestCase {
    private let store = EKEventStore()

    private func alarms(_ event: EKEvent) -> Set<AlarmSnapshot> {
        Set((event.alarms ?? []).map(AlarmSnapshot.init(from:)))
    }

    func testPlainEventLosesNothing() {
        let source = EKEvent(eventStore: store)
        source.addAlarm(EKAlarm(relativeOffset: -600))
        XCTAssertEqual(EventKitManager.fieldsNotCarriedOver(from: source, to: EKEvent(eventStore: store)), [])
    }

    /// #230: the copy keeps absolute-date alarms, so only the coordinates are reported.
    func testCoordinatesAreReportedButAbsoluteAlarmsAreNot() {
        let source = EKEvent(eventStore: store)
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        source.structuredLocation = place
        source.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))

        XCTAssertEqual(EventKitManager.fieldsNotCarriedOver(from: source, to: EKEvent(eventStore: store)),
                       ["structured_location"])
    }

    /// An in-memory EKEvent ignores `availability` (it stays `.notSupported`), so the
    /// availability rule is checked on values.
    func testAvailabilityIsReportedOnlyWhenTheCopyDiffers() {
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: false,
                                                  sourceAvailability: .free, copyAvailability: .busy), ["availability"])
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: false,
                                                  sourceAvailability: .busy, copyAvailability: .busy), [])
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: true,
                                                  sourceAvailability: .free, copyAvailability: .busy),
                       ["structured_location", "availability"])
    }

    /// #230: `copy_event` and the fallback copy of `move_events_batch` used to rebuild every
    /// alarm from its offset, so an absolute or location alarm landed at the event start and
    /// an email alarm became a display alarm.
    func testCopyKeepsAbsoluteLocationAndEmailAlarms() {
        let source = EKEvent(eventStore: store)
        source.title = "Review"
        source.startDate = Date(timeIntervalSince1970: 1_800_086_400)
        source.endDate = source.startDate.addingTimeInterval(3600)
        source.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))
        source.addAlarm(EKAlarm(relativeOffset: -900))
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        let location = EKAlarm()
        location.structuredLocation = place
        location.proximity = .leave
        source.addAlarm(location)
        let email = EKAlarm(relativeOffset: -3600)
        email.emailAddress = "owner@example.com"
        source.addAlarm(email)

        let copy = EventKitManager.makeCopy(of: source, in: EKCalendar(for: .event, eventStore: store), store: store)

        XCTAssertEqual(alarms(copy), alarms(source))
        XCTAssertEqual(copy.alarms?.count, 4)
    }

    // MARK: - copy-out alarms (#253 verify round 2, D2)

    /// An occurrence two weeks into a series: it reads the series' absolute alarm, with the
    /// series' date.
    private func occurrence() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.startDate = Date(timeIntervalSince1970: 1_800_086_400 + 14 * 86_400)
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_082_800)))
        event.addAlarm(EKAlarm(relativeOffset: -900))
        return event
    }

    func testSplitCopyPutsAnAbsoluteAlarmAtTheOccurrenceStartAndSaysSo() {
        let subject = occurrence()

        let planned = EventKitManager.copyOutAlarms(of: subject, isSplit: true)
        let copy = EventKitManager.makeCopy(of: subject, alarms: planned.alarms,
                                            in: EKCalendar(for: .event, eventStore: store), store: store)

        XCTAssertEqual((copy.alarms ?? []).compactMap(\.absoluteDate), [])
        XCTAssertEqual(Set((copy.alarms ?? []).map(\.relativeOffset)), [0, -900])
        XCTAssertEqual(planned.notCarriedOver, ["absolute_alarms"])
    }

    /// A fallback copy of a one-off event keeps the absolute date: it is the event's own.
    func testFallbackCopyKeepsAnAbsoluteAlarmsDate() {
        let subject = occurrence()

        let planned = EventKitManager.copyOutAlarms(of: subject, isSplit: false)

        XCTAssertEqual(planned.alarms.compactMap(\.absoluteDate), [Date(timeIntervalSince1970: 1_800_082_800)])
        XCTAssertEqual(planned.notCarriedOver, [])
    }

    /// Undo of a split recreates the occurrence with the alarms the copy was given.
    func testSplitUndoSnapshotUsesTheCopiedAlarms() {
        let subject = occurrence()
        subject.calendar = EKCalendar(for: .event, eventStore: store)
        let planned = EventKitManager.copyOutAlarms(of: subject, isSplit: true)

        let snapshot = EventSnapshot(from: subject, includeRecurrence: false, alarms: planned.alarms)

        XCTAssertEqual(snapshot.alarms, planned.alarms)
    }
}
