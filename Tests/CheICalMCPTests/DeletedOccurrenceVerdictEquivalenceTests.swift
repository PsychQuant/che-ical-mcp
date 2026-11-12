import EventKit
import XCTest
@testable import CheICalMCP

/// #520: `DeletedOccurrenceCheck.verdict` compares slots through `InstantSet` instead of a scan per
/// slot. Its answers must not change, so these tests run it beside the verdict of `main` (ef79cbc,
/// `verdictOnMain`) over the same generated inputs, and count its comparisons on a long series.
final class DeletedOccurrenceVerdictEquivalenceTests: XCTestCase {
    private let calendar = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)
    private let day: TimeInterval = 86_400

    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "+08:00")! }

    /// One call of the verdict, kept as values so both implementations get the same ones.
    private struct Input {
        var rules: [DeletedOccurrenceCheck.Rule]
        var firstStart: Date?
        var observed: [Date]
        var unedited: [Date]
        var slotsTrusted = true
        var changesAllDay = false
        var reachedFrom: Date?
        var scannedTo: Date
        var covers: Bool
        var isAllDay = false
        var listed: [DateInterval]?
        var horizon: Date?
    }

    private func current(_ input: Input, comparisons: ComparisonCounter? = nil) -> DeletedOccurrenceCheck.Verdict {
        DeletedOccurrenceCheck.verdict(
            rules: input.rules, firstStart: input.firstStart, observedSlots: input.observed, uneditedSlots: input.unedited,
            slotsTrusted: input.slotsTrusted, changesAllDay: input.changesAllDay, reachedFrom: input.reachedFrom,
            scannedTo: input.scannedTo, coversWholeSeries: input.covers, calendar: calendar, isAllDay: input.isAllDay,
            listed: input.listed, horizon: input.horizon, comparisons: comparisons)
    }

    private func onMain(_ input: Input) -> DeletedOccurrenceCheck.Verdict {
        DeletedOccurrenceCheck.verdictOnMain(
            rules: input.rules, firstStart: input.firstStart, observedSlots: input.observed, uneditedSlots: input.unedited,
            slotsTrusted: input.slotsTrusted, changesAllDay: input.changesAllDay, reachedFrom: input.reachedFrom,
            scannedTo: input.scannedTo, coversWholeSeries: input.covers, calendar: calendar, isAllDay: input.isAllDay,
            listed: input.listed, horizon: input.horizon)
    }

    /// A name for each kind of answer, to show the generated inputs reach every one.
    private func kind(_ verdict: DeletedOccurrenceCheck.Verdict) -> String {
        switch verdict {
        case .none: return "none"
        case .noneThrough: return "noneThrough"
        case .deleted(let blocked, let window):
            return "deleted(\(blocked.map { "\($0)" } ?? "route"))" + (window == nil ? "" : "+window")
        case .unknown(.firstSlot): return "unknown(firstSlot)"
        case .unknown(let cause): return "unknown(\(cause))"
        }
    }

    private func rule(_ frequency: EKRecurrenceFrequency, interval: Int = 1, days: [Int] = [], end: Date? = nil, count: Int = 0,
                      otherParts: Bool = false) -> DeletedOccurrenceCheck.Rule {
        .init(frequency: frequency, interval: interval, daysOfWeek: days, daysOfMonth: [], endDate: end, occurrenceCount: count,
              hasOtherParts: otherParts)
    }

    // MARK: - Generated inputs

    /// Offsets inside the tolerance: the slot still counts as the same instant.
    private let inside: [TimeInterval] = [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 0.999, -0.999]
    /// Offsets on and outside it.
    private let outside: [TimeInterval] = [1, -1, 1.001, -1.001, 2, -2, 3_600]

    private func generated(_ generator: inout SeededGenerator) -> Input {
        func chance(_ percent: Int, _ generator: inout SeededGenerator) -> Bool { Int.random(in: 0..<100, using: &generator) < percent }
        let firstStart = at("2026-01-05T10:00:00").addingTimeInterval(Double(Int.random(in: 0..<60, using: &generator)) * day)
        let span = Int.random(in: 10...90, using: &generator)
        var scannedTo = firstStart.addingTimeInterval(Double(span) * day + Double(Int.random(in: 0..<24, using: &generator)) * 3_600)

        let frequencyDraw = Int.random(in: 0..<10, using: &generator)
        let frequency: EKRecurrenceFrequency = frequencyDraw < 6 ? .daily : frequencyDraw < 9 ? .weekly : .monthly
        var end: Date?
        var count = 0
        switch Int.random(in: 0..<4, using: &generator) {
        case 0: end = firstStart.addingTimeInterval(Double(Int.random(in: 5...120, using: &generator)) * day + Double(Int.random(in: 0..<24, using: &generator)) * 3_600)
        case 1: count = Int.random(in: 1...40, using: &generator)
        default: break
        }
        var days: [Int] = []
        var interval = Int.random(in: 1...3, using: &generator)
        if frequency == .weekly, chance(40, &generator) {
            interval = 1
            let weekday = calendar.component(.weekday, from: firstStart)
            days = [weekday, weekday % 7 + 1, (weekday + 2) % 7 + 1]
        }
        let one = rule(frequency, interval: interval, days: days, end: end, count: count, otherParts: chance(2, &generator))
        let rules = chance(3, &generator) ? [] : chance(3, &generator) ? [one, one] : [one]

        let expected = DeletedOccurrenceCheck.expectedSlots(of: one, firstStart: firstStart, until: scannedTo, calendar: calendar) ?? []
        // No jitter, jitter inside the tolerance only, or any jitter.
        let jitter = Int.random(in: 0..<10, using: &generator)
        func moved(_ slot: Date, _ generator: inout SeededGenerator) -> Date {
            if jitter < 4 || !chance(30, &generator) { return slot }
            let offsets = jitter < 8 ? inside : inside + outside
            return slot.addingTimeInterval(offsets.randomElement(using: &generator)!)
        }
        let deletions = [0, 0, 3, 8, 30].randomElement(using: &generator)!
        var observed: [Date] = []
        for slot in expected where !chance(deletions, &generator) {
            observed.append(moved(slot, &generator))
            if chance(4, &generator) { observed.append(moved(slot, &generator)) }   // listed twice
        }
        if chance(6, &generator), let slot = expected.randomElement(using: &generator) { observed.append(slot.addingTimeInterval(7_200)) }
        if chance(6, &generator) { observed.append(firstStart.addingTimeInterval(-Double(Int.random(in: 1...3, using: &generator)) * day)) }
        if chance(6, &generator) { observed.append(scannedTo.addingTimeInterval(Double(Int.random(in: 0...2, using: &generator)) * day)) }
        observed.shuffle(using: &generator)
        let edited = [0, 10, 60].randomElement(using: &generator)!
        var unedited: [Date] = []
        for slot in observed where !chance(edited, &generator) { unedited.append(slot) }

        var listed: [DateInterval]?
        if chance(60, &generator) {
            // One to three ranges from before the first start, some with a gap between them.
            var ranges: [DateInterval] = []
            var start = firstStart.addingTimeInterval(-Double(Int.random(in: 0...5, using: &generator)) * day)
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                let length = Double(Int.random(in: 5...60, using: &generator)) * day
                ranges.append(DateInterval(start: start, duration: length))
                start = start.addingTimeInterval(length + (chance(50, &generator) ? 0 : Double(Int.random(in: 1...20, using: &generator)) * day))
            }
            listed = ranges.shuffled(using: &generator)
            if chance(80, &generator) { scannedTo = ranges.map(\.end).max()! }
        }
        let horizon: Date? = chance(60, &generator)
            ? firstStart.addingTimeInterval(Double(Int.random(in: 0...120, using: &generator)) * day) : nil
        var reachedFrom: Date?
        if chance(50, &generator), let slot = expected.randomElement(using: &generator) { reachedFrom = moved(slot, &generator) }
        return Input(rules: rules, firstStart: chance(4, &generator) ? nil : firstStart, observed: observed, unedited: unedited,
                     slotsTrusted: !chance(4, &generator), changesAllDay: chance(20, &generator), reachedFrom: reachedFrom,
                     scannedTo: scannedTo, covers: chance(50, &generator), isAllDay: chance(15, &generator), listed: listed, horizon: horizon)
    }

    /// 4,000 generated calls answer as `main` did, and between them reach every kind of answer the
    /// verdict has but `tooManySlots` (its own test below): an equality that held only on the early
    /// returns would show nothing.
    func testGeneratedCallsAnswerAsOnMain() {
        var generator = SeededGenerator(seed: 0x520)
        var kinds: [String: Int] = [:]
        for index in 0..<4_000 {
            let input = generated(&generator)
            let answer = current(input)
            XCTAssertEqual(answer, onMain(input), "case \(index): \(input)")
            kinds[kind(answer), default: 0] += 1
        }
        let required = [
            "none", "noneThrough", "deleted(route)", "deleted(route)+window", "deleted(notCovered)", "deleted(horizonNotReached)",
            "deleted(allDay)", "deleted(firstSlotMissing)", "deleted(nothingAfter)", "unknown(firstSlot)", "unknown(editedWithoutSlot)",
            "unknown(ruleNotFollowed)", "unknown(listedOffRule)", "unknown(allDayEnd)", "unknown(notCovered)", "unknown(horizonNotReached)",
        ]
        // With this seed the rarest kind (an all-day rule end) is reached 20 times and the next 35 times.
        for name in required {
            XCTAssertGreaterThanOrEqual(kinds[name, default: 0], 5, "\(name) was hardly reached: \(kinds)")
        }
        XCTAssertEqual(Set(kinds.keys), Set(required), "a kind the list does not name: \(kinds)")
    }

    /// A slot listed a fraction of a second off its rule slot is still that slot, in every one of the
    /// three comparisons, up to but not including a whole second.
    func testASlotJustInsideTheToleranceIsHeldAndJustOutsideIsNot() {
        let first = at("2026-12-07T10:00:00")
        let slots = (0..<5).map { first.addingTimeInterval(Double($0) * 7 * day) }
        func input(_ observed: [Date], unedited: [Date]? = nil) -> Input {
            Input(rules: [rule(.weekly, count: 5)], firstStart: first, observed: observed, unedited: unedited ?? observed,
                  scannedTo: at("2027-12-31T00:00:00"), covers: true)
        }
        for offset in [0.999, -0.999, 0.5, -0.5] {
            let near = input(slots.map { $0.addingTimeInterval(offset) })
            XCTAssertEqual(current(near), .none, "offset \(offset)")
            XCTAssertEqual(onMain(near), .none, "offset \(offset)")
        }
        // A whole second late: the listed slot is off the rule (the expander and the store disagree).
        var late = slots
        late[2] = late[2].addingTimeInterval(1)
        XCTAssertEqual(current(input(late)), .unknown(.listedOffRule))
        XCTAssertEqual(onMain(input(late)), .unknown(.listedOffRule))
        // The first slot a whole second early is not compared with the rule (it is before the first
        // start), and is not held either: the first slot reads as deleted.
        var early = slots
        early[0] = early[0].addingTimeInterval(-1)
        XCTAssertEqual(current(input(early)), .deleted(blocked: .firstSlotMissing))
        XCTAssertEqual(onMain(input(early)), .deleted(blocked: .firstSlotMissing))
        // The route after a deletion starts from a slot held unedited, within the tolerance.
        let withoutThird = [slots[0], slots[1], slots[3], slots[4]]
        let editedAfter = input(withoutThird, unedited: [slots[0], slots[1], slots[4].addingTimeInterval(0.999)])
        XCTAssertEqual(current(editedAfter), .deleted(blocked: nil))
        XCTAssertEqual(onMain(editedAfter), .deleted(blocked: nil))
        let noneUnedited = input(withoutThird, unedited: [slots[0], slots[1], slots[4].addingTimeInterval(1)])
        XCTAssertEqual(current(noneUnedited), .deleted(blocked: .nothingAfter))
        XCTAssertEqual(onMain(noneUnedited), .deleted(blocked: .nothingAfter))
    }

    /// Series of the size the listing really holds (a daily series over about four years, 1,500 slots),
    /// in the shapes of #506: nothing deleted, a deletion, a gap in the listing, a write from a later occurrence.
    func testSeriesOfTheListedSizeAnswerAsOnMain() {
        let first = at("2022-11-14T10:00:00")
        let scannedTo = first.addingTimeInterval(1_500 * day)
        let slots = DeletedOccurrenceCheck.expectedSlots(of: rule(.daily), firstStart: first, until: scannedTo, calendar: calendar) ?? []
        XCTAssertEqual(slots.count, 1_500)
        var generator = SeededGenerator(seed: 1_500)
        let whole = [DateInterval(start: first.addingTimeInterval(-day), end: scannedTo)]
        let gap = [DateInterval(start: first.addingTimeInterval(-day), duration: 400 * day),
                   DateInterval(start: first.addingTimeInterval(600 * day), end: scannedTo)]
        let horizon = first.addingTimeInterval(1_400 * day)
        let shapes: [(String, Input, DeletedOccurrenceCheck.Verdict)] = [
            ("nothing deleted, covered",
             Input(rules: [rule(.daily)], firstStart: first, observed: slots.shuffled(using: &generator), unedited: slots,
                   scannedTo: scannedTo, covers: true, listed: whole, horizon: nil), .none),
            ("nothing deleted, up to the horizon",
             Input(rules: [rule(.daily)], firstStart: first, observed: slots.shuffled(using: &generator), unedited: slots,
                   scannedTo: scannedTo, covers: false, listed: whole, horizon: horizon), .noneThrough(scannedTo)),
            ("one deleted",
             Input(rules: [rule(.daily)], firstStart: first, observed: slots.filter { $0 != slots[700] }, unedited: slots.filter { $0 != slots[700] },
                   scannedTo: scannedTo, covers: false, listed: whole, horizon: horizon),
             .deleted(blocked: nil, routeWindow: DateInterval(start: slots[701], end: scannedTo))),
            ("a gap in the listing",
             Input(rules: [rule(.daily)], firstStart: first, observed: slots.filter { DeletedOccurrenceCheck.isListed($0, in: gap) },
                   unedited: slots, scannedTo: scannedTo, covers: false, listed: gap, horizon: horizon), .unknown(.horizonNotReached)),
            ("from a later occurrence, past the gap",
             Input(rules: [rule(.daily)], firstStart: first, observed: slots.filter { DeletedOccurrenceCheck.isListed($0, in: gap) },
                   unedited: slots, reachedFrom: slots[800], scannedTo: scannedTo, covers: false, listed: gap, horizon: horizon),
             .noneThrough(scannedTo)),
        ]
        for (name, input, expected) in shapes {
            XCTAssertEqual(current(input), expected, name)
            XCTAssertEqual(onMain(input), expected, name)
        }
    }

    /// More slots than the expander takes is still unknown, before any slot is compared.
    func testTooManySlotsIsStillUnknown() {
        let first = at("1960-01-04T10:00:00")
        let input = Input(rules: [rule(.daily)], firstStart: first, observed: [first], unedited: [first],
                          scannedTo: first.addingTimeInterval(Double(DeletedOccurrenceCheck.maxSlots + 10) * day), covers: false)
        let counter = ComparisonCounter()
        XCTAssertEqual(current(input, comparisons: counter), .unknown(.tooManySlots))
        XCTAssertEqual(onMain(input), .unknown(.tooManySlots))
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.lookups, 0)
    }

    // MARK: - Scaling

    /// The most the verdict takes: `maxSlots` (20,000) expected slots, every one listed. Its slot
    /// comparisons, counted through the injected counter (the sorts and the lookups), stay near
    /// n log n. On `main` the two scans made about 200 million comparisons each here. The lookups are
    /// counted exactly: one per listed slot (is it a slot of the rule) and one per expected slot (is it
    /// held), so a scan put back for either would lower the count, and a set asked once per pair of
    /// slots would raise it.
    func testTheComparisonsOfTheLongestSeriesDoNotGrowWithItsSquare() {
        let count = DeletedOccurrenceCheck.maxSlots
        let first = at("1972-01-03T10:00:00")
        let scannedTo = first.addingTimeInterval(Double(count) * day - 3_600)
        let slots = DeletedOccurrenceCheck.expectedSlots(of: rule(.daily), firstStart: first, until: scannedTo, calendar: calendar) ?? []
        XCTAssertEqual(slots.count, count)
        var generator = SeededGenerator(seed: 20_520)
        let observed = slots.shuffled(using: &generator)

        let none = ComparisonCounter()
        XCTAssertEqual(current(Input(rules: [rule(.daily)], firstStart: first, observed: observed, unedited: observed,
                                     scannedTo: scannedTo, covers: true), comparisons: none), .none)
        XCTAssertEqual(none.lookups, 2 * count)
        XCTAssertLessThanOrEqual(none.count, 8_000_000)
        XCTAssertGreaterThan(none.count, none.lookups, "the comparisons are counted through the same counter")

        // With a deletion the third set (the unedited slots) is built and asked too: once for each of the
        // 9,999 expected slots after the deleted one, and the first slot is asked for once more.
        let deleted = ComparisonCounter()
        let withoutOne = observed.filter { $0 != slots[10_000] }
        XCTAssertEqual(current(Input(rules: [rule(.daily)], firstStart: first, observed: withoutOne, unedited: withoutOne,
                                     scannedTo: scannedTo, covers: true), comparisons: deleted), .deleted(blocked: nil))
        XCTAssertEqual(deleted.lookups, (count - 1) + count + 9_999 + 1)
        XCTAssertLessThanOrEqual(deleted.count, 12_000_000)
    }
}
