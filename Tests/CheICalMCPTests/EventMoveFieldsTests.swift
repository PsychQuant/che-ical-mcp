import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #226: when a move falls back to copy + delete, the response lists the fields the source
/// had that the copy did not keep — only the ones the source actually had.
final class EventMoveFieldsTests: XCTestCase {
    private let store = EKEventStore()

    func testPlainEventLosesNothing() {
        let source = EKEvent(eventStore: store)
        source.addAlarm(EKAlarm(relativeOffset: -600))
        XCTAssertEqual(EventKitManager.fieldsNotCarriedOver(from: source, to: EKEvent(eventStore: store)), [])
    }

    func testCoordinatesAndAbsoluteAlarmsAreReported() {
        let source = EKEvent(eventStore: store)
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        source.structuredLocation = place
        source.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))

        XCTAssertEqual(EventKitManager.fieldsNotCarriedOver(from: source, to: EKEvent(eventStore: store)),
                       ["structured_location", "absolute_alarms"])
    }

    /// An in-memory EKEvent ignores `availability` (it stays `.notSupported`), so the
    /// availability rule is checked on values.
    func testAvailabilityIsReportedOnlyWhenTheCopyDiffers() {
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: false, hasAbsoluteAlarm: false,
                                                  sourceAvailability: .free, copyAvailability: .busy), ["availability"])
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: false, hasAbsoluteAlarm: false,
                                                  sourceAvailability: .busy, copyAvailability: .busy), [])
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: true, hasAbsoluteAlarm: true,
                                                  sourceAvailability: .free, copyAvailability: .busy),
                       ["structured_location", "absolute_alarms", "availability"])
    }
}
