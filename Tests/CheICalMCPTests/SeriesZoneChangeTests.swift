import XCTest
@testable import CheICalMCP

/// #478: on a series that has started, a `timezone` or `clear_timezone` change from an occurrence
/// that has happened moved past occurrences and lost the last one (measured on iCloud: a weekly
/// series of 10 from Asia/Taipei set to Europe/London became 9). Refused before anything is written.
final class SeriesZoneChangeTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let london = TimeZone(identifier: "Europe/London")!
    private let first = Date(timeIntervalSince1970: 1_788_737_400) // 2026-09-07 07:30 +08:00
    private var now: Date { first.addingTimeInterval(9 * 7 * 86_400) }

    private func changes(_ requested: TimeZone?, clear: Bool = false, stored: TimeZone?) -> Bool {
        SeriesRuleWrite.changesZone(requested: requested, clearTimezone: clear, stored: stored)
    }

    func testAZoneChangeIsANewZoneOrClearingOne() {
        XCTAssertTrue(changes(london, stored: taipei))
        XCTAssertFalse(changes(taipei, stored: taipei), "the same zone echoed")
        XCTAssertTrue(changes(taipei, stored: nil), "any zone on a floating event")
        XCTAssertFalse(changes(nil, stored: taipei), "no zone in the call")
        XCTAssertTrue(changes(nil, clear: true, stored: taipei))
        XCTAssertFalse(changes(nil, clear: true, stored: nil), "nothing to clear")
    }

    /// PR #479 verify rounds 2 and 3: only the event's own stored identifier is no change. Another
    /// spelling of the same zone is a change (a zone write rewrites the series, and #455 lost an
    /// occurrence on a write that moved no wall-clock time), and so is any zone on a floating event,
    /// this Mac's included: item_timezone is null, and setting one rewrites the series.
    func testOnlyTheStoredIdentifierIsNoChange() {
        XCTAssertTrue(changes(TimeZone(identifier: "ROC")!, stored: taipei), "an alias of Asia/Taipei")
        XCTAssertTrue(changes(TimeZone(secondsFromGMT: 8 * 3600)!, stored: taipei), "GMT+0800")
        XCTAssertTrue(changes(TimeZone.current, stored: nil), "a floating event given this Mac's zone")
        XCTAssertTrue(changes(TimeZone(identifier: "ROC")!, stored: nil))
        XCTAssertFalse(changes(TimeZone(identifier: taipei.identifier)!, stored: taipei), "the stored identifier")
    }

    /// Round 3 MEDIUM: a started floating series given this Mac's zone is refused, not skipped; an
    /// all-day series turned timed with this Mac's zone gets the flip text.
    func testAFloatingStartedSeriesGivenThisMacsZoneIsRefused() {
        let floatingGivenHost = changes(TimeZone.current, stored: nil)
        XCTAssertEqual(refusal(changes: floatingGivenHost), SeriesRuleWrite.zoneChangeReason)
        XCTAssertEqual(refusal(changes: floatingGivenHost, storedAllDay: true, resultAllDay: false), SeriesRuleWrite.flipZoneReason)
        XCTAssertTrue(SeriesRuleWrite.zoneChangeReason.contains("item_timezone is null"), SeriesRuleWrite.zoneChangeReason)
    }

    /// The no-change shapes write no zone, so the store does not rewrite the series; round 3 LOW:
    /// clear_timezone on a floating started series writes nothing either.
    func testAZoneThatChangesNothingOnAStartedSeriesIsNotWritten() {
        let whole = SeriesRuleWrite.Reach.wholeSeries(anchor: first)
        func writes(_ requested: TimeZone?, clear: Bool = false, changes: Bool, reach: SeriesRuleWrite.Reach? = nil, happened: Bool) -> Bool {
            SeriesRuleWrite.writesZone(requested: requested, clearingTimezone: clear, changesZone: changes, reach: reach ?? whole, happened: happened)
        }
        XCTAssertFalse(writes(taipei, changes: false, happened: true))
        XCTAssertTrue(writes(taipei, changes: false, happened: false), "a series still to come: written as asked")
        XCTAssertTrue(writes(taipei, changes: false, reach: .oneOccurrence, happened: true), "span this or a one-off: written as asked")
        XCTAssertTrue(writes(london, changes: true, happened: false))
        XCTAssertFalse(writes(nil, changes: false, happened: false), "no zone in the call")
        XCTAssertFalse(writes(nil, clear: true, changes: false, happened: true), "clear_timezone over no zone, started: nil over nil not written")
        XCTAssertTrue(writes(nil, clear: true, changes: false, happened: false), "not started: written as asked")
        XCTAssertTrue(writes(nil, clear: true, changes: false, reach: .oneOccurrence, happened: true), "span this")
        XCTAssertTrue(writes(nil, clear: true, changes: true, happened: false))
    }

    private func refusal(_ reach: SeriesRuleWrite.Reach? = nil, happened: Bool = true, changes: Bool = true,
                         storedAllDay: Bool = false, resultAllDay: Bool = false, clearing: Bool = false) -> String? {
        SeriesRuleWrite.zoneRefusal(reach: reach ?? .wholeSeries(anchor: first), happened: happened, changesZone: changes,
                                    storedAllDay: storedAllDay, resultAllDay: resultAllDay, clearingTimezone: clearing)
    }

    func testAStartedSeriesRefusesAZoneChange() {
        XCTAssertEqual(refusal(), SeriesRuleWrite.zoneChangeReason, "the #478 repro: span all")
        XCTAssertEqual(refusal(.fromLaterOccurrence(anchor: first)), SeriesRuleWrite.zoneChangeReason, "span future from one that happened")
    }

    /// PR #479 verify MEDIUM: span future was measured for timezone only; clear_timezone gets its own
    /// text with no route.
    func testClearTimezoneGetsATextWithNoRoute() {
        XCTAssertEqual(refusal(clearing: true), SeriesRuleWrite.clearZoneReason)
        let reason = SeriesRuleWrite.clearZoneReason
        for phrase in ["has started", "already happened", "and a series with an occurrence_count was measured to lose its last occurrence (#455)", "No route", "leave clear_timezone out", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
        XCTAssertFalse(reason.contains("span 'future'"))
    }

    /// PR #479 verify LOW: only an event that is all-day before and after has no zone to change; a
    /// flip either way that changes the zone is refused.
    func testOnlyAnAllDayEventThatStaysAllDayIsExempt() {
        XCTAssertNil(refusal(storedAllDay: true, resultAllDay: true))
        XCTAssertEqual(refusal(storedAllDay: true, resultAllDay: false), SeriesRuleWrite.flipZoneReason,
                       "an all-day series turned timed with a zone: no route")
        XCTAssertFalse(SeriesRuleWrite.flipZoneReason.contains("span 'future'"), "span future refuses all_day from a later occurrence")
        for phrase in ["No route", "#442", "Nothing was written."] {
            XCTAssertTrue(SeriesRuleWrite.flipZoneReason.contains(phrase), phrase)
        }
        XCTAssertEqual(refusal(storedAllDay: false, resultAllDay: true, clearing: true), SeriesRuleWrite.clearZoneReason,
                       "a timed series turned all-day with clear_timezone")
    }

    /// PR #479 verify round 4: an all-day series turned timed with clear_timezone has no zone to
    /// clear, so changesZone is false, but the timed result is a new zone state: refused like the
    /// flip with timezone. Decided from the result's all-day state.
    func testAnAllDayToTimedFlipWithClearTimezoneIsRefused() {
        let noZoneToClear = SeriesRuleWrite.changesZone(requested: nil, clearTimezone: true, stored: nil)
        XCTAssertFalse(noZoneToClear)
        XCTAssertEqual(refusal(changes: noZoneToClear, storedAllDay: true, resultAllDay: false, clearing: true), SeriesRuleWrite.flipZoneReason)
        XCTAssertNil(refusal(changes: noZoneToClear, storedAllDay: true, resultAllDay: true, clearing: true), "stays all-day")
        XCTAssertNil(refusal(happened: false, changes: noZoneToClear, storedAllDay: true, resultAllDay: false, clearing: true), "still to come")
        XCTAssertNil(refusal(.oneOccurrence, changes: noZoneToClear, storedAllDay: true, resultAllDay: false, clearing: true), "span this")
        XCTAssertNil(refusal(changes: noZoneToClear, storedAllDay: false, resultAllDay: false, clearing: true), "a timed floating series: nothing to clear")
    }

    func testTheShapesThatKeepWorking() {
        XCTAssertNil(refusal(happened: false), "a series still to come: measured, all 6 kept")
        XCTAssertNil(refusal(changes: false), "the same zone echoed")
        XCTAssertNil(refusal(.oneOccurrence), "span this, or a one-off event")
        XCTAssertNil(refusal(happened: false, clearing: true))
    }

    func testTheReasonSaysWhyAndNamesOnlyMeasuredRoutes() {
        let reason = SeriesRuleWrite.zoneChangeReason
        for phrase in ["has started", "already happened", "the zone it then has", "the occurrence the write starts from",
                       "daylight-saving", "another day (not measured)", "leave timezone out", "span 'future'", "has not happened yet",
                       "Another spelling of the same zone", "the identifier item_timezone shows",
                       "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
        XCTAssertFalse(reason.contains("first occurrence's time"))
    }

    /// PR #479 verify INFO: the #416 field text no longer says there is no tested way for timezone.
    func testTheOccurrenceFieldTextNamesTheZoneRoute() {
        for whole in [true, false] {
            let text = DetachedOccurrenceSpan.fieldsReason(wholeSeries: whole)
            XCTAssertTrue(text.contains("#478"), text)
        }
    }

    func testUpdateEventRefusesBeforeTheFirstAssignment() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        let pin = "if let reason = SeriesRuleWrite.zoneRefusal( reach: reach, happened: happened, changesZone: changesZone, storedAllDay: event.isAllDay, resultAllDay: datePlan.isAllDay, clearingTimezone: clearTimezone) { throw EventKitError.seriesWriteRefused(reason: reason) }"
        let range = try XCTUnwrap(flat.range(of: pin), pin)
        XCTAssertLessThan(range.lowerBound, firstWrite.lowerBound)
    }

    /// PR #479 verify LOW (Codex): no seam runs updateEvent, so the inputs are pinned: the zone
    /// comparison reads the call's timezone and clear_timezone and the event's stored zone, and comes
    /// after `reach`, `happened` and the date plan it is given.
    func testTheRefusalReceivesTheValuesComputedAboveIt() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let compute = "let changesZone = SeriesRuleWrite.changesZone( requested: timezone, clearTimezone: clearTimezone, stored: event.timeZone)"
        let computed = try XCTUnwrap(flat.range(of: compute), compute)
        let refusal = try XCTUnwrap(flat.range(of: "if let reason = SeriesRuleWrite.zoneRefusal("))
        for earlier in ["let reach = SeriesRuleWrite.reach(", "let happened = reach.anchor.map {", "let datePlan = try AllDayRange.planUpdate("] {
            let range = try XCTUnwrap(flat.range(of: earlier), earlier)
            XCTAssertLessThan(range.lowerBound, computed.lowerBound, earlier)
        }
        XCTAssertLessThan(computed.lowerBound, refusal.lowerBound)
    }

    func testTheZoneIsAssignedOnlyWhenItIsWritten() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("if SeriesRuleWrite.writesZone( requested: timezone, clearingTimezone: clearTimezone, changesZone: changesZone, reach: reach, happened: happened) { event.timeZone = clearTimezone ? nil : timezone }"))
        XCTAssertFalse(flat.contains("if clearTimezone { event.timeZone = nil }"), "clear_timezone goes through the same gate")
    }
}
