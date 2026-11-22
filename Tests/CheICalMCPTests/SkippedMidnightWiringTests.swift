import XCTest
@testable import CheICalMCP

/// The real store supplies these fields after lookup; in-memory handler fakes supply them directly.
final class SkippedMidnightWiringTests: XCTestCase {
    func testTheRangePreviewTakesTheFlagAndZoneFromTheListedEvent() throws {
        let source = try SourcePins.source("EventBatchDeletionSource.swift")
        let adapter = try XCTUnwrap(source.range(of: "extension EventKitManager: EventBatchDeletionSource"))
        let body = try XCTUnwrap(SourcePins.body(of: "func listEventsForDeletion(", in: String(source[adapter.lowerBound...])))
        XCTAssertTrue(body.contains("isAllDay: $0.isAllDay, timeZone: $0.timeZone"))
    }

    func testTheIdentifierPreviewTakesTheFlagAndZoneFromTheResolvedEvent() throws {
        let source = try SourcePins.source("EventBatchDeletionSource.swift")
        let adapter = try XCTUnwrap(source.range(of: "extension EventKitManager: EventBatchDeletionSource"))
        let body = try XCTUnwrap(SourcePins.body(of: "func previewEventDeletion(", in: String(source[adapter.lowerBound...])))
        XCTAssertTrue(body.contains("isAllDay: event.isAllDay, timeZone: event.timeZone"))
    }

    func testTheUpdateAdapterForwardsTheEndpointThatNeededTheFallback() throws {
        let source = try SourcePins.source("EventWriteSource.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {", in: source))
        XCTAssertTrue(body.contains("skippedMidnightEndpoint: request.skippedMidnightEndpoint"))
    }

    func testUpdatePlanningTakesTheResolvedZoneAndTheEndpointThatNeededTheFallback() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: source))
        XCTAssertEqual(SourcePins.ranges(
            ofPattern: #"AllDayRange\.planUpdate\([^\)]*Calendar\.gregorian\(in: \.current\),\s*storedZone: event\.timeZone,\s*skippedMidnightEndpoint: skippedMidnightEndpoint\)"#,
            in: body).count, 1)
    }

    func testBothCopyPathsCheckTheResolvedSourceBeforeSavingOrRemoving() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let builder = try XCTUnwrap(SourcePins.body(of: "static func makeCopy(", in: source))
        let checkedDates = try XCTUnwrap(SourcePins.ranges(
            ofPattern: #"try AllDayRange\.validateCopy\(start: source\.startDate, end: source\.endDate,\s*isAllDay: source\.isAllDay, eventZone: source\.timeZone,\s*calendar: \.gregorian\(in: \.current\)\)"#,
            in: builder).first)
        let allocated = try XCTUnwrap(builder.range(of: "let copy = EKEvent("))
        XCTAssertLessThan(checkedDates.lowerBound, allocated.lowerBound)

        let copy = try XCTUnwrap(SourcePins.body(of: "func copyEvent(", in: source))
        let checkedCopy = try XCTUnwrap(copy.range(of: "let newEvent = try Self.makeCopy(of: sourceEvent,"))
        let savedCopy = try XCTUnwrap(copy.range(of: "try eventStore.save(newEvent,"))
        XCTAssertLessThan(checkedCopy.lowerBound, savedCopy.lowerBound)

        let move = try XCTUnwrap(SourcePins.body(of: "func moveEvent(", in: source))
        let selected = try XCTUnwrap(move.range(of: "subject = occurrence"))
        let copyOutDeclaration = "let copyOut: (_ isSplit: Bool) throws -> EventMoveExecutor.Copied = {"
        let closure = try XCTUnwrap(SourcePins.body(of: copyOutDeclaration, in: move))
        let copyOut = try XCTUnwrap(move.range(of: copyOutDeclaration))
        XCTAssertLessThan(selected.lowerBound, copyOut.lowerBound)
        let checkedMove = try XCTUnwrap(SourcePins.ranges(
            ofPattern: #"let copy = try Self\.makeCopy\(of: subject,\s*alarms: planned\.alarms,\s*in: targetCalendar,\s*store: self\.eventStore\)"#,
            in: closure).first)
        let savedMove = try XCTUnwrap(closure.range(of: "try self.eventStore.save(copy,"))
        let removed = try XCTUnwrap(closure.range(of: "try self.eventStore.remove(subject,"))
        XCTAssertLessThan(checkedMove.lowerBound, savedMove.lowerBound)
        XCTAssertLessThan(savedMove.lowerBound, removed.lowerBound)
        XCTAssertTrue(move.contains("copy: { try copyOut(false) },"))
        XCTAssertTrue(move.contains("split: { try copyOut(true) }"))
    }
}
