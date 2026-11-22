import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 (findings H1, H4, H5, J1, J2; fix round 4: C1, C10, L1, L3, L4, L12, L14): the undo of a
/// whole-series delete of a series with no time zone, over a matrix of shapes, through the production
/// capture (`SeriesExceptionsUndo.capture`), the production resolution of a series whose first occurrence
/// is gone or edited (`FirstRemainingOccurrence.resolve`, `pick`) and the production undo arm
/// (`SeriesExceptionsUndo.undoDeleteEvent`) on the in-memory store, beside `main`'s own capture and undo
/// arm (`SeriesUndoOnMain`) on the same store. Modelled by the test, not production: whether the series
/// object refreshes, the recreated series' slots (`seriesSlots`), and what a delete through a stand-in
/// leaves (two models below).
///
/// A cell: a host at a fixed UTC offset (no daylight saving), a daily or weekly series of six occurrences
/// at 06:00 or 22:00, one occurrence retitled either while the series had no time zone (its `/RID=` digits
/// are that slot's wall-clock time written as UTC, #539) or while it had one (the slot's instant, #311),
/// the series' zone then cleared (L1, L3), then the whole series moved by a whole period or two either way,
/// a day minus the host's offset, minus or plus the offset, three hours, or not at all. Every occurrence
/// moves; the edited one keeps its `/RID=` (cell N1), which is then stale. Then some occurrences are
/// deleted on their own: none, the first, the one at a slot either reading of the edited occurrence's
/// `/RID=` names, the first and that one, or the fourth.
///
/// Two routes to the delete:
/// - `seriesObject`: the series object refreshes (a store other than iCloud): the capture is made from it,
///   and the recreated series starts at the rule's first slot.
/// - `standIn`: iCloud. The object refreshes only when its first slot holds a plain occurrence (#326);
///   otherwise the earliest plain occurrence stands in (`pick`, with the edited-before refusal), the
///   capture is made from it and the recreated series starts there. When no stand-in is accepted the
///   delete goes through the first edited occurrence (#428), which cannot be undone: no restorable
///   capture, and the cell is counted apart. What a delete from a stand-in leaves is not measured in
///   every shape, so two models: it removes every occurrence (`leavesNothing`), or it leaves the
///   occurrences before the stand-in (`leavesEarlier`). Device cell SA (2026-11-17) also saw the stand-in
///   itself left behind, on `main` and on this PR alike; that is `main`'s own defect (#561) and is
///   not modelled.
///
/// For every cell with a restorable capture (PR #558 fix round 4: the whole-series undo is `main`'s):
/// - the production undo leaves the calendar `main`'s leaves, with the same answer (its counts) and text,
///   each from its own capture;
/// - `main`'s calendar is sorted: as before the delete, as before with the first occurrence kept from the
///   rule (its answer says so), from the rules alone (its answer says the exceptions did not match), or
///   one the checks reject, among them two events at one start. The counts are pinned: they are `main`'s
///   own, recorded on #539, not this PR's;
/// - a cell whose edited `/RID=` reads as its slot (edited while zoned, or at offset 0), not moved, its
///   first occurrence plain, applies;
/// - where the delete's forecast can be read (the series object reached, its first occurrence plain),
///   the planner's forecast (`SeriesExceptionsPlanner.unplacedEdits`, from the test's first slot in the
///   host's zone) says the rules alone exactly when the undo applies nothing.
///
/// The two store-level paths share one resolution result and the recreated slots supplied by
/// the fixture, over six fixed offsets. Of the 15,696 cells, 2,324 fail resolution and run neither
/// undo. For the rest, each path captures, restores and produces its own answer. The copy is
/// from 92d9b796, whose corresponding bodies match origin/main at 7f75f97d.
/// Handler and wiring tests cover the separate preview and delete paths.
final class FloatingSeriesUndoMatrixTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    enum Leaves: String { case nothing = "leavesNothing", earlier = "leavesEarlier" }
    enum Route: Equatable {
        case seriesObject
        case standIn(Leaves)
        var label: String {
            switch self {
            case .seriesObject: return "object"
            case .standIn(let leaves): return "iCloud/\(leaves.rawValue)"
            }
        }
    }

    /// What the edited occurrence's `/RID=` digits are.
    enum RID: String { case floating, zoned }

    struct Cell {
        let host: TimeZone
        let step: TimeInterval
        let hourOfDay: Int
        let edited: Int
        let move: TimeInterval
        let deleted: [Int]
        let route: Route
        var rid: RID = .floating
        /// Occurrences in the series (six, or more for a series begun years before the delete).
        var count = 6
        /// The delete this many years after the series' first occurrence (0: thirty days before it).
        var yearsBefore = 0
        var label: String {
            (yearsBefore > 0 ? "begun \(yearsBefore) y before, " : "") + "host \(host.secondsFromGMT() / 60) min, step \(Int(step / 86_400)) d, \(hourOfDay):00, \(rid.rawValue) edit \(edited), "
                + "move \(move / 3_600) h, deleted \(deleted), \(route.label)"
        }
    }

    /// What `main`'s undo left in a cell with a restorable capture, or why there is none.
    enum Kind: String {
        case notRestorable, noCapture
        /// As before the delete.
        case asBefore
        /// As before with the first occurrence kept from the rule, which the answer says.
        case firstKeptFromRule
        /// The rules-alone calendar, with an answer that says the exceptions were not applied.
        case rulesAlone
        /// A calendar the checks reject: two events at one start, an occurrence lost or moved, or false counts.
        case rejected
    }

    struct Run {
        var kind: Kind
        /// Production against `main`, the forecast against the undo, a cell that must apply.
        var failures: [String] = []
        /// `main`'s calendar has two events at one start.
        var mainDuplicate = false
        /// The forecast could be read: whether it said the rules alone.
        var forecast: Bool? = nil
        /// `main`'s restore applied the recorded exceptions (its answer is not "not applied").
        var mainApplied = false
    }

    // MARK: - building a cell

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The `/RID=` digits of an occurrence edited while its series had no time zone: the slot's wall-clock
    /// time in `zone` written as UTC; while it had one: the slot's instant.
    private func rid(_ slot: Date, in zone: TimeZone, _ kind: RID) -> String {
        guard kind == .floating else { return "/RID=\(Int(slot.timeIntervalSinceReferenceDate))" }
        let utc = Calendar.gregorian(in: TimeZone(identifier: "UTC")!)
        let digits = utc.date(from: Calendar.gregorian(in: zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot))!
        return "/RID=\(Int(digits.timeIntervalSinceReferenceDate))"
    }

    private func original(_ cell: Cell) -> [Date] {
        let first = date(2027, 3, 1, cell.hourOfDay, in: cell.host)
        return (0..<cell.count).map { first.addingTimeInterval(Double($0) * cell.step) }
    }

    private func key(_ start: Date, _ title: String) -> String { "\(Int(start.timeIntervalSinceReferenceDate)) \(title)" }

    /// The undo of the recorded series on a fresh store whose recreated series generates `slots`, through
    /// the production arm or `main`'s: its outcome, text and the calendar it left (with `left`).
    private func undo(_ exceptions: SeriesExceptions, slots: [Date], host: TimeZone, left: [String],
                      frequency: EKRecurrenceFrequency, seriesZone: TimeZone?, onMain: Bool) throws
        -> (outcome: UndoEventOutcome?, text: String, calendar: [String], projection: [FakeSeriesExceptionsStore.CalendarRow]) {
        let recurrence = EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: EKRecurrenceEnd(occurrenceCount: slots.count))
        let recorded = UndoSnapshotFixtures.event(title: "Standup", startDate: slots[0],
                                                  recurrence: recurrence, timeZone: seriesZone)
            .withExceptions(exceptions).withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
        let after = FakeSeriesExceptionsStore()
        after.zone = host
        after.seriesSlots = slots
        let undone: (text: String, outcome: UndoEventOutcome?)
        if onMain {
            let main = try SeriesUndoOnMain.recreateDeletedEvent(recorded, calendar: recorded.calendarIdentifier, in: after)
            undone = (main.text, main.outcome)
        } else {
            undone = try SeriesExceptionsUndo.undoDeleteEvent(recorded, calendar: recorded.calendarIdentifier, in: after)
        }
        return (undone.outcome, undone.text, (after.events.map { key($0.start, $0.title) } + left).sorted(),
                after.calendarProjection)
    }

    /// Runs one cell.
    func run(_ cell: Cell) throws -> Run {
        let host = cell.host
        let original = original(cell)
        let moved = original.map { $0.addingTimeInterval(cell.move) }
        let store = FakeSeriesExceptionsStore()
        store.zone = host
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: moved)
        let edited = occurrences[cell.edited]
        let suffix = rid(original[cell.edited], in: host, cell.rid)
        edited.id = "S" + suffix
        edited.external = "X-S" + suffix
        edited.detached = true
        edited.hasRules = false
        edited.title = "Edited"
        for index in cell.deleted { store.drop(occurrences[index]) }
        let before = store.events.map { key($0.start, $0.title) }.sorted()

        // The route: the series object, or (iCloud, its first slot not a plain occurrence) a stand-in.
        let object = FakeSeriesExceptionsStore.Event(id: "S", external: "X-S", calendar: "C", title: "Standup", start: moved[0],
                                                     occurrenceDate: moved[0], hasRules: true)
        let firstIsPlain = store.events.contains { !$0.detached && UndoPostState.sameInstant($0.start, moved[0]) }
        let candidates = store.events.map { event in
            FirstRemainingOccurrence.Candidate(
                eventIdentifier: event.id, isDetached: event.detached, hasRecurrenceRules: event.hasRules, start: event.start,
                slot: UndoPostState.originalSlot(eventIdentifier: event.id, externalIdentifier: event.external, occurrenceDate: event.occurrenceDate),
                slotFromRID: FirstRemainingOccurrence.slotIsFromRID(eventIdentifier: event.id, externalIdentifier: event.external))
        }
        let resolved = FirstRemainingOccurrence.resolve(
            stored: object, refresh: { _ in cell.route == .seriesObject || firstIsPlain },
            standIn: { _ in FirstRemainingOccurrence.pick(candidates, identifier: "S").map { index in store.events[index] } })
        guard let resolved else {
            // #428: through the first edited occurrence, which records no restorable capture.
            return Run(kind: .notRestorable)
        }
        let now = cell.yearsBefore > 0 ? original[0].addingTimeInterval(Double(cell.yearsBefore) * 365 * day)
                                       : min(original[0], moved[0]).addingTimeInterval(-30 * day)
        let target = resolved.event
        let capture = SeriesExceptionsUndo.capture(of: target, in: store, now: now)
        let mainCapture = SeriesUndoOnMain.capture(of: target, in: store, now: now)
        var failures: [String] = []
        func fail(_ what: String) { failures.append("\(cell.label): \(what)") }
        guard let exceptions = capture, let mainExceptions = mainCapture else {
            if (capture == nil) != (mainCapture == nil) { fail("a capture where main has none, or the reverse") }
            return Run(kind: .noCapture, failures: failures)
        }
        let start = store.startDate(of: target)
        let ruleSlots = moved.filter { $0 >= start }
        var left: [String] = []
        if case .standIn(.earlier) = cell.route {
            left = store.events.filter { $0.start < start }.map { key($0.start, $0.title) }
        }
        let rulesAlone = (ruleSlots.map { key($0, "Standup") } + left).sorted()

        let frequency: EKRecurrenceFrequency = cell.step == day ? .daily : .weekly
        let seriesZone: TimeZone? = cell.rid == .zoned ? host : nil
        let production = try undo(exceptions, slots: ruleSlots, host: host, left: left,
                                  frequency: frequency, seriesZone: seriesZone, onMain: false)
        let main = try undo(mainExceptions, slots: ruleSlots, host: host, left: left,
                            frequency: frequency, seriesZone: seriesZone, onMain: true)
        if production.outcome != main.outcome { fail("answer \(String(describing: production.outcome)) where main \(String(describing: main.outcome))") }
        if production.text != main.text { fail("text \(production.text) where main \(main.text)") }
        if production.projection != main.projection {
            fail("left \(production.projection) where main left \(main.projection)")
        }

        // `main`'s calendar, sorted.
        guard case .seriesWithExceptions(let restore)? = main.outcome else {
            fail("no exceptions outcome on main: \(String(describing: main.outcome))")
            return Run(kind: .rejected, failures: failures)
        }
        let starts = main.calendar.map { $0.split(separator: " ")[0] }
        var run = Run(kind: .rejected)
        run.mainDuplicate = Set(starts).count != starts.count
        run.mainApplied = !restore.notApplied
        let anchor = "\(Int(start.timeIntervalSinceReferenceDate)) "
        if restore.notApplied {
            if main.calendar == rulesAlone { run.kind = .rulesAlone }
        } else {
            var firstKept = before.filter { !$0.hasPrefix(anchor) }
            firstKept = (firstKept + [key(start, "Standup")]).sorted()
            // The counts: a recreated slot removed with no event there before stayed deleted; each one-off was written.
            let kept = Set(main.calendar.filter { $0.hasSuffix(" Standup") }.map { String($0.split(separator: " ")[0]) })
            let removed = ruleSlots.filter { !kept.contains("\(Int($0.timeIntervalSinceReferenceDate))") }
            let stayed = removed.filter { slot in !before.contains { $0.hasPrefix("\(Int(slot.timeIntervalSinceReferenceDate)) ") } }.count
            let oneOffs = main.calendar.filter { $0.hasSuffix(" Edited") }.count - left.filter { $0.hasSuffix(" Edited") }.count
            let truthful = restore.stayedDeleted == stayed && restore.oneOffs == oneOffs
            if truthful, !run.mainDuplicate {
                if main.calendar == before { run.kind = .asBefore }
                else if main.calendar == firstKept, restore.firstOccurrenceKeptFromRule { run.kind = .firstKeptFromRule }
            }
        }
        if run.mainDuplicate { run.kind = .rejected }

        // An edit whose `/RID=` reads as its slot, not moved, the first occurrence plain: it must come back.
        let readsAsSlot = cell.rid == .zoned || host.secondsFromGMT() == 0
        if readsAsSlot, cell.move == 0, cell.edited != 0, !cell.deleted.contains(0), restore.notApplied {
            fail("applied nothing where the edit must come back")
        }

        // Compare the planner against the restore using the fixture's first slot and rule. These
        // inputs model the case where the manager can establish a plain first occurrence.
        if firstIsPlain {
            let rule = DeletedOccurrenceCheck.Rule(frequency: frequency, interval: 1, daysOfWeek: [], daysOfMonth: [],
                                                   endDate: nil, occurrenceCount: cell.count, hasOtherParts: false)
            if let edits = SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule], firstSlot: start, calendar: .gregorian(in: host)) {
                run.forecast = edits > 0
                if (edits > 0) != restore.notApplied { fail("forecast \(edits) where the undo applied \(restore.notApplied ? "nothing" : "the exceptions")") }
            }
        }
        run.failures = failures
        return run
    }

    // MARK: - the matrix

    private var hosts: [TimeZone] {
        [0, 8 * 60, -8 * 60, 5 * 60 + 45, 12 * 60, -12 * 60].map { TimeZone(secondsFromGMT: $0 * 60)! }
    }

    private func cells() -> [Cell] {
        var cells: [Cell] = []
        for host in hosts {
            let offset = TimeInterval(host.secondsFromGMT())
            for step in [day, 7 * day] {
                for hourOfDay in [6, 22] {
                    var moves: [TimeInterval] = []
                    for move in [0, step, -step, 2 * step, -2 * step, day - offset, -offset, offset, 3 * hour] where !moves.contains(move) {
                        moves.append(move)
                    }
                    for edited in [0, 1, 2, 4] {
                        for move in moves {
                            let probe = Cell(host: host, step: step, hourOfDay: hourOfDay, edited: edited, move: move, deleted: [], route: .seriesObject)
                            let original = original(probe)
                            let moved = original.map { $0.addingTimeInterval(move) }
                            // The slots either reading of the edited `/RID=` names.
                            let digits = original[edited].addingTimeInterval(offset)
                            let named = moved.indices.filter { index in
                                index != edited && (UndoPostState.sameInstant(moved[index], original[edited])
                                                    || UndoPostState.sameInstant(moved[index], digits))
                            }
                            var deletions: [[Int]] = [[]]
                            if edited != 0 { deletions.append([0]) }
                            for index in named {
                                deletions.append([index])
                                if edited != 0, index != 0 { deletions.append([0, index]) }
                            }
                            if edited != 3 { deletions.append([3]) }
                            var seen: [[Int]] = []
                            for deleted in deletions where !seen.contains(deleted) {
                                seen.append(deleted)
                                for route in [Route.seriesObject, .standIn(.nothing), .standIn(.earlier)] {
                                    for kind in [RID.floating, .zoned] {
                                        cells.append(Cell(host: host, step: step, hourOfDay: hourOfDay, edited: edited, move: move,
                                                          deleted: deleted, route: route, rid: kind))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // J1 (verify round 3): the window edges, where a stale record's true slot is outside every window and
        // its wall-clock reading names a slot inside one, deleted on its own (`windowEdgeCells`).
        return cells + windowEdgeCells()
    }

    /// J1's two shapes in every host, at 06:00 and 22:00, on the three routes: (i) a young weekly series moved
    /// one week later, the 210th occurrence edited and the 209th deleted, the window ending between them;
    /// (ii) a series begun three years before the delete, moved one week earlier, the second occurrence
    /// edited and the third deleted, the window starting after the second's true slot.
    private func windowEdgeCells() -> [Cell] {
        var cells: [Cell] = []
        for host in hosts {
            for hourOfDay in [6, 22] {
                for route in [Route.seriesObject, .standIn(.nothing), .standIn(.earlier)] {
                    cells.append(Cell(host: host, step: 7 * day, hourOfDay: hourOfDay, edited: 209, move: 7 * day, deleted: [208],
                                      route: route, count: 280))
                    cells.append(Cell(host: host, step: 7 * day, hourOfDay: hourOfDay, edited: 1, move: -7 * day, deleted: [2],
                                      route: route, count: 5 * 52 + 20, yearsBefore: 3))
                }
            }
        }
        return cells
    }

    /// Every cell of the matrix. The counts are printed for the round's record.
    func testEveryCellIsRestoredAsOnMain() throws {
        var failures: [String] = []
        var kinds: [String: Int] = [:]
        var byRID: [String: Int] = [:]
        var mainDuplicates = 0
        var forecasts: [String: Int] = [:]
        // `main`'s rejected and duplicate cells by the edit's `/RID=` kind, the host at offset 0 or not, and
        // whether `main` applied the record (the shape the earlier rounds' 40 and 6 were counted in is
        // floating, offset not 0, applied).
        var rejectedBy: [String: Int] = [:]
        var duplicateBy: [String: Int] = [:]
        let all = cells()
        for cell in all {
            let run = try run(cell)
            kinds[run.kind.rawValue, default: 0] += 1
            byRID["\(cell.rid.rawValue) \(run.kind.rawValue)", default: 0] += 1
            failures += run.failures
            if run.mainDuplicate { mainDuplicates += 1 }
            let bucket = "\(cell.rid.rawValue) \(cell.host.secondsFromGMT() == 0 ? "offset0" : "offsetN") \(run.mainApplied ? "applied" : "notApplied")"
            if run.kind == .rejected { rejectedBy[bucket, default: 0] += 1 }
            if run.mainDuplicate { duplicateBy[bucket, default: 0] += 1 }
            if let forecast = run.forecast { forecasts[forecast ? "rulesAlone" : "none", default: 0] += 1 }
        }
        let redCells = Set(failures.map { $0.components(separatedBy: ": ")[0] }).count
        print("MATRIX cells \(all.count) main's kinds \(kinds.sorted { $0.key < $1.key }) main's duplicates \(mainDuplicates) red \(redCells)")
        print("MATRIX by rid \(byRID.sorted { $0.key < $1.key })")
        print("MATRIX forecasts \(forecasts.sorted { $0.key < $1.key })")
        print("MATRIX main rejected by \(rejectedBy.sorted { $0.key < $1.key }) duplicates by \(duplicateBy.sorted { $0.key < $1.key })")
        XCTAssertEqual(redCells, 0, failures.prefix(12).joined(separator: "\n"))
        // `main`'s own outcomes over the matrix, recorded on #539 (PR #558 fix round 4): a change of the
        // undo that moves a cell from one outcome to another shows here, and so does a change of the cells.
        XCTAssertEqual(all.count, 15696)
        XCTAssertEqual(kinds, ["notRestorable": 2324, "asBefore": 2234, "firstKeptFromRule": 660, "rulesAlone": 7646, "rejected": 2832])
        XCTAssertEqual(byRID, ["floating notRestorable": 1188, "floating asBefore": 746, "floating firstKeptFromRule": 260,
                               "floating rulesAlone": 5078, "floating rejected": 612,
                               "zoned notRestorable": 1136, "zoned asBefore": 1488, "zoned firstKeptFromRule": 400,
                               "zoned rulesAlone": 2568, "zoned rejected": 2220])
        // Of `main`'s rejected calendars, those with two events at one start (L12: counted by a check, not stated).
        XCTAssertEqual(mainDuplicates, 326)
        // Where the forecast can be read it agreed with the undo in every cell (checked per cell above).
        XCTAssertEqual(forecasts, ["none": 3264, "rulesAlone": 4752])
        XCTAssertEqual(rejectedBy, ["floating offsetN applied": 230, "floating offset0 applied": 382,
                                    "zoned offsetN applied": 1850, "zoned offset0 applied": 370])
        XCTAssertEqual(duplicateBy, ["floating offsetN applied": 6, "floating offset0 applied": 56,
                                     "zoned offsetN applied": 220, "zoned offset0 applied": 44])
    }

    // MARK: - named cells

    /// H1 (verify round 2, Codex): the second occurrence edited, the series moved one day later, the new
    /// first occurrence deleted on its own; the series object refreshes. As on `main`.
    // spec-example: undo-history-discard / H1
    func testH1IsRestoredAsOnMain() throws {
        let cell = Cell(host: TimeZone(secondsFromGMT: 8 * 3600)!, step: day, hourOfDay: 6, edited: 1, move: day, deleted: [0], route: .seriesObject)
        XCTAssertEqual(try run(cell).failures, [])
    }

    /// H4, H5: the first occurrence edited, the series moved one day earlier, the occurrence now on the second
    /// slot (the stale record's wall-clock reading) deleted on its own; the series object refreshes. As on
    /// `main`.
    func testH4IsRestoredAsOnMain() throws {
        let cell = Cell(host: TimeZone(secondsFromGMT: 8 * 3600)!, step: day, hourOfDay: 6, edited: 0, move: -day, deleted: [1], route: .seriesObject)
        XCTAssertEqual(try run(cell).failures, [])
    }

    /// The first occurrence edited, the series moved two days earlier, the slot the stale record's
    /// wall-clock reading names deleted on its own, through iCloud's stand-in. As on `main`.
    func testTheStandInRouteIsRestoredAsOnMain() throws {
        for leaves in [Leaves.nothing, .earlier] {
            let cell = Cell(host: TimeZone(secondsFromGMT: 8 * 3600)!, step: day, hourOfDay: 6, edited: 0, move: -2 * day, deleted: [2],
                            route: .standIn(leaves))
            XCTAssertEqual(try run(cell).failures, [], leaves.rawValue)
        }
    }

    /// J1 (verify round 3): a stale record whose true slot lies outside every window while its wall-clock
    /// reading names a slot inside one that was deleted on its own, both shapes. As on `main`.
    func testJ1IsRestoredAsOnMain() throws {
        for host in hosts where host.secondsFromGMT() != 0 {
            for route in [Route.seriesObject, .standIn(.nothing), .standIn(.earlier)] {
                let late = Cell(host: host, step: 7 * day, hourOfDay: 6, edited: 209, move: 7 * day, deleted: [208], route: route,
                                count: 280)
                let early = Cell(host: host, step: 7 * day, hourOfDay: 6, edited: 1, move: -7 * day, deleted: [2], route: route,
                                 count: 5 * 52 + 20, yearsBefore: 3)
                for cell in [late, early] {
                    XCTAssertEqual(try run(cell).failures, [], cell.label)
                }
            }
        }
    }

    /// A series begun five years before the delete, its first occurrence outside every window (#319), an
    /// occurrence edited while it had no time zone, not moved: as on `main`, the edit comes back only where
    /// its `/RID=` read as an instant is its slot (at offset 0), and with an edit made while the series had
    /// its zone (L1, L3) everywhere.
    func testASeriesBegunBeforeTheWindowIsRestoredAsOnMain() throws {
        for host in hosts {
            for kind in [RID.floating, .zoned] {
                let cell = Cell(host: host, step: 7 * day, hourOfDay: 6, edited: 5 * 52 + 2, move: 0, deleted: [5 * 52 + 4], route: .seriesObject,
                                rid: kind, count: 5 * 52 + 20, yearsBefore: 5)
                let run = try run(cell)
                XCTAssertEqual(run.failures, [], cell.label)
                let comesBack = kind == .zoned || host.secondsFromGMT() == 0
                XCTAssertEqual(run.kind, comesBack ? .asBefore : .rulesAlone, cell.label)
            }
        }
    }
}
