import XCTest
import EventKit
@testable import CheICalMCP

/// #285: the restore sequence after undo recreated the series from its rules: remove the surplus
/// slots (two-pass, #182), then recreate the occurrences edited on their own as one-off events,
/// all or nothing. Closure seams stand in for EventKit; the closures log what they were asked to do.
final class SeriesExceptionsRestorerTests: XCTestCase {

    private func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private let slots = ["2028-04-03T10:00:00+08:00", "2028-04-10T10:00:00+08:00",
                         "2028-04-17T10:00:00+08:00", "2028-04-24T10:00:00+08:00"]

    private var window: DateInterval {
        DateInterval(start: at("2028-04-02T10:00:00+08:00"), end: at("2028-04-25T10:00:00+08:00"))
    }

    private func detached(_ title: String, slot: String) -> DetachedOccurrence {
        DetachedOccurrence(slot: at(slot), snapshot: UndoSnapshotFixtures.event(title: title, startDate: at(slot)))
    }

    private struct Boom: Error {}

    /// Slot 1 and 4 kept, slot 2 edited, slot 3 deleted on its own, as in the on-device spike.
    private var spikeExceptions: SeriesExceptions {
        SeriesExceptions(window: window, keptSlots: [at(slots[0]), at(slots[3])],
                         detached: [detached("Standup (moved room)", slot: slots[1])])
    }

    private final class Log {
        var removed: [Date] = []
        var created: [String] = []
        var rolledBack = 0
        var removedOneOffs: [String] = []
        var events: [String] = []
    }

    private func run(_ exceptions: SeriesExceptions, generated: [Date]? = nil, log: Log = Log(),
                     failRemoveAt: Date? = nil, failCreateTitle: String? = nil, failRollback: Bool = false,
                     failOneOffCleanup: Bool = false) throws -> (SeriesExceptionsRestorer.Outcome, Log) {
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: exceptions,
            generated: (generated ?? slots.map(at)).map { (slot: $0, occurrence: $0) },
            remove: { date in
                if let failRemoveAt, UndoPostState.sameInstant(date, failRemoveAt) { throw Boom() }
                log.removed.append(date); log.events.append("remove")
            },
            createOneOff: { detached in
                if detached.snapshot.title == failCreateTitle { throw Boom() }
                log.created.append(detached.snapshot.title); log.events.append("create")
                return detached.snapshot.title
            },
            removeOneOff: { handle in
                if failOneOffCleanup { throw Boom() }
                log.removedOneOffs.append(handle)
            },
            rollbackSeries: {
                log.rolledBack += 1
                if failRollback { throw Boom() }
            })
        return (outcome, log)
    }

    func testRemovesTheSurplusSlotsThenCreatesTheOneOffs() throws {
        let (outcome, log) = try run(spikeExceptions)
        XCTAssertEqual(log.removed, [at(slots[1]), at(slots[2])])
        XCTAssertEqual(log.created, ["Standup (moved room)"])
        XCTAssertEqual(log.events, ["remove", "remove", "create"])   // the order the spike verified
        XCTAssertEqual(outcome.stayedDeleted, 1)                     // slot 3
        XCTAssertEqual(outcome.oneOffs, 1)                           // slot 2
        XCTAssertEqual(log.rolledBack, 0)
    }

    func testNothingToDoWhenTheRecreatedSeriesIsExactlyTheKeptSlots() throws {
        let exceptions = SeriesExceptions(window: window, keptSlots: slots.map(at), detached: [])
        let (outcome, log) = try run(exceptions)
        XCTAssertEqual(log.events, [])
        XCTAssertEqual(outcome.stayedDeleted, 0)
        XCTAssertEqual(outcome.oneOffs, 0)
    }

    func testTailDeleteCarriedByTheRuleRemovesNothing() throws {
        let exceptions = SeriesExceptions(window: window, keptSlots: slots.prefix(3).map(at), detached: [])
        let (_, log) = try run(exceptions, generated: slots.prefix(3).map(at))
        XCTAssertEqual(log.events, [])
    }

    func testOccurrencesOutsideTheWindowAreNotTouched() throws {
        let exceptions = SeriesExceptions(window: window, keptSlots: slots.map(at), detached: [])
        let (_, log) = try run(exceptions, generated: slots.map(at) + [at("2028-05-01T10:00:00+08:00")])
        XCTAssertEqual(log.removed, [])
    }

    func testAFailedRemovalRollsTheSeriesBackAndCreatesNothing() {
        let log = Log()
        XCTAssertThrowsError(try run(spikeExceptions, log: log, failRemoveAt: at(slots[2]))) { error in
            XCTAssertEqual(error as? SeriesExceptionsRestoreError, .removeFailed(at(slots[2])))
        }
        XCTAssertEqual(log.rolledBack, 1)
        XCTAssertEqual(log.created, [])
    }

    func testAFailedOneOffRemovesTheEarlierOnesAndTheSeries() {
        let two = SeriesExceptions(window: window, keptSlots: [at(slots[0])],
                                   detached: [detached("A", slot: slots[1]), detached("B", slot: slots[2]), detached("C", slot: slots[3])])
        let log = Log()
        XCTAssertThrowsError(try run(two, log: log, failCreateTitle: "C")) { error in
            XCTAssertEqual(error as? SeriesExceptionsRestoreError, .oneOffFailed(at(slots[3])))
        }
        XCTAssertEqual(log.created, ["A", "B"])
        XCTAssertEqual(log.removedOneOffs, ["A", "B"])
        XCTAssertEqual(log.rolledBack, 1)
    }

    func testAFailedRollbackIsReportedNotSwallowed() {
        XCTAssertThrowsError(try run(spikeExceptions, failRemoveAt: at(slots[2]), failRollback: true)) { error in
            guard case .rollbackFailed? = error as? SeriesExceptionsRestoreError else {
                return XCTFail("expected rollbackFailed, got \(error)")
            }
        }
    }

    func testAFailedOneOffCleanupIsReportedAsARollbackFailure() {
        let two = SeriesExceptions(window: window, keptSlots: [at(slots[0])],
                                   detached: [detached("A", slot: slots[1]), detached("B", slot: slots[2])])
        XCTAssertThrowsError(try run(two, failCreateTitle: "B", failOneOffCleanup: true)) { error in
            guard case .rollbackFailed? = error as? SeriesExceptionsRestoreError else {
                return XCTFail("expected rollbackFailed, got \(error)")
            }
        }
    }
}
