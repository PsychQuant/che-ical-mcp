import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 round 2 (findings H1, H4, H5; ruling I): the undo of a whole-series delete of a series with no
/// time zone, over a matrix of shapes, through the production capture (`SeriesExceptionsUndo.capture`), the
/// production resolution of a series whose first occurrence is gone or edited
/// (`FirstRemainingOccurrence.resolve`, `pick`, `earliestEdited`) and the production undo arm
/// (`SeriesExceptionsUndo.undoDeleteEvent`) on the in-memory store.
///
/// A cell: a host at a fixed UTC offset (no daylight saving), a daily or weekly series of six occurrences
/// at 06:00 or 22:00, one occurrence retitled while the series had no time zone (its `/RID=` digits are
/// that slot's wall-clock time written as UTC, #539), then the whole series moved by a whole period or
/// two either way, a day minus the host's offset, minus or plus the offset, three hours, or not at all.
/// Every occurrence moves; the edited one keeps its `/RID=` (cell N1), which is then stale. Then some
/// occurrences are deleted on their own: none, the first, the one at a slot either reading of the
/// edited occurrence's `/RID=` names, the first and that one, or the fourth.
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
///   itself left behind, on `main` and on this PR alike; that is `main`'s own defect (filed apart) and is
///   not modelled: a recreated series starting at a left stand-in would be a second event there on any
///   build.
///
/// For every cell with a restorable capture:
/// - no two events share a start after the undo;
/// - an undo that says it applied no exception leaves the rules-alone calendar: the recreated series'
///   slots, untitled, and what the delete left;
/// - an undo that applied the exceptions leaves the calendar as it was before the delete, except that a
///   first occurrence deleted or edited on its own is kept from the rule when the answer says so; and its
///   counts are what happened (an occurrence counted as deleted on its own stayed deleted is a slot of the
///   recreated series that had no event before the delete, each one-off counted is written);
/// - a cell whose records have one reading (a host at offset 0) restores as `main` did;
/// - a cell that must apply (no move, the first occurrence plain) applies.
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

    struct Cell {
        let host: TimeZone
        let step: TimeInterval
        let hourOfDay: Int
        let edited: Int
        let move: TimeInterval
        let deleted: [Int]
        let route: Route
        /// Occurrences in the series (six, or more for a series begun years before the delete).
        var count = 6
        /// The delete this many years after the series' first occurrence (0: thirty days before it).
        var yearsBefore = 0
        var label: String {
            (yearsBefore > 0 ? "begun \(yearsBefore) y before, " : "") + "host \(host.secondsFromGMT() / 60) min, step \(Int(step / 86_400)) d, \(hourOfDay):00, edited \(edited), "
                + "move \(move / 3_600) h, deleted \(deleted), \(route.label)"
        }
    }

    /// What a cell came to.
    enum Kind: Equatable { case notRestorable, noCapture, oneReading, twoApplied, twoNotApplied }

    struct Run {
        var kind: Kind
        var failures: [String] = []
        /// A one-reading cell that restores as `main` does, where `main` itself leaves a calendar these
        /// checks reject (a stale `/RID=` after a move by a whole period, read at offset 0: #560's shape on a
        /// series with no time zone). Counted apart; it is not this PR's path.
        var asOnMain: [String] = []
    }

    // MARK: - building a cell

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The `/RID=` digits of an occurrence edited while its series had no time zone: the slot's wall-clock
    /// time in `zone` written as UTC.
    private func floatingRID(_ slot: Date, in zone: TimeZone) -> String {
        let utc = Calendar.gregorian(in: TimeZone(identifier: "UTC")!)
        let digits = utc.date(from: Calendar.gregorian(in: zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot))!
        return "/RID=\(Int(digits.timeIntervalSinceReferenceDate))"
    }

    private func original(_ cell: Cell) -> [Date] {
        let first = date(2027, 3, 1, cell.hourOfDay, in: cell.host)
        return (0..<cell.count).map { first.addingTimeInterval(Double($0) * cell.step) }
    }

    private func key(_ start: Date, _ title: String) -> String { "\(Int(start.timeIntervalSinceReferenceDate)) \(title)" }

    /// Runs one cell; `restoredOnMain` in the result compares a one-reading cell with `main`'s restore.
    func run(_ cell: Cell, mustApply: Bool = false) throws -> Run {
        let host = cell.host
        let original = original(cell)
        let moved = original.map { $0.addingTimeInterval(cell.move) }
        let store = FakeSeriesExceptionsStore()
        store.zone = host
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: moved, floating: true)
        let edited = occurrences[cell.edited]
        let rid = floatingRID(original[cell.edited], in: host)
        edited.id = "S" + rid
        edited.external = "X-S" + rid
        edited.detached = true
        edited.hasRules = false
        edited.title = "Edited"
        for index in cell.deleted { store.drop(occurrences[index]) }
        let before = store.events.map { key($0.start, $0.title) }.sorted()

        // The route: the series object, or (iCloud, its first slot not a plain occurrence) a stand-in.
        let object = FakeSeriesExceptionsStore.Event(id: "S", external: "X-S", calendar: "C", title: "Standup", start: moved[0],
                                                     occurrenceDate: moved[0], hasRules: true)
        object.floating = true
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
            _ = FirstRemainingOccurrence.earliestEdited(candidates, identifier: "S", zone: host)
            return Run(kind: .notRestorable)
        }
        let now = cell.yearsBefore > 0 ? original[0].addingTimeInterval(Double(cell.yearsBefore) * 365 * day)
                                       : min(original[0], moved[0]).addingTimeInterval(-30 * day)
        let target = resolved.event
        let capture = SeriesExceptionsUndo.capture(of: target, in: store, now: now, zone: host, viaStandIn: resolved.viaStandIn)
        guard let exceptions = capture else { return Run(kind: .noCapture) }
        let start = store.startDate(of: target)
        let ruleSlots = moved.filter { $0 >= start }
        var left: [String] = []
        if case .standIn(.earlier) = cell.route {
            left = store.events.filter { $0.start < start }.map { key($0.start, $0.title) }
        }
        let rulesAlone = (ruleSlots.map { key($0, "Standup") } + left).sorted()

        let recorded = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: ruleSlots.count, startDate: start)
            .withExceptions(exceptions).withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
        let after = FakeSeriesExceptionsStore()
        after.zone = host
        after.seriesSlots = ruleSlots
        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(recorded, calendar: recorded.calendarIdentifier, in: after)
        let final = (after.events.map { key($0.start, $0.title) } + left).sorted()

        let twoReadings = exceptions.detached.contains { $0.readings.wallClock != nil }
        var run = Run(kind: .oneReading)
        var issues: [String] = []
        func fail(_ what: String) { issues.append("\(cell.label): \(what)") }

        let starts = final.map { $0.split(separator: " ")[0] }
        if Set(starts).count != starts.count { fail("two events at one start: \(final)") }

        guard case .seriesWithExceptions(let restore)? = outcome else {
            fail("no exceptions outcome: \(String(describing: outcome))")
            run.failures = issues
            return run
        }
        if restore.notApplied {
            if final != rulesAlone { fail("said rules alone, left \(final), rules alone \(rulesAlone)") }
            if !text.contains("Restored from the series rules alone") { fail("text: \(text)") }
            if mustApply { fail("applied nothing where the edit must come back") }
        } else {
            // Applied: the calendar as before the delete, the anchor kept from the rule when the answer says so.
            let anchorWasPlain = before.contains(key(start, "Standup"))
            let anchorInWindow = SeriesExceptionsPlanner.inWindows(start, exceptions.windows)
            var expected = before
            if restore.firstOccurrenceKeptFromRule {
                expected.removeAll { $0.hasPrefix("\(Int(start.timeIntervalSinceReferenceDate)) ") }
                expected = (expected + [key(start, "Standup")]).sorted()
            }
            if final != expected { fail("applied, left \(final), before \(before), answer \(restore)") }
            if restore.firstOccurrenceKeptFromRule == anchorWasPlain, anchorInWindow { fail("first kept flag \(restore.firstOccurrenceKeptFromRule)") }
            // Ruling I: with a record of two readings, a first slot kept from the rule only outside every window.
            if twoReadings, restore.firstOccurrenceKeptFromRule, anchorInWindow { fail("two readings applied with the first slot not plain") }
            // The counts: a slot of the recreated series removed with no event there before stayed deleted;
            // each one-off counted was written.
            let recreatedID = after.events.first { $0.hasRules }?.id
            let remaining = Set(after.events.filter { $0.id == recreatedID }.map(\.start))
            let removed = ruleSlots.filter { !remaining.contains($0) }
            let stayed = removed.filter { slot in !before.contains { $0.hasPrefix("\(Int(slot.timeIntervalSinceReferenceDate)) ") } }.count
            let oneOffs = after.events.filter { !$0.hasRules }.count
            if restore.stayedDeleted != stayed { fail("stayedDeleted \(restore.stayedDeleted), true \(stayed)") }
            if restore.oneOffs != oneOffs { fail("oneOffs \(restore.oneOffs), written \(oneOffs)") }
        }
        if twoReadings {
            run.kind = restore.notApplied ? .twoNotApplied : .twoApplied
            run.failures = issues
        } else {
            // One reading: `main`'s restore of the same record on the same recreated series.
            let current = restoreAtStoreLevel(exceptions, slots: ruleSlots, zone: host, onMain: false)
            let main = restoreAtStoreLevel(exceptions, slots: ruleSlots, zone: host, onMain: true)
            if current.answer != main.answer || current.left != main.left {
                run.failures = issues + ["\(cell.label): one reading, \(current.answer) where main \(main.answer)"]
            } else {
                run.asOnMain = issues
            }
        }
        return run
    }

    /// The store-level restore of `exceptions` on a store whose recreated series ("R") generates `slots`.
    private func restoreAtStoreLevel(_ exceptions: SeriesExceptions, slots: [Date], zone: TimeZone, onMain: Bool) -> (answer: String, left: [String]) {
        let store = FakeSeriesExceptionsStore()
        store.zone = zone
        let restored = FakeSeriesExceptionsStore.Event(id: "R", external: "X-R", calendar: "C", title: "Standup", start: slots[0],
                                                      occurrenceDate: slots[0], hasRules: true)
        store.add(restored)
        for slot in slots.dropFirst() {
            store.add(FakeSeriesExceptionsStore.Event(id: "R", external: "X-R", calendar: "C", title: "Standup", start: slot,
                                                      occurrenceDate: slot, hasRules: true))
        }
        let answer: String
        do {
            let outcome = onMain ? try SeriesExceptionsUndo.restoreOnMain(exceptions, of: restored, in: store)
                                 : try SeriesExceptionsUndo.restore(exceptions, of: restored, in: store)
            answer = "\(outcome)"
        } catch {
            answer = "threw \(error)"
        }
        return (answer, store.events.map { key($0.start, $0.title) }.sorted())
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
                                    cells.append(Cell(host: host, step: step, hourOfDay: hourOfDay, edited: edited, move: move,
                                                      deleted: deleted, route: route))
                                }
                            }
                        }
                    }
                }
            }
        }
        return cells
    }

    /// Every cell of the matrix. The counts are printed for the round's record.
    func testEveryCellLeavesTheCalendarAsBeforeOrAsTheRulesAlone() throws {
        var failures: [String] = []
        var kinds: [String: Int] = [:]
        var twoReadingFailures = 0
        var asOnMain = 0
        let all = cells()
        for cell in all {
            // No move and the first occurrence plain: the edit must come back on every build.
            let mustApply = cell.move == 0 && cell.edited != 0 && !cell.deleted.contains(0)
            let run = try run(cell, mustApply: mustApply)
            kinds["\(run.kind)", default: 0] += 1
            failures += run.failures
            if !run.asOnMain.isEmpty { asOnMain += 1 }
            if !run.failures.isEmpty, run.kind == .twoApplied || run.kind == .twoNotApplied { twoReadingFailures += 1 }
        }
        let redLabels = Set(failures.map { $0.components(separatedBy: ": ")[0] })
        let redCells = redLabels.count
        let byRoute = Dictionary(grouping: redLabels) { label in label.components(separatedBy: ", ").last ?? "" }.mapValues(\.count)
        print("MATRIX red by route \(byRoute.sorted { $0.key < $1.key })")
        print("MATRIX cells \(all.count) kinds \(kinds.sorted { $0.key < $1.key }) red \(redCells) two-reading red \(twoReadingFailures) one-reading as on main but rejected \(asOnMain)")
        XCTAssertEqual(redCells, 0, failures.prefix(12).joined(separator: "\n"))
        // The totals of the round's record (PR #558 round 2): a change of the restore that moves a cell from
        // one outcome to another shows here.
        XCTAssertEqual(all.count, 7812)
        XCTAssertEqual(kinds["notRestorable"], 1188)
        XCTAssertEqual(kinds["oneReading"], 1044)
        XCTAssertEqual(kinds["twoApplied"], 1236)
        XCTAssertEqual(kinds["twoNotApplied"], 4344)
        XCTAssertEqual(asOnMain, 452)
    }

    // MARK: - named cells

    /// H1 (verify round 2, Codex): the second occurrence edited, the series moved one day later, the new
    /// first occurrence deleted on its own; the series object refreshes. The stale record's wall-clock
    /// reading is the first slot, which held no plain occurrence: placed there before ruling I, its true
    /// slot was removed and no one-off written (the occurrence lost).
    // spec-example: undo-history-discard / H1
    func testH1TheEditedOccurrenceIsNotLostWhenTheFirstWasDeleted() throws {
        let cell = Cell(host: TimeZone(secondsFromGMT: 8 * 3600)!, step: day, hourOfDay: 6, edited: 1, move: day, deleted: [0], route: .seriesObject)
        XCTAssertEqual(try run(cell).failures, [])
    }

    /// H4, H5: the first occurrence edited, the series moved one day earlier, the occurrence now on the second
    /// slot (the stale record's wall-clock reading) deleted on its own; the series object refreshes. Before
    /// ruling I the record was placed there and the first slot came back from the rule too: two events.
    func testH4NoSecondEventWhenTheFirstWasEditedAndMovedEarlier() throws {
        let cell = Cell(host: TimeZone(secondsFromGMT: 8 * 3600)!, step: day, hourOfDay: 6, edited: 0, move: -day, deleted: [1], route: .seriesObject)
        XCTAssertEqual(try run(cell).failures, [])
    }

    /// The shape of the 40 cells ruling I (b) alone left red (device cell SA): the first occurrence edited, the
    /// series moved two days earlier, the slot the stale record's wall-clock reading names deleted on its own;
    /// on iCloud a stand-in is accepted (the record's instant reading falls after it), so the recreated series
    /// starts at a kept slot. Ruling I (a): through a stand-in, nothing is applied.
    func testSATheStandInRouteAppliesNothingForAStaleRecord() throws {
        for leaves in [Leaves.nothing, .earlier] {
            let cell = Cell(host: TimeZone(secondsFromGMT: 8 * 3600)!, step: day, hourOfDay: 6, edited: 0, move: -2 * day, deleted: [2],
                            route: .standIn(leaves))
            let run = try run(cell)
            XCTAssertEqual(run.failures, [], leaves.rawValue)
            XCTAssertEqual(run.kind, .twoNotApplied, leaves.rawValue)
        }
    }

    /// A series begun five years before the delete, its first occurrence outside every window (#319): an
    /// occurrence edited while it had no time zone, not moved, comes back as a one-off. Ruling I (b) asks the
    /// first slot only inside a window; outside one it would apply nothing for every such series.
    func testASeriesBegunBeforeTheWindowStillGetsItsEditBack() throws {
        for host in hosts where host.secondsFromGMT() != 0 {
            for route in [Route.seriesObject, .standIn(.nothing)] {
                let cell = Cell(host: host, step: 7 * day, hourOfDay: 6, edited: 5 * 52 + 2, move: 0, deleted: [5 * 52 + 4], route: route,
                                count: 5 * 52 + 20, yearsBefore: 5)
                let run = try run(cell, mustApply: true)
                XCTAssertEqual(run.failures, [], cell.label)
                XCTAssertEqual(run.kind, .twoApplied, cell.label)
            }
        }
    }
}
