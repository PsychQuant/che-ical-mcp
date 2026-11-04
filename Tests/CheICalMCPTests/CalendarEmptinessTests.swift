import XCTest
@testable import CheICalMCP

/// #328: `delete_calendar` with `require_empty` checks the calendar first. Events are searched over
/// a stated window, span by span (`EventRangeQuery`), and the search stops at the first span that
/// holds any; a reminder list is counted whole. Closures stand in for EventKit.
final class CalendarEmptinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    func testTheWindowIsCenteredOnNowAndFitsTheSpanCeiling() throws {
        let window = CalendarEmptiness.window(now: now)
        XCTAssertEqual(window.start, now.addingTimeInterval(-Double(CalendarEmptiness.windowDaysEachSide) * day))
        XCTAssertEqual(window.end, now.addingTimeInterval(Double(CalendarEmptiness.windowDaysEachSide) * day))
        XCTAssertEqual(try EventRangeQuery.spans(from: window.start, to: window.end).count, EventRangeQuery.maxSpans)
    }

    func testAnEmptyCalendarIsSearchedThroughTheWholeWindow() throws {
        var queried: [(Date, Date)] = []
        let window = CalendarEmptiness.window(now: now)
        let found = try CalendarEmptiness.firstEvents(in: window) { from, to in queried.append((from, to)); return 0 }
        XCTAssertNil(found)
        XCTAssertEqual(queried.count, EventRangeQuery.maxSpans)
        XCTAssertEqual(queried.first?.0, window.start)
        XCTAssertEqual(queried.last?.1, window.end)
        // A span after the first is queried from one second before its start, as `collect` does.
        XCTAssertEqual(queried[1].0, queried[0].1.addingTimeInterval(-1))
    }

    func testTheSearchStopsAtTheFirstSpanThatHoldsEvents() throws {
        var queried = 0
        let window = CalendarEmptiness.window(now: now)
        let found = try XCTUnwrap(try CalendarEmptiness.firstEvents(in: window) { _, _ in
            queried += 1
            return queried == 3 ? 2 : 0
        })
        XCTAssertEqual(queried, 3)
        XCTAssertEqual(found.atLeast, 2)
        let spans = try EventRangeQuery.spans(from: window.start, to: window.end)
        XCTAssertEqual(found.span, spans[2])
    }

    func testAnEventCalendarWithEventsIsRefusedWithTheWindowAndALowerBound() async throws {
        do {
            _ = try await CalendarEmptiness.check(holdsEvents: true, holdsReminders: false, now: now,
                                                  countEvents: { _, _ in 3 }, countReminders: { XCTFail("not a list"); return 0 })
            XCTFail("must refuse")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(error is EventKitError, "\(error)")
            XCTAssertTrue(text.contains("at least 3 event"), text)
            XCTAssertTrue(text.contains("Nothing was deleted"), text)
            let window = CalendarEmptiness.window(now: now)
            XCTAssertTrue(text.contains(EventRangeQuery.localText(window.start)) && text.contains(EventRangeQuery.localText(window.end)), text)
            XCTAssertTrue(text.contains("lower bound"), text)
        }
    }

    func testAnEmptyEventCalendarPassesAndSaysWhatWasSearched() async throws {
        let checked = try await CalendarEmptiness.check(holdsEvents: true, holdsReminders: false, now: now,
                                                        countEvents: { _, _ in 0 }, countReminders: { 0 })
        XCTAssertEqual(checked.searched, CalendarEmptiness.window(now: now))
        XCTAssertNil(checked.reminders)
    }

    func testAReminderListIsCountedWhole() async throws {
        do {
            _ = try await CalendarEmptiness.check(holdsEvents: false, holdsReminders: true, now: now,
                                                  countEvents: { _, _ in XCTFail("not a calendar"); return 0 },
                                                  countReminders: { 2 })
            XCTFail("must refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("holds 2 reminder(s), completed ones included"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
        let checked = try await CalendarEmptiness.check(holdsEvents: false, holdsReminders: true, now: now,
                                                        countEvents: { _, _ in 0 }, countReminders: { 0 })
        XCTAssertEqual(checked.reminders, 0)
        XCTAssertNil(checked.searched)
    }
}
