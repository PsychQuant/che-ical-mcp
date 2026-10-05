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

    // MARK: - split (#253 verify #1)

    private let seriesStart = Date(timeIntervalSince1970: 1_800_086_400)

    private func series() -> EKEvent {
        let master = EKEvent(eventStore: store)
        master.startDate = seriesStart
        master.endDate = seriesStart.addingTimeInterval(3600)
        master.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        return master
    }

    /// An occurrence two weeks in: it reads the series' alarm, with the series' date.
    private func occurrence() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.startDate = seriesStart.addingTimeInterval(14 * 86_400)
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.addAlarm(EKAlarm(absoluteDate: seriesStart.addingTimeInterval(-3600)))
        event.addAlarm(EKAlarm(relativeOffset: -900))
        return event
    }

    func testSplitCopyMovesAnAbsoluteAlarmWithTheOccurrence() {
        let subject = occurrence()

        let split = EventKitManager.splitAlarms(of: subject, series: series())
        let copy = EventKitManager.makeCopy(of: subject, alarms: split.alarms,
                                            in: EKCalendar(for: .event, eventStore: store), store: store)

        XCTAssertEqual(Set((copy.alarms ?? []).compactMap(\.absoluteDate)), [subject.startDate.addingTimeInterval(-3600)])
        XCTAssertEqual(copy.alarms?.count, 2)
        XCTAssertEqual(split.notCarriedOver, [])
    }

    /// The series start is the start of the event fetched by identifier only while that
    /// event still carries the rule.
    func testSplitWithoutARecurringSeriesFallsBackAndReportsAbsoluteAlarms() {
        let notASeries = EKEvent(eventStore: store)
        notASeries.startDate = seriesStart
        notASeries.endDate = seriesStart.addingTimeInterval(3600)

        let split = EventKitManager.splitAlarms(of: occurrence(), series: notASeries)

        XCTAssertEqual(split.alarms.compactMap(\.absoluteDate), [])
        XCTAssertEqual(split.notCarriedOver, ["absolute_alarms"])
    }

    /// The undo record of a split recreates the occurrence; its alarms follow the same rule.
    func testSplitUndoSnapshotUsesTheSplitAlarms() {
        let subject = occurrence()
        subject.calendar = EKCalendar(for: .event, eventStore: store)
        let split = EventKitManager.splitAlarms(of: subject, series: series())

        let snapshot = EventSnapshot(from: subject, includeRecurrence: false, alarms: split.alarms)

        XCTAssertEqual(snapshot.alarms, split.alarms)
    }
}
