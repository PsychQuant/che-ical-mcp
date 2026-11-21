import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 fix round 4 (verify finding C1, Codex): the chained undo of a series whose occurrence was
/// deleted on its own before the whole series was. Each sequence runs twice on the same in-memory store
/// setup, once through this server's production path (`SeriesExceptionsUndo.capture`, `undoDeleteEvent`,
/// `undoDeleteOccurrence`, the origin as a delete through the occurrence's own identifier records it) and
/// once through `main`'s (`SeriesUndoOnMain`), and the two must leave the same calendar with the same
/// answers. Each test names its host zone; none reads the process's.
///
/// The sequences: two occurrences, A and B, are retitled while the series has a time zone, so their
/// `/RID=` digits are instants (#311); the series is then given no time zone (`clear_timezone`) without
/// changing its times; A is deleted through its own identifier; then the whole series is deleted; then
/// the whole-series delete is undone, and then A's delete.
/// - (a) Nothing else. `main` applies B's record, keeps A's slot deleted, and A's undo writes A once with
///   its edit. Restored from its rules alone (PR #558 round 3, at `eb568983`), A's slot came back plain and
///   A's undo found it held: the entry used up, A's edit lost.
/// - (b) The zoned series was moved three hours later after A was edited and before B was (B's `/RID=` is
///   at the new time, A's stays at the old one, as on iCloud, cell N1), then given no time zone. `main`
///   again keeps A's slot deleted and A's undo writes A once. Restored from its rules alone, A's slot came
///   back plain at the new time; neither reading of A's stale `/RID=` is a slot, so A's undo wrote A
///   beside it: two events at one start.
final class WholeSeriesUndoChainOnMainTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    /// Fixed offsets (no daylight saving): east, west, a quarter-hour offset, and UTC.
    private var hosts: [TimeZone] { [8 * 60, -8 * 60, 5 * 60 + 45, 0].map { TimeZone(secondsFromGMT: $0 * 60)! } }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The suffix of an occurrence edited while its series had a time zone: the slot's instant (#311).
    private func zonedRID(_ slot: Date) -> String { "/RID=\(Int(slot.timeIntervalSinceReferenceDate))" }

    private func edit(_ occurrence: FakeSeriesExceptionsStore.Event, rid: String, title: String) {
        occurrence.id = "S" + rid
        occurrence.external = "X-S" + rid
        occurrence.detached = true
        occurrence.hasRules = false
        occurrence.title = title
    }

    private func key(_ event: FakeSeriesExceptionsStore.Event) -> String { "\(Int(event.start.timeIntervalSinceReferenceDate)) \(event.title)" }

    /// What one path left: the answers of the two undos and the calendar after them.
    struct Chain: Equatable {
        var series: String
        var occurrence: String
        var calendar: [String]
    }

    /// One path of the sequence. `store` holds the series as it was just before A's delete; `a` is A.
    private func run(onMain: Bool, store: FakeSeriesExceptionsStore, a: FakeSeriesExceptionsStore.Event,
                     first: FakeSeriesExceptionsStore.Event, slots: [Date], host: TimeZone) throws -> Chain {
        // A's delete through its own identifier: its origin. In production the series' zone is read on the
        // series object (ruling J), which has none now; `main` read none.
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: a.id, externalIdentifier: a.external,
                                                       occurrenceDate: a.occurrenceDate, isAllDay: false, isDetached: true,
                                                       floating: !onMain, zone: host))
        let record = UndoSnapshotFixtures.event(title: a.title, startDate: a.start).withOccurrenceOrigin(origin)
        store.drop(a)
        // The whole series' delete, thirty days before its first occurrence.
        let now = slots[0].addingTimeInterval(-30 * day)
        let exceptions = try XCTUnwrap(onMain ? SeriesUndoOnMain.capture(of: first, in: store, now: now)
                                              : SeriesExceptionsUndo.capture(of: first, in: store, now: now, zone: host))
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: slots.count, startDate: slots[0])
            .withExceptions(exceptions).withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
        let after = FakeSeriesExceptionsStore()
        after.zone = host
        after.seriesSlots = slots
        let calendar = series.calendarIdentifier
        let seriesOutcome = onMain ? try SeriesUndoOnMain.recreateDeletedEvent(series, calendar: calendar, in: after).outcome
                                   : try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: calendar, in: after).outcome
        let occurrenceAnswer: String
        do {
            let outcome = onMain ? try SeriesUndoOnMain.undoDeleteOccurrence(record, notCarriedOver: [], calendar: calendar, in: after).outcome
                                 : try SeriesExceptionsUndo.undoDeleteOccurrence(record, notCarriedOver: [], calendar: calendar, in: after).outcome
            occurrenceAnswer = "\(outcome)"
        } catch {
            occurrenceAnswer = "refused \(type(of: error))"
        }
        return Chain(series: "\(String(describing: seriesOutcome))", occurrence: occurrenceAnswer, calendar: after.events.map(key).sorted())
    }

    /// Builds the store of a sequence and runs both paths on a copy each.
    private func compare(_ host: TimeZone, moveBeforeB: TimeInterval, file: StaticString = #filePath, line: UInt = #line) throws
        -> (production: Chain, main: Chain) {
        func build() -> (store: FakeSeriesExceptionsStore, a: FakeSeriesExceptionsStore.Event, first: FakeSeriesExceptionsStore.Event, slots: [Date]) {
            let original = (0..<6).map { date(2027, 3, 1, 10, in: host).addingTimeInterval(Double($0) * 7 * day) }
            let store = FakeSeriesExceptionsStore()
            store.zone = host
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: original)
            // A, the second occurrence, retitled while the series had its zone.
            edit(occurrences[1], rid: zonedRID(original[1]), title: "A edited")
            // (b): the whole zoned series moved; every occurrence moves, A keeps its `/RID=` (cell N1).
            let moved = original.map { $0.addingTimeInterval(moveBeforeB) }
            for (index, occurrence) in occurrences.enumerated() {
                occurrence.start = moved[index]
                if !occurrence.detached { occurrence.occurrenceDate = moved[index] }
            }
            // B, the fourth, retitled while the series had its zone, at its time now.
            edit(occurrences[3], rid: zonedRID(moved[3]), title: "B edited")
            // `clear_timezone` at the same wall-clock time: the instants stay.
            for occurrence in occurrences { occurrence.floating = true }
            return (store, occurrences[1], occurrences[0], moved)
        }
        let production = build()
        let main = build()
        return (try run(onMain: false, store: production.store, a: production.a, first: production.first, slots: production.slots, host: host),
                try run(onMain: true, store: main.store, a: main.a, first: main.first, slots: main.slots, host: host))
    }

    /// (a): no move. The undo of A's delete writes A once with its edit, as on `main`.
    // spec-example: undo-history-discard / C1 the older record writes its edit as on main
    func testC1AnOccurrenceDeletedOnItsOwnBeforeTheSeriesComesBackWithItsEditAsOnMain() throws {
        for host in hosts {
            let (production, main) = try compare(host, moveBeforeB: 0)
            XCTAssertEqual(production, main, "host \(host.secondsFromGMT() / 60) min")
            XCTAssertEqual(main.calendar.filter { $0.hasSuffix(" A edited") }.count, 1, "main writes A once")
        }
    }

    /// (b): the zoned series moved three hours later between the two edits. No two events at one start, as
    /// on `main`.
    // spec-example: undo-history-discard / C1 no second event after a move
    func testC1AStaleRecordOfAnOccurrenceDeletedOnItsOwnWritesNoSecondEvent() throws {
        for host in hosts {
            let (production, main) = try compare(host, moveBeforeB: 3 * hour)
            XCTAssertEqual(production, main, "host \(host.secondsFromGMT() / 60) min")
            let starts = production.calendar.map { $0.split(separator: " ")[0] }
            XCTAssertEqual(Set(starts).count, starts.count, "two events at one start: \(production.calendar)")
        }
    }
}
