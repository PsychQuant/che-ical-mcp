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

    /// #272: a copy keeps the source's availability when the target calendar supports it, so
    /// the copy's value equals the source's and nothing is listed; a target that does not
    /// support it keeps its default, and the difference is listed.
    func testAvailabilityTheCopyKeptIsNotListed() {
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: false,
                                                  sourceAvailability: .free, copyAvailability: .free), [])
        XCTAssertEqual(EventKitManager.lostFields(hasCoordinates: false,
                                                  sourceAvailability: .tentative, copyAvailability: .tentative), [])
    }

    /// #272: `makeCopy` writes availability with #245's rule, after the calendar is set (support
    /// depends on the calendar), and only as the rule decided. An in-memory event ignores
    /// `availability`, so the wiring is pinned in the source; the write was checked on device.
    func testMakeCopyWritesAvailabilityAfterTheCalendarWithTheSupportRule() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "static func makeCopy(of source: EKEvent,", in: source))
        let calendar = try XCTUnwrap(SourcePins.ranges(ofPattern: #"copy\.calendar\s*=\s*calendar\b"#, in: body).first)
        let rule = try XCTUnwrap(SourcePins.ranges(ofPattern: #"EventSnapshot\.availabilityToWrite\(recorded:\s*source\.availability,\s*supported:\s*calendar\.supportedEventAvailabilities,\s*current:\s*copy\.availability\)"#, in: body).first)
        let writes = SourcePins.ranges(ofPattern: #"copy\.availability\s*=(?!=)"#, in: body)
        XCTAssertEqual(writes.count, 1, "written in one place")
        XCTAssertLessThan(calendar.lowerBound, rule.lowerBound, "decided after the calendar is set")
        if let write = writes.first { XCTAssertLessThan(rule.lowerBound, write.lowerBound, "written as the rule decided") }
    }

    /// #272: a plain `copy_event` reports what the saved copy did not keep, with the same rule as
    /// the move paths (`fieldsNotCarriedOver`), read after the save.
    func testPlainCopyReportsTheFieldsTheCopyDidNotKeep() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func copyEvent(", in: source))
        let save = try XCTUnwrap(body.range(of: "try eventStore.save(newEvent, span: .thisEvent)"))
        let report = try XCTUnwrap(body.range(of: "Self.fieldsNotCarriedOver(from: sourceEvent, to: newEvent)"))
        XCTAssertLessThan(save.lowerBound, report.lowerBound)
        let wiring = try XCTUnwrap(SourcePins.body(of: "func copyEventValue(", in: try SourcePins.source("EventCopySource.swift")))
        XCTAssertTrue(wiring.contains("notCarriedOver: copied.notCarriedOver"))
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
