import EventKit
import XCTest
@testable import CheICalMCP

/// #451: the `update_event` shapes refused because occurrences went silently, as measured on iCloud.
final class SeriesRuleWriteTests: XCTestCase {
    /// A Tuesday, 2027-01-19 08:00 UTC, as the weekly Tuesday rule below starts on its day.
    private let first = Date(timeIntervalSince1970: 1_800_000_000 + 4 * 86_400)
    private let day: TimeInterval = 86_400
    private let week: TimeInterval = 7 * 86_400
    private let utc = Calendar.gregorian(in: TimeZone(identifier: "UTC")!)
    private let weeklyTuesday = SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3], occurrenceCount: 10)

    // MARK: what the write covers

    private func reach(all: Bool = false, future: Bool = true, repeats: Bool = true, ownIdLater: Bool? = nil, slot: TimeInterval = 0) -> SeriesRuleWrite.Reach {
        SeriesRuleWrite.reach(applyToAll: all, futureSpan: future, repeats: repeats, ownIdLater: ownIdLater,
                              seriesStart: first, occurrenceSlot: first.addingTimeInterval(slot))
    }

    func testReachComesFromTheOriginalSlot() {
        XCTAssertEqual(reach(all: true, future: false, slot: 3 * week), .wholeSeries(anchor: first), "span all starts at the series' start")
        XCTAssertEqual(reach(slot: 0), .wholeSeries(anchor: first), "span future from the first occurrence")
        XCTAssertEqual(reach(slot: 3 * week), .fromLaterOccurrence(anchor: first.addingTimeInterval(3 * week)))
        XCTAssertEqual(reach(future: false), .oneOccurrence, "span this")
        XCTAssertEqual(reach(repeats: false), .oneOccurrence, "a one-off event")
    }

    /// PR #471 verify item 1: an occurrence's own id resolves to that occurrence itself, so only the
    /// series' listing says whether it is the first.
    func testAnOwnIdWithAnEarlierSlotIsFromALaterOccurrence() {
        let slot = 3 * week
        XCTAssertEqual(reach(ownIdLater: true, slot: slot), .fromLaterOccurrence(anchor: first.addingTimeInterval(slot)))
        XCTAssertEqual(reach(ownIdLater: false, slot: slot), .wholeSeries(anchor: first.addingTimeInterval(slot)),
                       "nothing earlier remains: it is where the series starts now")
        XCTAssertEqual(reach(repeats: false, ownIdLater: true, slot: slot), .fromLaterOccurrence(anchor: first.addingTimeInterval(slot)),
                       "a detached occurrence reads back with no rules")
        XCTAssertEqual(reach(future: false, ownIdLater: true), .oneOccurrence)
        let laterReach = reach(ownIdLater: true, slot: slot)
        XCTAssertEqual(SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: laterReach.isFromLaterOccurrence, changesAllDay: false,
                                                              changesCalendar: false, hasRecurrence: true, occurrenceCount: 4),
                       SeriesRuleWrite.countReason)
    }

    func testAnOccurrenceMovedEarlierThanItsSlotHasHappened() {
        let now = first.addingTimeInterval(day)
        XCTAssertTrue(SeriesRuleWrite.hasHappened(slot: first, shownStart: first, now: now))
        XCTAssertTrue(SeriesRuleWrite.hasHappened(slot: now.addingTimeInterval(week), shownStart: first, now: now))
        XCTAssertFalse(SeriesRuleWrite.hasHappened(slot: now.addingTimeInterval(day), shownStart: now.addingTimeInterval(day), now: now))
    }

    // MARK: moving the start past occurrences that happened

    private func reads(repeats: Bool = true, planned: TimeInterval, happened: Bool = true) -> Bool {
        SeriesRuleWrite.needsPassedOccurrenceCheck(repeats: repeats, anchorStart: first, plannedStart: first.addingTimeInterval(planned), happened: happened)
    }

    func testOnlyAStartMovedLaterOnAStartedSeriesIsLookedAt() {
        XCTAssertTrue(reads(planned: week))
        XCTAssertFalse(reads(planned: -week), "earlier: measured clean on a series with no edited occurrence")
        XCTAssertFalse(reads(planned: 0), "the same start")
        XCTAssertFalse(reads(repeats: false, planned: week), "a one-off event")
        XCTAssertFalse(reads(planned: week, happened: false), "a series that has not started loses nothing that happened")
    }

    private func next(_ rules: [SeriesRuleWrite.StoredRule], after anchor: Date? = nil) -> Date {
        SeriesRuleWrite.nextSlotLowerBound(after: anchor ?? first, rules: rules, calendar: utc)
    }

    /// One passed slot is enough: the first occurrence went on a move of a week.
    func testAnOccurrenceUpToTheNewStartRefuses() {
        let second = first.addingTimeInterval(week)
        XCTAssertEqual(next([weeklyTuesday]), second)
        XCTAssertTrue(SeriesRuleWrite.passesNextSlot(plannedStart: second, nextSlot: second, dayCalendar: nil))
        XCTAssertFalse(SeriesRuleWrite.passesNextSlot(plannedStart: first.addingTimeInterval(2 * day), nextSlot: second, dayCalendar: nil),
                       "two days later, before the second: measured clean")
    }

    /// PR #471 verify item 2: the slot comes from the rule, not from the occurrences listed, so an
    /// occurrence deleted or edited there does not let a move past it through.
    func testADeletedSecondOccurrenceDoesNotLetAMovePastItsSlot() {
        XCTAssertEqual(next([weeklyTuesday]), first.addingTimeInterval(week), "nothing listed is read")
        XCTAssertEqual(next([SeriesRuleWrite.StoredRule(frequency: .weekly, interval: 2)]), first.addingTimeInterval(2 * week))
        XCTAssertEqual(next([SeriesRuleWrite.StoredRule(frequency: .daily, interval: 3)]), first.addingTimeInterval(3 * day))
    }

    func testMonthlyAndYearlyStepsAreNoLaterThanTheRealSlot() {
        let jan31 = utc.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 10))!
        let monthly = next([SeriesRuleWrite.StoredRule(frequency: .monthly)], after: jan31)
        XCTAssertEqual(utc.dateComponents([.month, .day], from: monthly), DateComponents(month: 2, day: 28), "clamped, before March 31")
        let onThe15th = utc.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 10))!
        XCTAssertEqual(utc.component(.month, from: next([SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfMonth: [15])], after: onThe15th)), 2)
        let yearly = next([SeriesRuleWrite.StoredRule(frequency: .yearly)], after: onThe15th)
        XCTAssertEqual(utc.component(.year, from: yearly), 2028)
    }

    /// PR #471 verify LOW: a rule with several slots a period, or one whose slot is not where the
    /// series starts, may come back the next day: only the same day is let through.
    func testRulesWithSeveralSlotsAPeriodAllowOnlyTheSameDay() {
        let tuesday = utc.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10))!
        let nextDay = utc.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        for rule in [SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3, 5]),
                     SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [5]),
                     SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfMonth: [1, 15]),
                     SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfWeek: [3]),
                     SeriesRuleWrite.StoredRule(frequency: .daily, daysOfWeek: [3, 4]),
                     SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfMonth: [-1]),
                     SeriesRuleWrite.StoredRule(frequency: .monthly, hasOtherParts: true)] {
            XCTAssertEqual(next([rule], after: tuesday), nextDay, "\(rule)")
        }
        XCTAssertEqual(next([weeklyTuesday, weeklyTuesday], after: tuesday), nextDay, "two rules")
        XCTAssertEqual(next([], after: tuesday), nextDay)
        XCTAssertEqual(next([weeklyTuesday], after: tuesday), tuesday.addingTimeInterval(week), "Tuesday rule on a Tuesday")
    }

    /// PR #471 verify LOW: an all-day result starts at midnight, before a timed slot that day.
    func testAnAllDayResultComparesByDay() {
        let secondSlot = first.addingTimeInterval(week)
        let midnight = utc.startOfDay(for: secondSlot)
        XCTAssertFalse(SeriesRuleWrite.passesNextSlot(plannedStart: midnight, nextSlot: secondSlot, dayCalendar: nil))
        XCTAssertTrue(SeriesRuleWrite.passesNextSlot(plannedStart: midnight, nextSlot: secondSlot, dayCalendar: utc))
        XCTAssertFalse(SeriesRuleWrite.passesNextSlot(plannedStart: midnight.addingTimeInterval(-day), nextSlot: secondSlot, dayCalendar: utc))
    }

    /// PR #471 verify items 3 and 5, and the clear_recurrence LOW: each covers its own case.
    func testTheStartReasonFollowsWhatTheCallCovers() {
        let whole = SeriesRuleWrite.Reach.wholeSeries(anchor: first), later = SeriesRuleWrite.Reach.fromLaterOccurrence(anchor: first)
        XCTAssertEqual(SeriesRuleWrite.startReason(reach: whole, clearingRecurrence: false), SeriesRuleWrite.startPassesOccurrencesReason)
        XCTAssertEqual(SeriesRuleWrite.startReason(reach: later, clearingRecurrence: false), SeriesRuleWrite.laterStartReason)
        XCTAssertEqual(SeriesRuleWrite.startReason(reach: whole, clearingRecurrence: true), SeriesRuleWrite.clearStartReason)
        XCTAssertFalse(SeriesRuleWrite.clearStartReason.contains("occurrence_date"),
                       "clear_recurrence from an occurrence is refused (#434), so it is not offered")
    }

    func testTheStartReasonNamesTheRouteThatWasMeasured() {
        let reason = SeriesRuleWrite.startPassesOccurrencesReason
        for phrase in ["already happened", "leave start_time out", "first occurrence's own date", "span 'future'",
                       "occurrence_date", "has not happened yet", "end_date", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
        for phrase in ["already happened", "leave start_time out", "has not happened yet", "Nothing was written."] {
            XCTAssertTrue(SeriesRuleWrite.laterStartReason.contains(phrase), "\(phrase): \(SeriesRuleWrite.laterStartReason)")
        }
    }

    // MARK: a rule on a series that has started (PR #471 verify item 4, measured)

    private func rule(_ frequency: RecurrenceRuleInput.Frequency = .weekly, interval: Int = 1, days: [Int]? = [3], monthDays: [Int]? = nil,
                      end: Date? = nil, count: Int? = nil) -> RecurrenceRuleInput {
        RecurrenceRuleInput(frequency: frequency, interval: interval, endDate: end, occurrenceCount: count, daysOfWeek: days,
                            daysOfMonth: monthDays, excludedOccurrenceDates: nil)
    }

    private func refusal(_ new: RecurrenceRuleInput?, stored: [SeriesRuleWrite.StoredRule]? = nil, happened: Bool = true) -> String? {
        SeriesRuleWrite.startedRuleRefusal(new, stored: stored ?? [weeklyTuesday], happened: happened, now: first.addingTimeInterval(5 * week))
    }

    func testEveryMeasuredRewriteIsRefused() {
        let now = first.addingTimeInterval(5 * week)
        XCTAssertEqual(refusal(rule(interval: 2, count: 10)), SeriesRuleWrite.startedRuleReason, "interval 2")
        XCTAssertEqual(refusal(rule(.monthly, days: nil, count: 10)), SeriesRuleWrite.startedRuleReason, "monthly")
        XCTAssertEqual(refusal(rule(count: 3)), SeriesRuleWrite.startedRuleReason, "a count below the stored one")
        XCTAssertEqual(refusal(rule(end: now.addingTimeInterval(-day))), SeriesRuleWrite.startedRuleReason, "an end before now")
        XCTAssertEqual(refusal(rule(days: [3, 5], count: 10)), SeriesRuleWrite.startedRuleReason, "Tuesday and Thursday")
        XCTAssertEqual(refusal(rule(days: [5])), SeriesRuleWrite.startedRuleReason, "another weekday")
        XCTAssertEqual(refusal(rule(days: nil)), SeriesRuleWrite.startedRuleReason, "days left out: another set, not judged")
    }

    func testTheStoredPatternWithABoundThatKeepsWhatHappenedPasses() {
        let now = first.addingTimeInterval(5 * week)
        XCTAssertNil(refusal(rule(end: now.addingTimeInterval(2 * week))), "an end after now: measured, all kept")
        XCTAssertNil(refusal(rule(end: now)), "an end at now")
        XCTAssertNil(refusal(rule(count: 12)), "a count above the stored one: measured, all kept")
        XCTAssertNil(refusal(rule(count: 10)), "the stored count")
        XCTAssertNil(refusal(rule()), "no bound: measured, all kept")
    }

    func testABoundTheStoredRuleCannotCompareIsRefused() {
        let open = SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3])
        XCTAssertEqual(refusal(rule(count: 50), stored: [open]), SeriesRuleWrite.startedRuleReason, "a count on an open series")
        XCTAssertNil(refusal(rule(), stored: [open]))
        let numbered = SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfWeek: [3], hasOtherParts: true)
        XCTAssertEqual(refusal(rule(.monthly), stored: [numbered]), SeriesRuleWrite.startedRuleReason, "a filter the input cannot write")
        XCTAssertEqual(refusal(rule(), stored: []), SeriesRuleWrite.startedRuleReason, "no stored rule read")
        XCTAssertEqual(refusal(rule(), stored: [weeklyTuesday, weeklyTuesday]), SeriesRuleWrite.startedRuleReason, "two rules")
    }

    func testARuleBeforeAnythingHappenedIsNotChecked() {
        XCTAssertNil(refusal(rule(interval: 2, count: 3), happened: false), "measured clean from an occurrence still to come")
        XCTAssertNil(refusal(nil), "no rule in the call")
    }

    func testTheDaysAreComparedAsSets() {
        let both = SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3, 5])
        XCTAssertNil(refusal(rule(days: [5, 3, 5]), stored: [both]))
        let monthDays = SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfMonth: [1, 15])
        XCTAssertNil(refusal(rule(.monthly, days: nil, monthDays: [15, 1]), stored: [monthDays]))
        XCTAssertEqual(refusal(rule(.monthly, days: nil, monthDays: [1]), stored: [monthDays]), SeriesRuleWrite.startedRuleReason)
    }

    func testTheStoredRuleIsReadFromEventKit() {
        let ek = EKRecurrenceRule(recurrenceWith: .weekly, interval: 2,
                                  daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday), EKRecurrenceDayOfWeek(.thursday)],
                                  daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                  setPositions: nil, end: EKRecurrenceEnd(occurrenceCount: 10))
        XCTAssertEqual(SeriesRuleWrite.StoredRule(ek), SeriesRuleWrite.StoredRule(frequency: .weekly, interval: 2, daysOfWeek: [3, 5], occurrenceCount: 10))
        let numbered = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday, weekNumber: 2)],
                                        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                        setPositions: nil, end: nil)
        XCTAssertTrue(SeriesRuleWrite.StoredRule(numbered).hasOtherParts)
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        let ended = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: [15],
                                     monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                     end: EKRecurrenceEnd(end: end))
        XCTAssertEqual(SeriesRuleWrite.StoredRule(ended), SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfMonth: [15], endDate: end))
    }

    func testTheRuleReasonNamesOnlyMeasuredRoutes() {
        let reason = SeriesRuleWrite.startedRuleReason
        for phrase in ["already happened", "end_date after now", "span 'future'", "has not happened yet", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
    }

    /// The #439 recipe for ending a series is span all with the series' whole rule: on a started
    /// series it now needs its end_date at or after now, and the text says so.
    func testTheEndingRecipeSaysAnEndBeforeNowIsRefused() {
        for address in [EventKitManager.RecurrenceChangeAddress.seriesId, .occurrenceOwnId(series: nil)] {
            let text = EventKitError.recurrenceChangeOnOccurrenceRefused(clearing: true, address: address).errorDescription ?? ""
            XCTAssertTrue(text.contains("an end_date before now is refused"), text)
        }
    }

    // MARK: span future from a later occurrence

    private func refusal(later: Bool = true, allDay: Bool = false, calendar: Bool = false, rule: Bool = false, count: Int? = nil) -> String? {
        SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: later, changesAllDay: allDay, changesCalendar: calendar,
                                               hasRecurrence: rule, occurrenceCount: count)
    }

    func testAllDayIsRefusedWithOrWithoutARule() {
        XCTAssertEqual(refusal(allDay: true), SeriesRuleWrite.allDayReason)
        XCTAssertEqual(refusal(allDay: true, rule: true), SeriesRuleWrite.allDayReason)
        XCTAssertEqual(refusal(allDay: true, rule: true, count: 4), SeriesRuleWrite.allDayReason)
    }

    func testACountIsRefused() {
        XCTAssertEqual(refusal(rule: true, count: 4), SeriesRuleWrite.countReason)
        XCTAssertEqual(refusal(calendar: true, rule: true, count: 4), SeriesRuleWrite.countReason)
    }

    /// With a rule the calendar change stayed within the later occurrences; alone it moved all of them.
    func testACalendarAloneIsRefusedAndWithARuleIsNot() {
        XCTAssertEqual(refusal(calendar: true), SeriesRuleWrite.calendarReason)
        XCTAssertNil(refusal(calendar: true, rule: true))
    }

    func testTheCleanShapesPass() {
        XCTAssertNil(refusal())
        XCTAssertNil(refusal(rule: true), "a rule with end_date or no bound")
        XCTAssertNil(refusal(later: false, allDay: true, calendar: true, rule: true, count: 4), "not from a later occurrence")
    }

    func testTheReasonsSayWhatWasMeasuredAndNothingWasWritten() {
        XCTAssertTrue(SeriesRuleWrite.countReason.contains("end_date"), SeriesRuleWrite.countReason)
        XCTAssertTrue(SeriesRuleWrite.calendarReason.contains("span 'all'"), SeriesRuleWrite.calendarReason)
        XCTAssertTrue(SeriesRuleWrite.allDayReason.contains("span 'all'"), SeriesRuleWrite.allDayReason)
        for reason in [SeriesRuleWrite.countReason, SeriesRuleWrite.calendarReason, SeriesRuleWrite.allDayReason,
                       SeriesRuleWrite.startPassesOccurrencesReason, SeriesRuleWrite.laterStartReason,
                       SeriesRuleWrite.clearStartReason, SeriesRuleWrite.startedRuleReason] {
            XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
        }
    }

    // MARK: wiring (no in-memory store can run updateEvent)

    func testUpdateEventRefusesBeforeTheFirstAssignment() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        for pin in ["SeriesRuleWrite.laterOccurrenceRefusal( fromLaterOccurrence: reach.isFromLaterOccurrence,",
                    "throw EventKitError.seriesWriteRefused(reason: SeriesRuleWrite.startReason(reach: reach, clearingRecurrence: clearRecurrence))",
                    "if let reason = SeriesRuleWrite.startedRuleRefusal(recurrenceRule, stored: seriesRules, happened: happened, now: now) {"] {
            let range = try XCTUnwrap(flat.range(of: pin), pin)
            XCTAssertLessThan(range.lowerBound, firstWrite.lowerBound, pin)
        }
    }

    /// PR #471 verify items 1 and 2, and the force-unwrap LOW: where `reach` and the rules come from.
    func testReachAndTheRulesComeFromTheSeries() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for pin in ["let ownNeighbours = addressesOwnOccurrence ? occurrenceNeighbours(of: masterEvent, id: identifier) : nil",
                    "ownIdLater: ownNeighbours.map { $0.earlierRemain || $0.own.firstSlotGone },",
                    "DetachedOccurrenceSpan.seriesIdentifier(of: identifier).flatMap { storedEvent(id: $0) } : masterEvent",
                    "nextSlot: SeriesRuleWrite.nextSlotLowerBound(after: anchor, rules: seriesRules,",
                    "dayCalendar: datePlan.isAllDay || event.isAllDay ? Calendar.gregorian(in: .current) : nil",
                    "$0.calendarIdentifier != event.calendar?.calendarIdentifier"] {
            XCTAssertTrue(flat.contains(pin), pin)
        }
        XCTAssertFalse(flat.contains("passesAnOccurrence"), "no listing of the calendar decides it")
        XCTAssertFalse(flat.contains("event.calendar.calendarIdentifier"))
    }
}
