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
}
