import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// #503: a write that changes the start, end or all-day flag of more than one occurrence of a
/// series brought back every occurrence deleted on its own (iCloud, measured). The check compares
/// the rule's expected slots with the listed occurrences and refuses when one is missing, or when
/// it cannot tell (`unknown`). Pure: no store.
final class DeletedOccurrenceCheckTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Taipei")!
    private var calendar: Calendar { Calendar.gregorian(in: zone) }

    private func at(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.date(from: text + "+08:00")!
    }

    private func weekly(days: [Int] = [], interval: Int = 1, count: Int = 0, end: Date? = nil) -> DeletedOccurrenceCheck.Rule {
        .init(frequency: .weekly, interval: interval, daysOfWeek: days, daysOfMonth: [], endDate: end, occurrenceCount: count, hasOtherParts: false)
    }

    // MARK: - Expected slots

    func testAWeeklyRuleGivesOneSlotAWeek() throws {
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(count: 5), firstStart: at("2026-12-07T10:00:00"),
                                                                        until: at("2027-12-31T00:00:00"), calendar: calendar))
        XCTAssertEqual(slots, ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"].map { at($0 + "T10:00:00") })
    }

    func testAWeeklyRuleOnSeveralDaysCountsFromTheFirstStart() throws {
        // Monday and Wednesday from a Monday, three occurrences.
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(days: [2, 4], count: 3), firstStart: at("2026-12-07T10:00:00"),
                                                                        until: at("2027-12-31T00:00:00"), calendar: calendar))
        XCTAssertEqual(slots, [at("2026-12-07T10:00:00"), at("2026-12-09T10:00:00"), at("2026-12-14T10:00:00")])
    }

    func testAnEndDateBoundsTheSlots() throws {
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(end: at("2026-12-21T23:59:00")), firstStart: at("2026-12-07T10:00:00"),
                                                                        until: at("2027-12-31T00:00:00"), calendar: calendar))
        XCTAssertEqual(slots.count, 3)
    }

    func testDailyMonthlyAndYearlyRules() throws {
        let first = at("2026-01-31T09:00:00")
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 2, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 3, hasOtherParts: false)
        XCTAssertEqual(DeletedOccurrenceCheck.expectedSlots(of: daily, firstStart: first, until: at("2027-12-31T00:00:00"), calendar: calendar),
                       [at("2026-01-31T09:00:00"), at("2026-02-02T09:00:00"), at("2026-02-04T09:00:00")])
        let monthly = DeletedOccurrenceCheck.Rule(frequency: .monthly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 3, hasOtherParts: false)
        XCTAssertEqual(DeletedOccurrenceCheck.expectedSlots(of: monthly, firstStart: at("2026-01-15T09:00:00"), until: at("2027-12-31T00:00:00"), calendar: calendar),
                       [at("2026-01-15T09:00:00"), at("2026-02-15T09:00:00"), at("2026-03-15T09:00:00")])
        let yearly = DeletedOccurrenceCheck.Rule(frequency: .yearly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 2, hasOtherParts: false)
        XCTAssertEqual(DeletedOccurrenceCheck.expectedSlots(of: yearly, firstStart: first, until: at("2028-12-31T00:00:00"), calendar: calendar),
                       [at("2026-01-31T09:00:00"), at("2027-01-31T09:00:00")])
    }

    /// Rules the expander cannot follow give nil, which the verdict reads as unknown.
    func testRulesTheExpanderCannotFollow() {
        let first = at("2026-12-07T10:00:00"), until = at("2027-12-31T00:00:00")
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(of: weekly(days: [2, 4], interval: 2), firstStart: first, until: until, calendar: calendar),
                     "several days every two weeks depend on the week start")
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(of: weekly(days: [3]), firstStart: first, until: until, calendar: calendar),
                     "a first start off the rule's days")
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: true),
            firstStart: first, until: until, calendar: calendar))
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .monthly, interval: 1, daysOfWeek: [], daysOfMonth: [-1], endDate: nil, occurrenceCount: 0, hasOtherParts: false),
            firstStart: first, until: until, calendar: calendar))
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .yearly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: false),
            firstStart: at("2028-02-29T10:00:00"), until: until, calendar: calendar))
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .daily, interval: 1, daysOfWeek: [2], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: false),
            firstStart: first, until: until, calendar: calendar))
    }

    // MARK: - Verdict

    private func verdict(observed: [String], reachedFrom: String? = nil, covers: Bool = true, trusted: Bool = true,
                         first: String? = "2026-12-07T10:00:00",
                         rules: [DeletedOccurrenceCheck.Rule]? = nil) -> DeletedOccurrenceCheck.Verdict {
        DeletedOccurrenceCheck.verdict(rules: rules ?? [weekly(count: 5)], firstStart: first.map(at),
                                       observedSlots: observed.map { at($0 + "T10:00:00") },
                                       uneditedSlots: observed.map { at($0 + "T10:00:00") }, slotsTrusted: trusted,
                                       changesAllDay: false, reachedFrom: reachedFrom.map(at),
                                       scannedTo: at("2027-12-31T00:00:00"), coversWholeSeries: covers, calendar: calendar)
    }

    func testAMissingSlotIsADeletedOccurrence() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"]), .deleted(blocked: nil))
    }

    func testEverySlotListedIsNone() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"]), .none)
    }

    func testOnlyTheSlotsTheWriteReachesCount() {
        // Span future from the third occurrence: the deleted second is not reached (#503: it stayed deleted).
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"], reachedFrom: "2026-12-21T10:00:00"), .none)
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2027-01-04"], reachedFrom: "2026-12-21T10:00:00"), .deleted(blocked: nil))
    }

    func testASeriesTheListingDoesNotCoverIsUnknown() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"], covers: false), .unknown)
        // A deletion found inside the listing refuses on its own grounds.
        // Round 1 (LOW 6): there the partial route cannot work either, so the text does not offer it.
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"], covers: false), .deleted(blocked: .notCovered))
    }

    func testMoreThanOneRuleOrAnUnfollowableRuleIsUnknown() {
        XCTAssertEqual(verdict(observed: [], rules: [weekly(count: 5), weekly(count: 5)]), .unknown)
        XCTAssertEqual(verdict(observed: [], rules: []), .unknown)
        XCTAssertEqual(verdict(observed: ["2026-12-07"], rules: [weekly(days: [3])]), .unknown)
    }

    func testAnEditedOccurrenceIsListedByItsRuleSlot() {
        // The caller passes rule slots; an occurrence moved to 11:00 is listed at its 10:00 slot.
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"]), .none)
    }

    // MARK: - When the check applies

    func testTheCheckAppliesToWritesThatChangeTheDatesOfMoreThanOneOccurrence() {
        let start = at("2026-12-07T10:00:00"), end = at("2026-12-07T11:00:00")
        func applies(_ reachesSeveral: Bool, newStart: Date? = nil, newEnd: Date? = nil, allDay: Bool = false, clearing: Bool = false) -> Bool {
            DeletedOccurrenceCheck.applies(reachesSeveral: reachesSeveral, clearingRecurrence: clearing,
                                           plannedDates: newStart.map { ($0, newEnd ?? end) } ?? newEnd.map { (start, $0) },
                                           storedStart: start, storedEnd: end, resultAllDay: allDay, storedAllDay: false,
                                           changesZone: false, changesAccount: false)
        }
        XCTAssertTrue(applies(true, newStart: at("2026-12-07T11:00:00"), newEnd: at("2026-12-07T12:00:00")))
        XCTAssertTrue(applies(true, newEnd: at("2026-12-07T11:30:00")), "an end-only change brought it back")
        XCTAssertTrue(applies(true, allDay: true))
        XCTAssertFalse(applies(true, newStart: start, newEnd: end), "the stored values kept it")
        XCTAssertFalse(applies(true), "a title-only write kept it")
        XCTAssertFalse(applies(false, newStart: at("2026-12-07T11:00:00")), "one occurrence")
        XCTAssertFalse(applies(true, newStart: at("2026-12-07T11:00:00"), clearing: true), "clear_recurrence leaves one event")
    }

    func testTheRefusalTextsNameTheIssueAndWriteNothing() {
        let blocks: [DeletedOccurrenceCheck.RouteBlock?] = [nil, .notCovered, .allDay, .firstSlotMissing, .nothingAfter]
        for reason in blocks.map(DeletedOccurrenceCheck.deletedReason(blocked:)) + [DeletedOccurrenceCheck.unknownReason] {
            XCTAssertTrue(reason.contains("Nothing was written."), reason)
            XCTAssertTrue(reason.contains("deleted on its own"), reason)
        }
        // Rounds 1-3: the route only where it can pass, and each refusal of it says its own cause.
        let offer = DeletedOccurrenceCheck.deletedReason(blocked: nil)
        XCTAssertTrue(offer.contains("an occurrence after it, not edited on its own"))
        XCTAssertFalse(offer.contains("No tested route"), "the opening no longer contradicts the route it offers")
        XCTAssertTrue(DeletedOccurrenceCheck.deletedReason(blocked: .notCovered).contains("goes on past what this check can list"))
        XCTAssertTrue(DeletedOccurrenceCheck.deletedReason(blocked: .allDay).contains("for an all_day change"))
        XCTAssertTrue(DeletedOccurrenceCheck.deletedReason(blocked: .firstSlotMissing).contains("first occurrence was deleted"))
        XCTAssertTrue(DeletedOccurrenceCheck.deletedReason(blocked: .nothingAfter).contains("nowhere to start span 'future' from"))
        for block in [DeletedOccurrenceCheck.RouteBlock.allDay, .firstSlotMissing, .nothingAfter] {
            XCTAssertFalse(DeletedOccurrenceCheck.deletedReason(blocked: block).contains("goes on past"), "\(block)")
        }
        // Round 1 (LOW 7, HIGH): the cases the code refuses as unknown are all named.
        for part in ["its first occurrence was deleted", "days of the week on a daily, monthly or yearly rule",
                     "days of the month on a daily, weekly or yearly rule", "an interval below 1", "a day of the month after the 28th",
                     "a count whose last occurrence", "an occurrence edited on its own without its original slot",
                     "more than one, is listed where the series shows its first", "its recorded first slot disagrees",
                     "a listed occurrence falls where the rule gives none"] {
            XCTAssertTrue(DeletedOccurrenceCheck.unknownReason.contains(part), part)
        }
    }

    // MARK: - Round 1 of PR #505

    /// HIGH: the first slot counts only when proven. A stand-in (the first remaining occurrence after
    /// the first was deleted, #326) or a detached object never gives it.
    func testTheFirstSlotIsProvenOnlyForTheSeriesObject() {
        let original = at("2026-12-07T10:00:00")
        func first(_ od: Date?, start: Date, listed: Bool = true, rid: Date? = nil, earliest: Date? = nil,
                   standIn: Bool = false, detached: Bool = false) -> Date? {
            DeletedOccurrenceCheck.firstSlot(occurrenceDate: od, startDate: start, startMatches: listed ? 1 : 0, startRIDSlot: rid,
                                             earliestListedSlot: earliest ?? rid, viaStandIn: standIn, isDetached: detached)
        }
        XCTAssertEqual(first(original, start: original), original, "the first occurrence not edited")
        XCTAssertNil(first(at("2026-12-14T10:00:00"), start: at("2026-12-14T10:00:00"), standIn: true), "never counted again from a stand-in")
        XCTAssertNil(first(original, start: original, detached: true))
        XCTAssertNil(first(original, start: original, listed: false), "no occurrence listed where the series shows its first")
        // An edited first occurrence: its /RID= slot is the first slot.
        let later = at("2026-12-07T14:00:00")
        XCTAssertEqual(first(original, start: later, rid: original), original, "moved later")
        XCTAssertEqual(first(later, start: later, rid: original), original, "moved later, occurrenceDate drifted (LOW 8)")
        // Round 2 (MEDIUM, LOW 2): moved earlier, occurrenceDate drifted: never the earlier time.
        // Round 4 (LOW 5): nor the RID slot, since a later occurrence moved onto a deleted first
        // occurrence's start reads the same: unknown.
        let earlier = at("2026-12-07T09:00:00")
        XCTAssertNil(first(earlier, start: earlier, rid: original))
        XCTAssertEqual(first(original, start: earlier, rid: original), original, "moved earlier, not drifted")
        // occurrenceDate agrees with neither the RID slot nor the shown start: unknown.
        XCTAssertNil(first(at("2026-12-07T08:00:00"), start: earlier, rid: original))
        // Edited with nothing that shows its original slot: unknown.
        XCTAssertNil(first(original, start: later))
        // An edited occurrence whose slot is before the first slot: unknown.
        XCTAssertNil(first(original, start: original, earliest: at("2026-11-30T10:00:00")))
    }

    /// Round 2 (LOW 3): the span-future route is offered only where it can pass: not an all-day
    /// change (#451 refuses it from a later occurrence), the first slot present (else the series' id
    /// resolves to a stand-in), and an occurrence after the last missing slot.
    func testTheRouteIsOfferedOnlyWhereItCanPass() {
        let all = ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"]
        func route(observed: [String], allDay: Bool = false) -> DeletedOccurrenceCheck.Verdict {
            DeletedOccurrenceCheck.verdict(rules: [weekly(count: 5)], firstStart: at("2026-12-07T10:00:00"),
                                           observedSlots: observed.map { at($0 + "T10:00:00") },
                                           uneditedSlots: observed.map { at($0 + "T10:00:00") }, slotsTrusted: true,
                                           changesAllDay: allDay, reachedFrom: nil, scannedTo: at("2027-12-31T00:00:00"),
                                           coversWholeSeries: true, calendar: calendar)
        }
        XCTAssertEqual(route(observed: all.filter { $0 != "2026-12-14" }), .deleted(blocked: nil))
        XCTAssertEqual(route(observed: all.filter { $0 != "2026-12-14" }, allDay: true), .deleted(blocked: .allDay))
        XCTAssertEqual(route(observed: all.filter { $0 != "2027-01-04" }), .deleted(blocked: .nothingAfter), "the last slot deleted")
        XCTAssertEqual(route(observed: all.filter { $0 != "2026-12-07" }), .deleted(blocked: .firstSlotMissing), "the first slot deleted")
    }

    /// Round 2 (LOW 6, measured): a zone change brought deletions back across a daylight-saving
    /// divergence, so it is checked like a change of start, end or all_day.
    func testAZoneChangeIsChecked() {
        let start = at("2026-12-07T10:00:00"), end = at("2026-12-07T11:00:00")
        XCTAssertTrue(DeletedOccurrenceCheck.applies(reachesSeveral: true, clearingRecurrence: false, plannedDates: nil,
                                                     storedStart: start, storedEnd: end, resultAllDay: false, storedAllDay: false,
                                                     changesZone: true, changesAccount: false))
        XCTAssertFalse(DeletedOccurrenceCheck.applies(reachesSeveral: false, clearingRecurrence: false, plannedDates: nil,
                                                      storedStart: start, storedEnd: end, resultAllDay: false, storedAllDay: false,
                                                      changesZone: true, changesAccount: false))
    }

    /// Round 3 (MEDIUM): a moved occurrence on the first one's start is not taken for the first.
    /// S0 unedited, S1 deleted, S2 moved onto S0's start.
    func testAnOccurrenceMovedOntoTheFirstStartIsNotTheFirst() {
        let s0 = at("2026-12-07T10:00:00"), s2 = at("2026-12-21T10:00:00")
        XCTAssertNil(DeletedOccurrenceCheck.firstSlot(occurrenceDate: s0, startDate: s0, startMatches: 2, startRIDSlot: s2,
                                                      earliestListedSlot: s0, viaStandIn: false, isDetached: false),
                     "two occurrences listed at the start")
        XCTAssertNil(DeletedOccurrenceCheck.firstSlot(occurrenceDate: s0, startDate: s0, startMatches: 1, startRIDSlot: s2,
                                                      earliestListedSlot: s0, viaStandIn: false, isDetached: false),
                     "an unedited slot before the chosen first")
    }

    /// Round 3 (MEDIUM): what is listed must be what the rule gives, both ways.
    func testAListedSlotTheRuleDoesNotGiveIsUnknown() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-16", "2026-12-21", "2026-12-28", "2027-01-04"]), .unknown)
    }

    /// Round 3, measured on iCloud (2026-11-09): the rule's end is a point in time, inclusive. Weekly
    /// 10:00 from 2026-12-07: an end at 00:00 on 2027-01-04 (a date-only end_date) gives 4 occurrences,
    /// an end at 10:00 or 23:59 that day gives 5; a New York series ended at 00:00 New York gives 4;
    /// an all-day series whose stored end is 2027-01-05 07:59:59 Taipei gives 5.
    func testTheRuleEndIsAnInclusiveInstantAsMeasured() throws {
        let first = at("2026-12-07T10:00:00"), until = at("2027-12-31T00:00:00")
        func count(_ end: Date, from: Date? = nil, calendar cal: Calendar? = nil) throws -> Int {
            try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(end: end), firstStart: from ?? first,
                                                               until: until, calendar: cal ?? calendar)).count
        }
        XCTAssertEqual(try count(at("2027-01-04T00:00:00")), 4, "date-only end_date, and T00:00")
        XCTAssertEqual(try count(at("2027-01-04T10:00:00")), 5, "an end at the occurrence's own time")
        XCTAssertEqual(try count(at("2027-01-04T23:59:00")), 5, "an end at 23:59")
        let ny = TimeZone(identifier: "America/New_York")!
        let nyFirst = Calendar.gregorian(in: ny).date(from: DateComponents(year: 2026, month: 12, day: 7, hour: 10))!
        let nyEnd = Calendar.gregorian(in: ny).date(from: DateComponents(year: 2027, month: 1, day: 4))!
        XCTAssertEqual(try count(nyEnd, from: nyFirst, calendar: Calendar.gregorian(in: ny)), 4, "New York, read from a Taipei host")
        XCTAssertEqual(try count(at("2027-01-05T07:59:59"), from: at("2026-12-07T00:00:00")), 5, "all-day, end of the last day")
        // An end on an occurrence's day is checked like any other: none without a deletion, and the
        // 5th deleted under an end at 23:59 is found.
        let four = ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28"]
        XCTAssertEqual(verdict(observed: four, rules: [weekly(end: at("2027-01-04T00:00:00"))]), .none)
        XCTAssertEqual(verdict(observed: four, rules: [weekly(end: at("2027-01-04T23:59:00"))]), .deleted(blocked: .nothingAfter))
    }

    /// Round 3 (LOW 6): only an occurrence not edited on its own after the last deletion is a starting point.
    func testOnlyAnUneditedOccurrenceAfterTheLastDeletionIsAStart() {
        let held = ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"].map { at($0 + "T10:00:00") }
        let result = DeletedOccurrenceCheck.verdict(
            rules: [weekly(count: 5)], firstStart: at("2026-12-07T10:00:00"), observedSlots: held,
            uneditedSlots: [at("2026-12-07T10:00:00")], slotsTrusted: true, changesAllDay: false, reachedFrom: nil,
            scannedTo: at("2027-12-31T00:00:00"), coversWholeSeries: true, calendar: calendar)
        XCTAssertEqual(result, .deleted(blocked: .nothingAfter))
    }

    /// HIGH, the integration shapes: the first occurrence deleted and the rest intact.
    func testAFirstOccurrenceDeletedIsFoundOrUnknown() {
        let rest = ["2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"]
        // Through the series object (its first slot proven): span all finds the deletion.
        // Round 2 (LOW 3): with the first slot missing, the series' id resolves to a stand-in, so
        // the span-future route is not offered.
        XCTAssertEqual(verdict(observed: rest), .deleted(blocked: .firstSlotMissing), "count series, span all")
        XCTAssertEqual(verdict(observed: rest, rules: [weekly(end: at("2027-01-04T23:00:00"))]), .deleted(blocked: .firstSlotMissing),
                       "end-date series, span all")
        // Through a stand-in (span future from a later occurrence, measured): the first slot is not
        // proven, so the answer is unknown, for both bounds.
        XCTAssertEqual(verdict(observed: rest, reachedFrom: "2026-12-21T10:00:00", first: nil), .unknown, "count series, stand-in")
        XCTAssertEqual(verdict(observed: rest, reachedFrom: "2026-12-21T10:00:00", first: nil,
                               rules: [weekly(end: at("2027-01-04T23:00:00"))]), .unknown, "end-date series, stand-in")
    }

    /// MEDIUM / LOW 4: a whole-series write reaches every occurrence, so it filters nothing: a deleted
    /// slot before the first occurrence's shown (moved) start is still found.
    func testAWholeSeriesWriteChecksEverySlot() {
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                                occurrenceCount: 4, hasOtherParts: false)
        // The first occurrence moved to day 2 14:00 (listed by its rule slot, day 1 10:00); day 2 10:00 deleted.
        let result = DeletedOccurrenceCheck.verdict(
            rules: [daily], firstStart: at("2026-12-07T10:00:00"),
            observedSlots: ["2026-12-07", "2026-12-09", "2026-12-10"].map { at($0 + "T10:00:00") },
            uneditedSlots: ["2026-12-09", "2026-12-10"].map { at($0 + "T10:00:00") }, slotsTrusted: true,
            changesAllDay: false, reachedFrom: nil, scannedTo: at("2027-12-31T00:00:00"), coversWholeSeries: true, calendar: calendar)
        XCTAssertEqual(result, .deleted(blocked: nil))
        XCTAssertEqual(DeletedOccurrenceCheck.reachedFrom(isWholeSeries: true, anchor: at("2026-12-08T14:00:00")), nil)
        XCTAssertEqual(DeletedOccurrenceCheck.reachedFrom(isWholeSeries: false, anchor: at("2026-12-21T10:00:00")), at("2026-12-21T10:00:00"))
    }

    /// LOW 9: an edited occurrence without a /RID= slot may show a moved time as its slot, so a gap
    /// is not proof of a deletion.
    func testUntrustedSlotsAreUnknown() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"], trusted: false), .unknown)
    }

    /// INFO 10: a day after the 28th is not followed (EventKit's month-end handling was not measured).
    func testAMonthDayAfterThe28thIsNotFollowed() {
        let monthly = DeletedOccurrenceCheck.Rule(frequency: .monthly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                                  occurrenceCount: 3, hasOtherParts: false)
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(of: monthly, firstStart: at("2026-01-31T09:00:00"),
                                                          until: at("2027-12-31T00:00:00"), calendar: calendar))
    }

    // MARK: - PR #505 round 4

    /// MEDIUM 1: a calendar of another account is a create plus a delete (not measured), so it goes
    /// through the same verdict, with no date change.
    func testAMoveToAnotherAccountApplies() {
        let start = at("2026-12-07T10:00:00"), end = at("2026-12-07T11:00:00")
        func applies(_ reachesSeveral: Bool, account: Bool, clearing: Bool = false) -> Bool {
            DeletedOccurrenceCheck.applies(reachesSeveral: reachesSeveral, clearingRecurrence: clearing, plannedDates: nil,
                                           storedStart: start, storedEnd: end, resultAllDay: false, storedAllDay: false,
                                           changesZone: false, changesAccount: account)
        }
        XCTAssertTrue(applies(true, account: true))
        XCTAssertFalse(applies(true, account: false))
        XCTAssertFalse(applies(false, account: true))
        XCTAssertFalse(applies(true, account: true, clearing: true))
        let text = DeletedOccurrenceCheck.accountMoveReason(.deleted(blocked: nil))
        XCTAssertTrue(text.contains("another account") && text.contains("not measured") && text.contains("Nothing was written"), text)
        XCTAssertTrue(DeletedOccurrenceCheck.accountMoveReason(.unknown).contains("cannot rule one out"))
        XCTAssertNotEqual(DeletedOccurrenceCheck.accountMoveReason(.unknown), DeletedOccurrenceCheck.accountMoveReason(.deleted(blocked: nil)))
    }

    /// LOW 3: an EventKit range does not return an event that starts exactly at its end, so a slot
    /// at `until` is not expected. An open-ended daily series lands one there (1825 days on).
    func testASlotAtTheListingEndIsNotExpected() throws {
        let first = at("2026-12-07T10:00:00")
        let until = try XCTUnwrap(calendar.date(byAdding: .day, value: 1825, to: first))
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: false)
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: daily, firstStart: first, until: until, calendar: calendar))
        XCTAssertEqual(slots.count, 1825)
        XCTAssertLessThan(try XCTUnwrap(slots.last), until)
        XCTAssertEqual(DeletedOccurrenceCheck.verdict(rules: [daily], firstStart: first, observedSlots: slots, uneditedSlots: slots, slotsTrusted: true,
                                                      changesAllDay: false, reachedFrom: nil, scannedTo: until, coversWholeSeries: false,
                                                      calendar: calendar), .unknown)
    }

    /// LOW 4 and 7: an all-day series stores its end as the end of its last day in UTC, so east of
    /// UTC the next local midnight is still before it. Whether EventKit lists that day was not
    /// measured, so an end less than a day after a slot is unknown.
    func testAnAllDayEndLessThanADayAfterASlotIsUnknown() throws {
        let first = at("2027-01-01T00:00:00")
        let end = at("2027-01-05T07:59:59")   // a 2027-01-04 end, as stored (measured)
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: end, occurrenceCount: 0, hasOtherParts: false)
        let held = ["2027-01-01", "2027-01-02", "2027-01-03", "2027-01-04"].map { at($0 + "T00:00:00") }
        func verdict(allDay: Bool) -> DeletedOccurrenceCheck.Verdict {
            DeletedOccurrenceCheck.verdict(rules: [daily], firstStart: first, observedSlots: held, uneditedSlots: held, slotsTrusted: true,
                                           changesAllDay: false, reachedFrom: nil, scannedTo: at("2027-12-31T00:00:00"), coversWholeSeries: true,
                                           calendar: calendar, isAllDay: allDay)
        }
        XCTAssertEqual(verdict(allDay: true), .unknown)
        // A weekly all-day series, as measured: its last slot is more than a day before the end.
        let weekly = weekly(end: end)
        let mondays = ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"].map { at($0 + "T00:00:00") }
        XCTAssertEqual(DeletedOccurrenceCheck.verdict(rules: [weekly], firstStart: mondays[0], observedSlots: mondays, uneditedSlots: mondays, slotsTrusted: true,
                                                      changesAllDay: false, reachedFrom: nil, scannedTo: at("2027-12-31T00:00:00"), coversWholeSeries: true,
                                                      calendar: calendar, isAllDay: true), .none)
    }

    /// LOW 5: S0 deleted, S1 edited and moved onto S0's start, on a store where the series object
    /// still refreshes: its `/RID=` slot is after the shown start while the recorded first equals the
    /// shown start, so the first slot cannot be shown.
    func testAnEditedOccurrenceMovedOntoTheDeletedFirstStartIsNotTheFirst() {
        let start = at("2026-12-07T10:00:00"), s1 = at("2026-12-14T10:00:00")
        XCTAssertNil(DeletedOccurrenceCheck.firstSlot(occurrenceDate: start, startDate: start, startMatches: 1, startRIDSlot: s1,
                                                      earliestListedSlot: s1, viaStandIn: false, isDetached: false))
        // The first occurrence edited and moved later keeps its slot.
        XCTAssertEqual(DeletedOccurrenceCheck.firstSlot(occurrenceDate: start, startDate: at("2026-12-07T12:00:00"), startMatches: 1,
                                                        startRIDSlot: start, earliestListedSlot: start, viaStandIn: false, isDetached: false), start)
    }

}
