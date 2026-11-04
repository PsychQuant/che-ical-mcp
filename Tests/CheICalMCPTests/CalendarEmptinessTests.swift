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

    func testAnEventCalendarWithEventsIsRefusedWithTheWindowAndALowerBound() throws {
        let window = CalendarEmptiness.window(now: now)
        do {
            try CalendarEmptiness.checkEvents(window: window, count: { _, _ in 3 })
            XCTFail("must refuse")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(error is EventKitError, "\(error)")
            XCTAssertTrue(text.contains("at least 3 event"), text)
            XCTAssertTrue(text.contains("Nothing was deleted"), text)
            XCTAssertTrue(text.contains(EventRangeQuery.localText(window.start)) && text.contains(EventRangeQuery.localText(window.end)), text)
            XCTAssertTrue(text.contains("lower bound"), text)
        }
        XCTAssertNoThrow(try CalendarEmptiness.checkEvents(window: window, count: { _, _ in 0 }))
    }

    /// PR #413 verify r1, 1: an event read that cannot answer refuses (fail-closed), it is never
    /// read as empty.
    func testAnEventReadThatFailsRefusesInsteadOfPassing() {
        struct ReadFailed: Error {}
        XCTAssertThrowsError(try CalendarEmptiness.checkEvents(window: CalendarEmptiness.window(now: now),
                                                               count: { _, _ in throw ReadFailed() })) { error in
            XCTAssertTrue(error is ReadFailed, "\(error)")
        }
    }

    func testAReminderListIsCountedWhole() throws {
        XCTAssertThrowsError(try CalendarEmptiness.checkReminders(counted: 2, generationBefore: 1, generationAfter: 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("holds 2 reminder(s), completed ones included"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
        XCTAssertNoThrow(try CalendarEmptiness.checkReminders(counted: 0, generationBefore: 1, generationAfter: 1))
    }

    /// PR #413 verify r1, 1: a fetch that returned nothing (nil, it failed) is not an empty list.
    func testARemindersFetchThatFailedRefusesInsteadOfDeleting() {
        XCTAssertThrowsError(try CalendarEmptiness.checkReminders(counted: nil, generationBefore: 1, generationAfter: 1)) { error in
            XCTAssertTrue(error is EventKitError, "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("could not be counted"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
    }

    /// PR #413 verify r1, 2: the reminder fetch suspends; a write this server committed meanwhile
    /// (the write generation moved) refuses, even when the count was 0.
    func testAWriteDuringTheReminderFetchRefuses() {
        XCTAssertThrowsError(try CalendarEmptiness.checkReminders(counted: 0, generationBefore: 4, generationAfter: 5)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed while the list was being checked"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
    }

    // MARK: - wiring (PR #413 verify r1, 2)

    /// The check runs on the manager's actor: the event span loop is synchronous (no `await` in
    /// `CalendarEmptiness`), the only suspension between the start of the check and the removal is
    /// the reminder fetch, and the write generation is taken before it and compared after it,
    /// before `removeCalendar`.
    func testTheCheckRunsOnTheActorWithOneSuspensionAndAGenerationCompare() throws {
        let emptiness = try SourcePins.source("EventKit/CalendarEmptiness.swift")
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\basync\b|\bawait\b"#, in: SourcePins.code(emptiness)).count, 0,
                       "CalendarEmptiness has no async step, so it runs on its caller's actor")
        let body = try XCTUnwrap(SourcePins.body(of: "func deleteCalendar(identifier: String, requireEmpty: Bool = false)",
                                                 in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let code = SourcePins.code(body)
        let check = try XCTUnwrap(SourcePins.ranges(of: "if requireEmpty {", in: code).first)
        let generation = try XCTUnwrap(SourcePins.ranges(of: "let generation = writeGeneration", in: code).first)
        let events = try XCTUnwrap(SourcePins.ranges(of: "CalendarEmptiness.checkEvents(", in: code).first)
        let fetch = try XCTUnwrap(SourcePins.ranges(of: "await countReminders(in: calendar)", in: code).first)
        let compare = try XCTUnwrap(SourcePins.ranges(of: "generationAfter: writeGeneration", in: code).first)
        let removal = try XCTUnwrap(SourcePins.ranges(of: "eventStore.removeCalendar(", in: code).first)
        XCTAssertTrue(check.lowerBound < generation.lowerBound && generation.lowerBound < events.lowerBound
                      && events.lowerBound < fetch.lowerBound && fetch.lowerBound < compare.lowerBound
                      && compare.lowerBound < removal.lowerBound, "generation, events, fetch, compare, removal, in that order")
        let awaits = SourcePins.ranges(ofPattern: #"\bawait\b"#, in: String(code[check.lowerBound..<removal.lowerBound]))
        XCTAssertEqual(awaits.count, 1, "the reminder fetch is the only suspension before the removal")
        let mark = try XCTUnwrap(SourcePins.body(of: "func markNeedsRefresh()", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertEqual(SourcePins.ranges(of: "writeGeneration &+= 1", in: mark).count, 1, "every write this server commits moves the generation")
    }
}
