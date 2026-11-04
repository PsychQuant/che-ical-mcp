import XCTest
@testable import CheICalMCP

/// #373 verify (PR #379, MEDIUM): `updateEvent` assigned `event.title` before
/// `AllDayRange.planUpdate` could refuse the call, so a refused update left the rejected title on
/// the cached `EKEvent`, which a later save in the same server process could write. The same
/// order already held for #364's refusals, the all-day + timezone conflict (#190) and the weekday
/// check (#5). Every step that can refuse must run before the first field of the event is
/// assigned; only the save itself may come after.
///
/// Pinned over the source, because the handler cannot be driven without EventKit access: the
/// slice from `func updateEvent(` to its `try eventStore.save(event, span: span)` must have no `try`
/// or `throw` after its first write to the event.
final class UpdateEventRefusalOrderTests: XCTestCase {
    private func updateEventBodyBeforeSave() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func updateEvent("), "updateEvent exists")
        let rest = source[from.upperBound...]
        let save = try XCTUnwrap(rest.range(of: "try eventStore.save(event, span: span)"), "updateEvent saves the event")
        return rest[..<save.lowerBound].components(separatedBy: "\n").map {
            // Drop line comments, so a comment that mentions `throw` or `event.x = ` does not count.
            guard let slashes = $0.range(of: "//") else { return $0 }
            return String($0[..<slashes.lowerBound])
        }
    }

    /// A write to the event: `event.<field> = ...` (also inside `if let x = y { ... }`), or adding
    /// and removing alarms.
    private func isEventWrite(_ line: String) -> Bool {
        line.range(of: #"\bevent\.\w+\s*=[^=]"#, options: .regularExpression) != nil
            || line.range(of: #"\bevent\.(addAlarm|removeAlarm)\("#, options: .regularExpression) != nil
    }

    private func canRefuse(_ line: String) -> Bool {
        line.range(of: #"\b(try|throw)\b"#, options: .regularExpression) != nil
    }

    func testEveryRefusalInUpdateEventComesBeforeTheFirstWriteToTheEvent() throws {
        let lines = try updateEventBodyBeforeSave()
        let firstWrite = try XCTUnwrap(lines.firstIndex(where: isEventWrite), "updateEvent writes the event")
        let late = lines[firstWrite...].filter(canRefuse)
        XCTAssertEqual(late, [], "a step that can refuse runs after the first write (\(lines[firstWrite].trimmingCharacters(in: .whitespaces)))")
    }

    /// #373 verify round 2: the weekday check reads the planned start with the zone the event will
    /// have after the update, which for an all-day result is the host zone (WeekdayCheckZoneTests).
    func testTheWeekdayCheckUsesThePlannedAllDayState() throws {
        let text = try updateEventBodyBeforeSave().joined(separator: "\n").filter { !$0.isWhitespace }
        // Every argument is pinned (#373 verify round 3): the planned start, the planned all-day
        // state, the requested zone, the clear flag, the stored zone and the host calendar.
        XCTAssertTrue(text.contains("WeekdayCheck.weekday(of:datePlan.datesToWrite?.start??event.startDate,"
                                    + "resultIsAllDay:datePlan.isAllDay,requested:timezone,clearTimezone:clearTimezone,"
                                    + "stored:event.timeZone,host:Calendar.current)"),
                      "updateEvent passes the values the event will have after the update to WeekdayCheck")
    }

    /// #373 verify round 2 (DA): a save that fails (a read-only calendar, an alarm or recurrence
    /// EventKit rejects) left every assigned field on the cached event. The save is wrapped so a
    /// failure rolls the event back before the error is rethrown, like the move path does.
    func testAFailedSaveRollsTheEventBack() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func updateEvent("))
        let rest = source[from.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        let body = rest[..<end].filter { !$0.isWhitespace }
        XCTAssertTrue(body.contains("do{tryeventStore.save(event,span:span)}catch{event.rollback()throwerror}"),
                      "updateEvent rolls the event back when its save fails")
    }

    /// The pin must see the refusals it is about; otherwise an edit that renames them would make
    /// the check above pass on nothing.
    func testThePinSeesTheRefusalsItOrders() throws {
        let text = try updateEventBodyBeforeSave().joined(separator: "\n")
        for refusal in ["AllDayRange.planUpdate(", "EventKitError.allDayTimezoneConflict", "EventKitError.weekdayMismatch("] {
            XCTAssertTrue(text.contains(refusal), "updateEvent before its save contains \(refusal)")
        }
    }
}
