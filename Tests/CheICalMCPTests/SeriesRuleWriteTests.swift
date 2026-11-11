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

    /// #442 cluster verify: span future from the first occurrence is a whole-series save too.
    func testWholeSeriesCoversSpanAllAndSpanFutureFromTheFirst() {
        XCTAssertTrue(reach(all: true, future: false, slot: 3 * week).isWholeSeries)
        XCTAssertTrue(reach(slot: 0).isWholeSeries, "span future from the first occurrence")
        XCTAssertFalse(reach(slot: 3 * week).isWholeSeries)
        XCTAssertFalse(reach(future: false).isWholeSeries)
        XCTAssertTrue(reach(ownIdLater: false, slot: 3 * week).isWholeSeries, "nothing earlier remains")
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

    // MARK: moving the start (PR #471 verify round 2: a closed rule)

    private func start(_ planned: TimeInterval?, reach: SeriesRuleWrite.Reach? = nil, happened: Bool = true,
                       now: TimeInterval = 5 * 7 * 86_400, calendar: Calendar? = nil, clearing: Bool = false) -> String? {
        SeriesRuleWrite.startRefusal(reach: reach ?? .wholeSeries(anchor: first), plannedStart: planned.map { first.addingTimeInterval($0) },
                                     happened: happened, now: first.addingTimeInterval(now), dayCalendar: calendar ?? utc,
                                     clearingRecurrence: clearing)
    }

    /// From an occurrence that has happened, only the time of day on its own date: a week either
    /// way, two days later, the next slot's day an hour earlier and a monthly 6th moved to the 26th
    /// all move the series' days.
    func testAHappenedAnchorAllowsOnlyItsOwnDay() {
        XCTAssertNil(start(0), "the same start")
        XCTAssertNil(start(2 * 3600), "the same day, later: measured clean")
        XCTAssertNil(start(-2 * 3600), "the same day, earlier")
        XCTAssertNil(start(nil), "no new start")
        let refused = SeriesRuleWrite.startPassesOccurrencesReason
        XCTAssertEqual(start(-week), refused, "a week earlier")
        XCTAssertEqual(start(week - 3600), refused, "the next slot's day, an hour earlier")
        XCTAssertEqual(start(20 * day), refused, "a monthly series on the 6th moved to the 26th")
        XCTAssertEqual(start(-day), refused, "the day before")
    }

    /// One passed slot is enough: the first occurrence went on a move of a week; two days later
    /// moved every happened occurrence to days they never had (measured).
    func testAnOccurrenceUpToTheNewStartRefuses() {
        XCTAssertEqual(start(week), SeriesRuleWrite.startPassesOccurrencesReason)
        XCTAssertEqual(start(2 * day), SeriesRuleWrite.startPassesOccurrencesReason)
    }

    /// PR #471 verify item 2: no listing of the series is read, so a deleted occurrence on the
    /// new date does not change the answer.
    func testADeletedSecondOccurrenceDoesNotLetAMovePastItsSlot() {
        XCTAssertEqual(start(week), SeriesRuleWrite.startPassesOccurrencesReason)
        XCTAssertEqual(start(week, reach: .fromLaterOccurrence(anchor: first)), SeriesRuleWrite.laterStartReason)
    }

    /// The day is the event's for a timed result and the host's for an all-day one; an all-day
    /// result starts at midnight of that day.
    func testAnAllDayResultComparesByDay() {
        let midnightSame = utc.startOfDay(for: first).timeIntervalSince(first)
        XCTAssertNil(start(midnightSame), "all_day on the first occurrence's day: measured clean")
        XCTAssertEqual(start(midnightSame + week), SeriesRuleWrite.startPassesOccurrencesReason, "all_day on the second's day")
        let taipei = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)
        // 08:00 UTC is 16:00 in Taipei; 17:00 UTC is 01:00 the next day there.
        XCTAssertNil(start(9 * 3600), "the same UTC day")
        XCTAssertEqual(start(9 * 3600, calendar: taipei), SeriesRuleWrite.startPassesOccurrencesReason, "the next day in the event's zone")
    }

    /// The round-2 LOW on the route the messages give: from an occurrence still to come, a start
    /// before now would put occurrences in the past.
    func testAnAnchorStillToComeRefusesAStartBeforeNow() {
        let later = SeriesRuleWrite.Reach.fromLaterOccurrence(anchor: first)
        XCTAssertEqual(start(-2 * week, reach: later, happened: false, now: -day), SeriesRuleWrite.pastStartReason)
        XCTAssertNil(start(2 * week, reach: later, happened: false, now: -day), "later, still to come: measured clean")
        XCTAssertNil(start(2 * 3600, reach: later, happened: false, now: -day))
        XCTAssertEqual(start(-2 * week, happened: false, now: -day), SeriesRuleWrite.pastStartReason, "a series that has not started, moved into the past")
        XCTAssertNil(start(4 * week, happened: false, now: -day), "a series that has not started, moved later: measured clean")
        XCTAssertNil(start(-2 * week, reach: .oneOccurrence, happened: false, now: -day), "span this is not this check's")
    }

    /// Items 3 and 5, and the clear_recurrence LOW: each covers its own case.
    func testTheStartReasonFollowsWhatTheCallCovers() {
        XCTAssertEqual(start(week, reach: .fromLaterOccurrence(anchor: first)), SeriesRuleWrite.laterStartReason)
        XCTAssertEqual(start(week, clearing: true), SeriesRuleWrite.clearStartReason)
        XCTAssertNil(start(3600, clearing: true), "clear_recurrence at another hour of the first day")
        XCTAssertFalse(SeriesRuleWrite.clearStartReason.contains("occurrence_date"),
                       "clear_recurrence from an occurrence is refused (#434), so it is not offered")
    }

    func testTheStartReasonNamesTheRouteThatWasMeasured() {
        let reason = SeriesRuleWrite.startPassesOccurrencesReason
        for phrase in ["already happened", "only the time of day", "own date", "earlier or later", "leave start_time out", "span 'future'",
                       "occurrence_date", "has not happened yet", "not in the past", "end_date", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
        for phrase in ["already happened", "only its time of day", "leave start_time out", "has not happened yet", "not in the past", "Nothing was written."] {
            XCTAssertTrue(SeriesRuleWrite.laterStartReason.contains(phrase), "\(phrase): \(SeriesRuleWrite.laterStartReason)")
        }
    }

    // MARK: a rule on a series that has started (PR #471 verify item 4, measured)

    private func rule(_ frequency: RecurrenceRuleInput.Frequency = .weekly, interval: Int = 1, days: [Int]? = [3], monthDays: [Int]? = nil,
                      end: Date? = nil, count: Int? = nil) -> RecurrenceRuleInput {
        RecurrenceRuleInput(frequency: frequency, interval: interval, endDate: end, occurrenceCount: count, daysOfWeek: days,
                            daysOfMonth: monthDays, excludedOccurrenceDates: nil)
    }

    private func refusal(_ new: RecurrenceRuleInput?, stored: [SeriesRuleWrite.StoredRule]? = nil, happened: Bool = true,
                         countBase: Date?? = .none) -> String? {
        SeriesRuleWrite.startedRuleRefusal(new, stored: stored ?? [weeklyTuesday], happened: happened, countBase: countBase ?? first,
                                           now: first.addingTimeInterval(5 * week), calendar: utc)
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
        XCTAssertEqual(refusal(rule(.monthly), stored: [numbered]), SeriesRuleWrite.unwritableRuleReason, "a filter the input cannot write")
        XCTAssertEqual(refusal(rule(), stored: []), SeriesRuleWrite.unwritableRuleReason, "no stored rule read")
        XCTAssertEqual(refusal(rule(), stored: [weeklyTuesday, weeklyTuesday]), SeriesRuleWrite.unwritableRuleReason, "two rules")
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
        XCTAssertEqual(SeriesRuleWrite.StoredRule(ek, startWeekday: 3), SeriesRuleWrite.StoredRule(frequency: .weekly, interval: 2, daysOfWeek: [3, 5], occurrenceCount: 10))
        let numbered = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday, weekNumber: 2)],
                                        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                        setPositions: nil, end: nil)
        XCTAssertTrue(SeriesRuleWrite.StoredRule(numbered, startWeekday: nil).hasOtherParts)
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        let ended = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: [15],
                                     monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                     end: EKRecurrenceEnd(end: end))
        XCTAssertEqual(SeriesRuleWrite.StoredRule(ended, startWeekday: nil), SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfMonth: [15], endDate: end))
    }

    /// Verify rounds 4-6: changing the week start (WKST) from s to Monday moves a weekly interval>1
    /// rule's occurrences only when its days plus the series' start weekday fall on both sides of
    /// the split between the circular range [s, Monday) and the rest. recurrence cannot write the
    /// week start (makeRecurrenceRule leaves EventKit's default), so such a rule counts as having a
    /// part recurrence cannot write.
    func testAWeekStartThatRegroupsTheRuleCannotBeWritten() {
        func weekly(interval: Int, weekStart: Int?, days: [EKRecurrenceDayOfWeek]) -> EKRecurrenceRule {
            let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: interval, daysOfTheWeek: days,
                                        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                        setPositions: nil, end: nil)
            if let weekStart { rule.setValue(weekStart, forKey: "firstDayOfTheWeek") }
            return rule
        }
        let sunTue = [EKRecurrenceDayOfWeek(.sunday), EKRecurrenceDayOfWeek(.tuesday)]
        let tueThu = [EKRecurrenceDayOfWeek(.tuesday), EKRecurrenceDayOfWeek(.thursday)]
        let tue = [EKRecurrenceDayOfWeek(.tuesday)]
        func parts(_ rule: EKRecurrenceRule, start: Int?) -> Bool { SeriesRuleWrite.StoredRule(rule, startWeekday: start).hasOtherParts }
        XCTAssertTrue(parts(weekly(interval: 2, weekStart: 1, days: sunTue), start: 1), "Sunday week start, every two weeks, Sunday and Tuesday")
        XCTAssertFalse(parts(weekly(interval: 2, weekStart: nil, days: sunTue), start: 1), "default week start")
        XCTAssertFalse(parts(weekly(interval: 1, weekStart: 1, days: sunTue), start: 1), "interval 1")
        // Round 6: Tuesday and Thursday from a Tuesday start sit on one side, so WKST=SU changes nothing.
        XCTAssertFalse(parts(weekly(interval: 2, weekStart: 1, days: tueThu), start: 3), "every two weeks on Tuesday and Thursday, WKST=SU")
        XCTAssertFalse(parts(weekly(interval: 2, weekStart: 1, days: tue), start: 3), "every two weeks on Tuesday, as Google writes it with WKST=SU")
        // Round 6: one day, but a Sunday start outside it: WKST=SU puts the first Tuesday 2 days in, Monday 9.
        XCTAssertTrue(parts(weekly(interval: 2, weekStart: 1, days: tue), start: 1), "a Tuesday rule from a Sunday start")
        XCTAssertTrue(parts(weekly(interval: 2, weekStart: 1, days: tue), start: nil), "start weekday unknown: the side that refuses")
        let monthly = EKRecurrenceRule(recurrenceWith: .monthly, interval: 2, daysOfTheWeek: nil, daysOfTheMonth: [15],
                                       monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        monthly.setValue(1, forKey: "firstDayOfTheWeek")
        XCTAssertFalse(SeriesRuleWrite.StoredRule(monthly, startWeekday: nil).hasOtherParts, "every two months on the 15th")
        func matters(_ fdw: Int, interval: Int = 2, days: Set<Int>, start: Int?, frequency: RecurrenceRuleInput.Frequency = .weekly) -> Bool {
            SeriesRuleWrite.weekStartMatters(frequency: frequency, firstDayOfTheWeek: fdw, interval: interval, days: days, startWeekday: start)
        }
        XCTAssertTrue(matters(1, interval: 3, days: [1, 3], start: 1))
        XCTAssertFalse(matters(2, interval: 3, days: [1, 3], start: 1), "Monday, what recurrence writes")
        XCTAssertFalse(matters(0, interval: 3, days: [1, 3], start: 1))
        XCTAssertFalse(matters(1, interval: 1, days: [1, 3], start: 1))
        XCTAssertFalse(matters(1, days: [1, 3], start: 1, frequency: .daily))
        XCTAssertFalse(matters(1, days: [], start: 4), "no days: the start weekday alone")
        XCTAssertFalse(matters(1, days: [1], start: 1), "Sunday alone")
        // Saturday week start: [Sat, Mon) is Saturday and Sunday.
        XCTAssertFalse(matters(7, days: [7, 1], start: 7), "Saturday and Sunday")
        XCTAssertTrue(matters(7, days: [1, 2], start: 1), "Sunday and Monday")
        XCTAssertFalse(matters(7, days: [3, 5], start: 3), "Tuesday and Thursday")
        // Wednesday week start: [Wed, Mon) is Wednesday to Sunday.
        XCTAssertTrue(matters(4, days: [2, 4], start: 2), "Monday and Wednesday")
        XCTAssertFalse(matters(4, days: [4, 6], start: 4), "Wednesday and Friday")
        XCTAssertEqual(EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, daysOfTheWeek: sunTue, daysOfTheMonth: nil,
                                        monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                        end: nil).firstDayOfTheWeek,
                       SeriesRuleWrite.writtenWeekStart, "EventKit's default for a rule built as makeRecurrenceRule builds it")
    }

    /// Verify rounds 5-6: over a stored rule recurrence cannot write, or rules that could not be
    /// read, any recurrence counts as possibly the stored one, so calendar_name with it from a later
    /// occurrence is refused, and the text does not offer a rule change that is refused again.
    func testAnyRuleOverAnUnwritableStoredRuleCountsAsStored() {
        let unwritable = SeriesRuleWrite.StoredRule(frequency: .weekly, interval: 2, daysOfWeek: [1, 3], hasOtherParts: true)
        let input = RecurrenceRuleInput(frequency: .weekly, interval: 2, endDate: nil, occurrenceCount: nil,
                                        daysOfWeek: [1, 3], daysOfMonth: nil, excludedOccurrenceDates: nil)
        XCTAssertTrue(SeriesRuleWrite.isStoredRule(input, stored: [unwritable]))
        XCTAssertTrue(SeriesRuleWrite.isStoredRule(input, stored: []), "rules that could not be read")
        for hasRecurrence in [true, false] {
            XCTAssertEqual(SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: true, changesAllDay: false, changesCalendar: true,
                                                                  hasRecurrence: hasRecurrence, occurrenceCount: nil,
                                                                  storedRuleUnwritable: true, recurrenceIsStored: true),
                           SeriesRuleWrite.calendarUnwritableReason)
        }
        XCTAssertFalse(SeriesRuleWrite.calendarUnwritableReason.contains("bound other than"))
        XCTAssertTrue(SeriesRuleWrite.calendarUnwritableReason.contains("span 'all'"))
        XCTAssertTrue(SeriesRuleWrite.calendarUnwritableReason.hasSuffix("Nothing was written."))
    }

    /// Round-2 LOW: a finished series echoing its own bound changes nothing; any other bound on it
    /// would add occurrences after its last one, which may be in the past.
    func testAFinishedSeriesTakesOnlyItsOwnBound() {
        let now = first.addingTimeInterval(5 * week)
        let pastEnd = first.addingTimeInterval(3 * week)
        let ended = SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3], endDate: pastEnd)
        XCTAssertNil(refusal(rule(end: pastEnd), stored: [ended]), "its own past end_date")
        XCTAssertNil(refusal(rule(end: pastEnd.addingTimeInterval(0.4)), stored: [ended]), "to the second")
        XCTAssertEqual(refusal(rule(end: now.addingTimeInterval(week)), stored: [ended]), SeriesRuleWrite.startedRuleReason, "reopened past now")
        XCTAssertEqual(refusal(rule(), stored: [ended]), SeriesRuleWrite.startedRuleReason, "no bound")
        let counted = SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3], occurrenceCount: 3)
        XCTAssertNil(refusal(rule(count: 3), stored: [counted]), "its own count")
        XCTAssertEqual(refusal(rule(count: 12), stored: [counted]), SeriesRuleWrite.startedRuleReason, "three weeks of a five-week-old series: finished")
        XCTAssertEqual(refusal(rule(end: now.addingTimeInterval(week)), stored: [counted]), SeriesRuleWrite.startedRuleReason)
    }

    func testWhetherACountedSeriesStillRuns() {
        let now = first.addingTimeInterval(5 * week)
        func runs(_ rule: SeriesRuleWrite.StoredRule, base: Date? = nil) -> Bool? {
            SeriesRuleWrite.stillRuns(rule, countBase: base ?? first, now: now, calendar: utc)
        }
        XCTAssertEqual(runs(weeklyTuesday), true, "ten weeks from five weeks ago")
        XCTAssertEqual(runs(SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3], occurrenceCount: 4)), false)
        XCTAssertEqual(runs(SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3], occurrenceCount: 5)), true, "the slot after the last is now")
        XCTAssertEqual(runs(SeriesRuleWrite.StoredRule(frequency: .monthly, occurrenceCount: 3)), true)
        XCTAssertEqual(runs(SeriesRuleWrite.StoredRule(frequency: .daily, interval: 7, occurrenceCount: 6)), true)
        XCTAssertNil(runs(SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [3, 5], occurrenceCount: 50)),
                     "several slots a week cannot be stepped: unknown")
        XCTAssertEqual(runs(SeriesRuleWrite.StoredRule(frequency: .weekly)), true, "no bound")
        XCTAssertEqual(runs(SeriesRuleWrite.StoredRule(frequency: .weekly, endDate: now)), true, "an end at now")
        XCTAssertNil(SeriesRuleWrite.stillRuns(weeklyTuesday, countBase: nil, now: now, calendar: utc), "a count with no base")
        XCTAssertEqual(SeriesRuleWrite.stillRuns(SeriesRuleWrite.StoredRule(frequency: .weekly, endDate: now), countBase: nil, now: now, calendar: utc),
                       true, "an end does not need the base")
    }

    /// PR #471 verify round 3: the stored count runs from the original first start, so only a call
    /// over the whole series from its first slot holds it.
    func testTheCountBaseIsTheFirstSlotOfAWholeSeriesCallOnly() {
        let whole = SeriesRuleWrite.Reach.wholeSeries(anchor: first)
        XCTAssertEqual(SeriesRuleWrite.countBase(reach: whole, viaStandIn: false, firstSlotGone: false), first)
        XCTAssertNil(SeriesRuleWrite.countBase(reach: .fromLaterOccurrence(anchor: first.addingTimeInterval(6 * week)), viaStandIn: false, firstSlotGone: false))
        XCTAssertNil(SeriesRuleWrite.countBase(reach: whole, viaStandIn: true, firstSlotGone: false), "the stand-in of a deleted first occurrence")
        XCTAssertNil(SeriesRuleWrite.countBase(reach: whole, viaStandIn: false, firstSlotGone: true), "an own id after the first slot was deleted")
        XCTAssertNil(SeriesRuleWrite.countBase(reach: .oneOccurrence, viaStandIn: false, firstSlotGone: false))
    }

    /// Round 3 HIGH: a weekly series of 10 that ended three weeks ago, changed from its 7th
    /// occurrence (happened, six weeks ago) to an end_date tomorrow or no bound. Counted from the 7th
    /// it read as still running and brought back occurrences in the past.
    func testAFinishedCountedSeriesChangedFromALaterOccurrenceIsRefused() {
        let now = first.addingTimeInterval(12 * week)
        let seventh = first.addingTimeInterval(6 * week)
        let later = SeriesRuleWrite.Reach.fromLaterOccurrence(anchor: seventh)
        let base = SeriesRuleWrite.countBase(reach: later, viaStandIn: false, firstSlotGone: false)
        func refused(_ new: RecurrenceRuleInput) -> String? {
            SeriesRuleWrite.startedRuleRefusal(new, stored: [weeklyTuesday], happened: true, countBase: base, now: now, calendar: utc)
        }
        XCTAssertEqual(refused(rule(end: now.addingTimeInterval(day))), SeriesRuleWrite.countedSeriesReason)
        XCTAssertEqual(refused(rule()), SeriesRuleWrite.countedSeriesReason)
        XCTAssertEqual(refused(rule(count: 12)), SeriesRuleWrite.countedSeriesReason)
        XCTAssertNil(refused(rule(count: 10)), "its own bound")
        XCTAssertEqual(SeriesRuleWrite.stillRuns(weeklyTuesday, countBase: seventh, now: now, calendar: utc), true,
                       "the round-2 reading, counted from the 7th: what this guards against")
        XCTAssertEqual(SeriesRuleWrite.startedRuleRefusal(rule(end: now.addingTimeInterval(day)), stored: [weeklyTuesday], happened: true,
                                                          countBase: first, now: now, calendar: utc),
                       SeriesRuleWrite.startedRuleReason, "from its first slot: finished, refused as such")
    }

    /// Round 3 MEDIUM: with the first occurrence deleted, the stand-in starts a week late, and a
    /// series that ended reads as running from it. No base: refused.
    func testAFinishedCountedSeriesThroughAStandInIsRefused() {
        let now = first.addingTimeInterval(10 * week + 3 * day)
        let standIn = first.addingTimeInterval(week)
        XCTAssertEqual(SeriesRuleWrite.stillRuns(weeklyTuesday, countBase: standIn, now: now, calendar: utc), true, "the wrong reading")
        for (viaStandIn, firstSlotGone) in [(true, false), (false, true)] {
            let base = SeriesRuleWrite.countBase(reach: .wholeSeries(anchor: standIn), viaStandIn: viaStandIn, firstSlotGone: firstSlotGone)
            XCTAssertEqual(SeriesRuleWrite.startedRuleRefusal(rule(), stored: [weeklyTuesday], happened: true, countBase: base, now: now, calendar: utc),
                           SeriesRuleWrite.countedSeriesReason)
        }
    }

    /// Round 3 LOW: a counted rule with several days a week gets the count text, not the one whose
    /// route was just refused.
    func testSeveralDaysAPeriodOnACountedSeriesGetTheCountText() {
        let mwf = SeriesRuleWrite.StoredRule(frequency: .weekly, daysOfWeek: [2, 4, 6], occurrenceCount: 30)
        XCTAssertEqual(refusal(rule(days: [2, 4, 6], end: first.addingTimeInterval(9 * week)), stored: [mwf]), SeriesRuleWrite.countedSeriesReason)
        XCTAssertNil(refusal(rule(days: [2, 4, 6], count: 30), stored: [mwf]), "its own count")
        for phrase in ["occurrence_count", "has not happened yet", "end_date", "leaving recurrence out", "Nothing was written."] {
            XCTAssertTrue(SeriesRuleWrite.countedSeriesReason.contains(phrase), phrase)
        }
    }

    /// Round 3 LOW: an echo of the stored rule may change nothing, leaving calendar_name to move
    /// every occurrence; the measured rows all changed the bound.
    func testAnEchoedRuleWithACalendarFromALaterOccurrenceIsRefused() {
        XCTAssertTrue(SeriesRuleWrite.isStoredRule(rule(count: 10), stored: [weeklyTuesday]))
        XCTAssertFalse(SeriesRuleWrite.isStoredRule(rule(end: first), stored: [weeklyTuesday]))
        XCTAssertFalse(SeriesRuleWrite.isStoredRule(rule(interval: 2, count: 10), stored: [weeklyTuesday]))
        XCTAssertEqual(SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: true, changesAllDay: false, changesCalendar: true,
                                                              hasRecurrence: true, occurrenceCount: nil, recurrenceIsStored: true),
                       SeriesRuleWrite.calendarReason)
        XCTAssertNil(SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: true, changesAllDay: false, changesCalendar: true,
                                                            hasRecurrence: true, occurrenceCount: nil, recurrenceIsStored: false))
        XCTAssertTrue(SeriesRuleWrite.calendarReason.contains("a bound other than the series' own"))
    }

    /// Round-2 LOW: a pattern recurrence cannot write has no rule change here, and the text says so.
    func testAnUnwritablePatternGetsItsOwnText() {
        let numbered = SeriesRuleWrite.StoredRule(frequency: .monthly, daysOfWeek: [3], hasOtherParts: true)
        XCTAssertEqual(refusal(rule(.monthly, days: [3]), stored: [numbered]), SeriesRuleWrite.unwritableRuleReason)
        XCTAssertNil(refusal(rule(.monthly, days: [3]), stored: [numbered], happened: false), "nothing happened yet: not checked")
        for phrase in ["cannot write", "Leave recurrence out", "Nothing was written."] {
            XCTAssertTrue(SeriesRuleWrite.unwritableRuleReason.contains(phrase), phrase)
        }
        XCTAssertFalse(SeriesRuleWrite.unwritableRuleReason.contains("end_date after now"))
    }

    func testTheRuleReasonNamesOnlyMeasuredRoutes() {
        let reason = SeriesRuleWrite.startedRuleReason
        for phrase in ["already happened", "its own bound", "leave recurrence out", "end_date after now", "span 'future'", "has not happened yet", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
    }

    /// The #439 recipe for ending a series is span all with the series' whole rule: on a started
    /// series it now needs its end_date at or after now, and the text says so.
    func testTheEndingRecipeSaysAnEndBeforeNowIsRefused() {
        for address in [EventKitManager.RecurrenceChangeAddress.seriesId, .occurrenceOwnId(series: nil)] {
            let text = EventKitError.recurrenceChangeOnOccurrenceRefused(clearing: true, address: address).errorDescription ?? ""
            XCTAssertTrue(text.contains("an end_date before now is refused"), text)
            XCTAssertTrue(text.contains("on a series with an occurrence_count"), text)
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

    /// Round-2 LOW: span all reaches here only through an own id after a deleted first slot; the
    /// text does not name span future, and says the route was not measured.
    func testACountOnSpanAllAfterADeletedFirstNamesItsOwnRoute() {
        XCTAssertEqual(SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: true, changesAllDay: false, changesCalendar: false,
                                                              hasRecurrence: true, occurrenceCount: 4, wholeSeriesCall: true),
                       SeriesRuleWrite.countAfterDeletedFirstReason)
        XCTAssertTrue(SeriesRuleWrite.countAfterDeletedFirstReason.contains("not measured"))
        XCTAssertTrue(SeriesRuleWrite.countAfterDeletedFirstReason.hasPrefix("occurrence_count cannot be used here"))
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
                       SeriesRuleWrite.clearStartReason, SeriesRuleWrite.startedRuleReason, SeriesRuleWrite.pastStartReason,
                       SeriesRuleWrite.unwritableRuleReason, SeriesRuleWrite.countAfterDeletedFirstReason, SeriesRuleWrite.countedSeriesReason] {
            XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
        }
    }

    // MARK: wiring (no in-memory store can run updateEvent)

    func testUpdateEventRefusesBeforeTheFirstAssignment() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        for pin in ["SeriesRuleWrite.laterOccurrenceRefusal( fromLaterOccurrence: reach.isFromLaterOccurrence,",
                    "if let reason = SeriesRuleWrite.startRefusal( reach: reach, plannedStart: datePlan.datesToWrite?.start, happened: happened, now: now, dayCalendar: dayCalendar, clearingRecurrence: clearRecurrence) {",
                    "if let reason = SeriesRuleWrite.startedRuleRefusal( recurrenceRule, stored: seriesRules, happened: happened, countBase: SeriesRuleWrite.countBase(reach: reach, viaStandIn: resolved.viaStandIn, firstSlotGone: ownNeighbours?.own.firstSlotGone ?? false),",
                    "storedRuleUnwritable: SeriesRuleWrite.writableRule(seriesRules) == nil,",
                    "recurrenceIsStored: recurrenceRule.map { SeriesRuleWrite.isStoredRule($0, stored: seriesRules) } ?? false) {",
                    "map { SeriesRuleWrite.StoredRule($0, startWeekday: seriesFirstSlotDay?.weekday) }"] {
            let range = try XCTUnwrap(flat.range(of: pin), pin)
            XCTAssertLessThan(range.lowerBound, firstWrite.lowerBound, pin)
        }
    }

    /// PR #471 verify items 1 and 2, and the force-unwrap LOW: where `reach` and the rules come from.
    func testReachAndTheRulesComeFromTheSeries() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for pin in ["let ownNeighbours = addressesOwnOccurrence ? try occurrenceNeighbours(of: masterEvent, id: identifier) : nil",
                    "ownIdLater: ownNeighbours.map { $0.earlierRemain || $0.own.firstSlotGone },",
                    "DetachedOccurrenceSpan.seriesIdentifier(of: identifier).flatMap { try storedEvent(id: $0) } : masterEvent",
                    "let dayCalendar = Calendar.gregorian(in: datePlan.isAllDay || event.isAllDay ? .current : (event.timeZone ?? .current))",
                    "wholeSeriesCall: applyToAll,",
                    "$0.calendarIdentifier != event.calendar?.calendarIdentifier"] {
            XCTAssertTrue(flat.contains(pin), pin)
        }
        XCTAssertFalse(flat.contains("passesAnOccurrence"), "no listing of the calendar decides it")
        XCTAssertFalse(flat.contains("event.calendar.calendarIdentifier"))
    }

    // MARK: - #512: the routes the #503 check can refuse say so

    /// The sentence of `reason` that gives a route (found by `marker`), as `replacingSpanFutureSentence`
    /// splits it: the condition has to be inside it, so a swap of that sentence takes it along.
    private func routeSentence(_ reason: String, _ marker: String) -> String? {
        reason.components(separatedBy: ". ").first { $0.contains(marker) }
    }

    private func namesTheDeletedOccurrenceCheck(_ sentence: String?) -> Bool {
        guard let sentence else { return false }
        return sentence.contains("#503") && sentence.contains("deleted on its own") && sentence.contains("cannot be ruled out")
    }

    func testTheStartedRuleRoutesNameTheDeletedOccurrenceCheck() {
        let reason = SeriesRuleWrite.startedRuleReason
        XCTAssertTrue(namesTheDeletedOccurrenceCheck(routeSentence(reason, "To end the series")), reason)
        XCTAssertTrue(routeSentence(reason, "To end the series")?.contains("occurrence_count") == true, "only a count series changes its bound")
        XCTAssertTrue(namesTheDeletedOccurrenceCheck(routeSentence(reason, "To change the pattern")), reason)
    }

    /// No route survives a count series whose first occurrence was deleted: #503 cannot show its first
    /// slot, so it answers unknown and refuses; the text points to Calendar there.
    func testTheCountedSeriesRouteNamesTheCheckAndCalendarAfterADeletedFirst() {
        let sentence = routeSentence(SeriesRuleWrite.countedSeriesReason, "To end it or change its bound")
        XCTAssertTrue(namesTheDeletedOccurrenceCheck(sentence), SeriesRuleWrite.countedSeriesReason)
        XCTAssertTrue(sentence?.contains("first occurrence was deleted") == true && sentence?.contains("Calendar") == true, sentence ?? "")
    }

    func testTheCountRouteNamesTheDeletedOccurrenceCheck() {
        XCTAssertTrue(namesTheDeletedOccurrenceCheck(routeSentence(SeriesRuleWrite.countReason, "Use end_date")), SeriesRuleWrite.countReason)
    }

    /// PR #515 round 1: this text is a fallback (#416's `firstLeftRecurrenceReason` answers the same call
    /// first), so it offers no route through this tool: Calendar, with #416 and #503 named.
    func testTheCountAfterADeletedFirstTextIsAFallbackThatPointsToCalendar() {
        let reason = SeriesRuleWrite.countAfterDeletedFirstReason
        XCTAssertFalse(reason.contains("use end_date") || reason.contains("Use end_date"), reason)
        XCTAssertTrue(reason.contains("#416") && reason.contains("#503") && reason.contains("change the series in Calendar"), reason)
    }

    /// PR #515 round 1: where a deleted first occurrence leaves #503 unable to rule one out, every
    /// count or pattern route says to change it in Calendar then.
    func testTheCountAndPatternRoutesPointToCalendarAfterADeletedFirst() {
        let gone = "which it cannot be once the series' first occurrence was deleted, so then change it in Calendar"
        XCTAssertTrue(routeSentence(SeriesRuleWrite.startedRuleReason, "To end the series")?.contains(gone) == true)
        XCTAssertTrue(routeSentence(SeriesRuleWrite.startedRuleReason, "To change the pattern")?.contains(gone) == true)
        XCTAssertTrue(routeSentence(SeriesRuleWrite.countReason, "Use end_date")?.contains(gone) == true)
        XCTAssertTrue(routeSentence(SeriesRuleWrite.calendarReason, "To move the occurrences from one that has not happened yet")?.contains(gone) == true)
    }

    /// PR #515 round 1: span all to another account is checked too, over every occurrence of the series
    /// (`reachedFrom` nil across accounts); and through a series whose first occurrence was deleted both
    /// routes are refused (#326), so the text names move_events_batch (measured, #369) or Calendar.
    func testTheCalendarRoutesNameTheAccountCheckAndTheStandIn() {
        let account = "to a calendar of another account it is refused while an occurrence deleted on its own is found among any occurrences of the series or cannot be ruled out (#503)"
        for reason in [SeriesRuleWrite.calendarReason, SeriesRuleWrite.calendarUnwritableReason] {
            XCTAssertTrue(routeSentence(reason, "Pass span 'all'")?.contains(account) == true, reason)
            let standIn = routeSentence(reason, "first occurrence was deleted both routes")
            XCTAssertTrue(standIn?.contains("#326") == true && standIn?.contains("move_events_batch") == true
                          && standIn?.contains("#369") == true && standIn?.contains("Calendar") == true, reason)
            XCTAssertFalse(standIn?.contains("span 'future'") == true, "survives the span future swap")
        }
        let future = routeSentence(SeriesRuleWrite.calendarReason, "To move the occurrences from one that has not happened yet")
        XCTAssertTrue(future?.contains(account) == true, SeriesRuleWrite.calendarReason)
    }

    /// PR #515 round 1: #503's pattern text says a count replaced by an end_date is a pattern change, and
    /// the measured new end_date was on a series that already ended at one.
    func testThePatternTextCountsABoundChangeAsAPatternChange() {
        let text = DeletedOccurrenceCheck.deletedReason(blocked: nil, change: .pattern)
        XCTAssertTrue(text.contains("a count replaced by an end_date or by no bound counts as one"), text)
        XCTAssertTrue(text.contains("a new end_date alone on a series that already ended at one kept them"), text)
    }

    func testTheCalendarRouteNamesTheDeletedOccurrenceCheck() {
        let sentence = routeSentence(SeriesRuleWrite.calendarReason, "To move the occurrences from one that has not happened yet")
        XCTAssertTrue(namesTheDeletedOccurrenceCheck(sentence), SeriesRuleWrite.calendarReason)
        XCTAssertTrue(sentence?.contains("another account") == true, sentence ?? "")
        XCTAssertFalse(sentence?.contains("another account, is refused while an occurrence deleted on its own is found among the occurrences it moves") == true)
        XCTAssertTrue(sentence?.contains("span 'future'") == true, "the condition stays in the sentence a swap replaces")
    }
}
