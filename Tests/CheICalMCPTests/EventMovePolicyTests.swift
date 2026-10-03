import XCTest
@testable import CheICalMCP

/// #226: the move decisions made 2026-10-04, as a pure function.
/// - Move in place first (keeps recurrence, attendees and every other field).
/// - `span: this` on a recurring event splits the occurrence out (an in-place calendar
///   change on one occurrence moves the whole series — confirmed on device).
/// - Refuse only when the copy path would lose recurrence or attendees.
final class EventMovePolicyTests: XCTestCase {
    private func input(recurring: Bool = false, span: EventMovePolicy.Span = .this,
                       occurrence: Bool = false, attendees: Int = 0) -> EventMovePolicy.Input {
        .init(isRecurring: recurring, span: span, hasOccurrenceDate: occurrence, attendeeCount: attendees)
    }

    // MARK: - Before the write

    func testNonRecurringEventMovesInPlace() {
        XCTAssertEqual(EventMovePolicy.plan(input()), .inPlace)
        XCTAssertEqual(EventMovePolicy.plan(input(span: .all)), .inPlace)
        XCTAssertEqual(EventMovePolicy.plan(input(attendees: 3)), .inPlace)
    }

    func testWholeSeriesMovesInPlace() {
        XCTAssertEqual(EventMovePolicy.plan(input(recurring: true, span: .all)), .inPlace)
        XCTAssertEqual(EventMovePolicy.plan(input(recurring: true, span: .all, attendees: 2)), .inPlace)
    }

    func testOneOccurrenceWithoutItsDateIsRefused() {
        guard case .refuse(let reason) = EventMovePolicy.plan(input(recurring: true)) else {
            return XCTFail("a recurring event without occurrence_date must not move its first occurrence")
        }
        XCTAssertTrue(reason.contains("occurrence_date"))
        XCTAssertTrue(reason.contains("span"))
    }

    func testOneOccurrenceIsSplitOut() {
        XCTAssertEqual(EventMovePolicy.plan(input(recurring: true, occurrence: true)), .split)
    }

    func testOneOccurrenceWithAttendeesIsRefused() {
        guard case .refuse(let reason) = EventMovePolicy.plan(input(recurring: true, occurrence: true, attendees: 1)) else {
            return XCTFail("splitting would drop the attendees")
        }
        XCTAssertTrue(reason.contains("attendees"))
    }

    // MARK: - After an in-place failure

    func testFailedInPlaceMoveFallsBackToCopyWhenNothingWouldBeLost() {
        XCTAssertEqual(EventMovePolicy.afterInPlaceFailure(input()), .copy)
    }

    func testFailedInPlaceMoveOfASeriesIsRefused() {
        guard case .refuse(let reason) = EventMovePolicy.afterInPlaceFailure(input(recurring: true, span: .all)) else {
            return XCTFail("a copy would drop the recurrence")
        }
        XCTAssertTrue(reason.contains("recurrence"))
    }

    func testFailedInPlaceMoveWithAttendeesIsRefused() {
        guard case .refuse(let reason) = EventMovePolicy.afterInPlaceFailure(input(attendees: 2)) else {
            return XCTFail("a copy would drop the attendees")
        }
        XCTAssertTrue(reason.contains("attendees"))
    }

    // MARK: - Span parsing

    func testSpanParsesThisAndAllAndRejectsAnythingElse() throws {
        XCTAssertEqual(try EventMovePolicy.Span.parse(nil), .this)
        XCTAssertEqual(try EventMovePolicy.Span.parse("this"), .this)
        XCTAssertEqual(try EventMovePolicy.Span.parse("all"), .all)
        XCTAssertThrowsError(try EventMovePolicy.Span.parse("future"))
    }
}
