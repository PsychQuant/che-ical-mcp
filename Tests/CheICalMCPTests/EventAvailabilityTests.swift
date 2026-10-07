import EventKit
import XCTest
@testable import CheICalMCP

/// #245: an event's availability was not in its undo snapshot, so a delete-undo recreated a free
/// (or tentative, or unavailable) event as busy, the calendar default on iCloud. An in-memory
/// EKEvent ignores `availability` (it stays `.notSupported`), so these tests work on values; the
/// write itself is checked on device.
final class EventAvailabilityTests: XCTestCase {
    private let store = EKEventStore()
    private lazy var calendar = EKCalendar(for: .event, eventStore: store)

    private func snapshot(availability: EKEventAvailability, title: String = "Focus") -> EventSnapshot {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        return EventSnapshot(from: event, availability: availability)
    }

    // MARK: - Record

    func testTheOverrideSetsTheRecordedValue() {
        XCTAssertEqual(snapshot(availability: .free).availability, .free)
    }

    /// Verify round 1, finding 21: an in-memory event reads `.notSupported` whatever is set, so a
    /// value test cannot tell a read from a hard-coded value. Pinned in the source instead: the
    /// snapshot reads the event's availability, and `apply` writes it after the calendar is set
    /// (support depends on the calendar). Checked on device: a free event came back free.
    func testTheSnapshotReadsTheEventsAvailabilityAndWritesItAfterTheCalendar() throws {
        let source = try SourcePins.source("EventKit/UndoManager.swift")
        let initializer = try XCTUnwrap(SourcePins.body(of: "init(from event: EKEvent,", in: source))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"self\.availability\s*=\s*availability\s*\?\?\s*event\.availability\b"#, in: initializer).count, 1,
                       "init(from:) reads the event unless a value is given")
        let apply = try XCTUnwrap(SourcePins.body(of: "func apply(to event: EKEvent, calendar: EKCalendar)", in: source))
        let calendar = try XCTUnwrap(SourcePins.ranges(ofPattern: #"event\.calendar\s*=\s*calendar\b"#, in: apply).first)
        let rule = try XCTUnwrap(SourcePins.ranges(ofPattern: #"availabilityToWrite\(recorded:\s*availability,\s*supported:\s*calendar\.supportedEventAvailabilities"#, in: apply).first)
        let writes = SourcePins.ranges(ofPattern: #"event\.availability\s*=(?!=)"#, in: apply)
        XCTAssertEqual(writes.count, 1, "written in one place")
        XCTAssertLessThan(calendar.lowerBound, rule.lowerBound, "decided after the calendar is set")
        if let write = writes.first { XCTAssertLessThan(rule.lowerBound, write.lowerBound, "written as the rule decided") }
    }

    // MARK: - Write rule

    private let all: EKCalendarEventAvailabilityMask = [.busy, .free, .tentative, .unavailable]

    func testARecordedAvailabilityTheCalendarSupportsIsWritten() {
        XCTAssertEqual(EventSnapshot.availabilityToWrite(recorded: .free, supported: all, current: .busy), .free)
        XCTAssertEqual(EventSnapshot.availabilityToWrite(recorded: .tentative, supported: all, current: .busy), .tentative)
        XCTAssertEqual(EventSnapshot.availabilityToWrite(recorded: .unavailable, supported: [.busy, .unavailable], current: .busy), .unavailable)
        XCTAssertEqual(EventSnapshot.availabilityToWrite(recorded: .busy, supported: [.busy, .free], current: .free), .busy)
    }

    /// The calendar default is left rather than failing the restore.
    func testAValueTheCalendarDoesNotSupportIsNotWritten() {
        XCTAssertNil(EventSnapshot.availabilityToWrite(recorded: .tentative, supported: [.busy, .free], current: .busy))
        XCTAssertNil(EventSnapshot.availabilityToWrite(recorded: .free, supported: [], current: .notSupported))
    }

    func testNothingIsWrittenWhenNothingWasRecordedOrTheValueIsAlreadyThere() {
        XCTAssertNil(EventSnapshot.availabilityToWrite(recorded: .notSupported, supported: all, current: .busy))
        XCTAssertNil(EventSnapshot.availabilityToWrite(recorded: .free, supported: all, current: .free))
    }

    // MARK: - Post-state guard (D1 a)

    /// A create-undo deletes the event, so an availability changed since the create blocks it.
    func testTheGuardComparesAvailability() {
        let created = snapshot(availability: .busy)
        XCTAssertEqual(created.changedFields(in: snapshot(availability: .free), restoring: nil), ["availability"])
        XCTAssertEqual(created.changedFields(in: snapshot(availability: .busy), restoring: nil), [])
    }

    /// An update-undo writes the recorded value back, so a field already at it does not block.
    func testAnAvailabilityAlreadyAtTheRestoredValueDoesNotBlock() {
        let saved = snapshot(availability: .busy)
        XCTAssertEqual(saved.changedFields(in: snapshot(availability: .free), restoring: snapshot(availability: .free)), [])
        XCTAssertEqual(saved.changedFields(in: snapshot(availability: .tentative), restoring: snapshot(availability: .free)),
                       ["availability"])
    }

    /// An occurrence of a created series whose availability was changed on its own is an edit.
    func testAnOccurrenceWithItsOwnAvailabilityDiffersFromTheSeries() {
        let series = snapshot(availability: .busy)
        func face(_ event: EventSnapshot) -> UndoPostState.OccurrenceFace {
            UndoPostState.OccurrenceFace(slot: event.startDate, event: event)
        }
        XCTAssertTrue(UndoPostState.differsFromSeries(face(snapshot(availability: .free)), series: face(series)))
        XCTAssertFalse(UndoPostState.differsFromSeries(face(snapshot(availability: .busy)), series: face(series)))
    }

    /// Verify round 1, findings 4/8/14/16: a store that reports no availability for one side
    /// (occurrence or series) is not taken as an edit, or every create-undo of a series there
    /// would be refused with only discard as the way out. iCloud reports the same value for both
    /// (checked on device 2026-10-07, both directions).
    func testNoAvailabilityOnOneSideIsNotAnEdit() {
        func face(_ event: EventSnapshot) -> UndoPostState.OccurrenceFace {
            UndoPostState.OccurrenceFace(slot: event.startDate, event: event)
        }
        XCTAssertFalse(UndoPostState.differsFromSeries(face(snapshot(availability: .notSupported)), series: face(snapshot(availability: .busy))))
        XCTAssertFalse(UndoPostState.differsFromSeries(face(snapshot(availability: .free)), series: face(snapshot(availability: .notSupported))))
    }
}
