import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 ruling F, fix round 4: the undo of one occurrence's delete (and the rule-less record of an
/// occurrence deleted through its own identifier, PR #318 round 3, finding 22) against `main`'s
/// (`SeriesUndoOnMain`), one test per answer of `OccurrenceSlotGuard.answer`. Each runs on two stores set up
/// alike and compares what each undo wrote: this server writes a part of what `main` wrote, the same where
/// the answer is `held` or `free`, and nothing where `main` wrote a one-off beside an occurrence at the
/// wall-clock reading (`heldAtWallClockOnly`, the refusal, entry kept). The record is an occurrence edited
/// while its series had no time zone (its `/RID=` digits are the slot's wall-clock time as UTC, #539), read
/// on a host at `+08:00`; each test names its zone.
final class OccurrenceSlotRefusalAgainstMainTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let day: TimeInterval = 86_400

    private var slot: Date { Calendar.gregorian(in: taipei).date(from: DateComponents(year: 2027, month: 2, day: 25, hour: 10))! }

    /// The `/RID=` of an occurrence of `slot` edited while its series had no time zone.
    private var floatingRID: String {
        let digits = Calendar.gregorian(in: TimeZone(identifier: "UTC")!).date(
            from: Calendar.gregorian(in: taipei).dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot))!
        return "/RID=\(Int(digits.timeIntervalSinceReferenceDate))"
    }

    private func key(_ event: FakeSeriesExceptionsStore.Event) -> String { "\(Int(event.start.timeIntervalSinceReferenceDate)) \(event.title)" }

    /// A store holding series S with occurrences at `holders`.
    private func store(holders: [Date]) -> FakeSeriesExceptionsStore {
        let store = FakeSeriesExceptionsStore()
        store.zone = taipei
        store.addSeries(id: "S", calendar: "C", title: "Standup", slots: holders)
        return store
    }

    /// What each undo of the occurrence's record wrote on a store holding series S at `holders`, by arm.
    private func written(holders: [Date], ruleless: Bool, onMain: Bool) throws -> (written: [String], answer: String) {
        let store = store(holders: holders)
        let before = Set(store.events.map(key))
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + floatingRID, externalIdentifier: "X-S" + floatingRID, occurrenceDate: nil,
                                                       isAllDay: false, isDetached: true, floating: !onMain, zone: taipei))
        let record = UndoSnapshotFixtures.event(title: "Edited", startDate: slot).withOccurrenceOrigin(origin)
        let answer: String
        do {
            switch (onMain, ruleless) {
            case (false, false):
                answer = "\(try SeriesExceptionsUndo.undoDeleteOccurrence(record, notCarriedOver: [], calendar: "C", in: store).outcome)"
            case (false, true):
                answer = "\(String(describing: try SeriesExceptionsUndo.undoDeleteEvent(record, calendar: "C", in: store).outcome))"
            case (true, false):
                answer = "\(try SeriesUndoOnMain.undoDeleteOccurrence(record, notCarriedOver: [], calendar: "C", in: store).outcome)"
            case (true, true):
                answer = "\(String(describing: try SeriesUndoOnMain.recreateDeletedEvent(record, calendar: "C", in: store).outcome))"
            }
        } catch {
            answer = "refused \(type(of: error)), kept: \(UndoFailureDisposition.of(error) == .restore)"
        }
        return (store.events.map(key).filter { !before.contains($0) }.sorted(), answer)
    }

    /// For both arms: this server's answer and what it wrote, and `main`'s.
    private func compare(holders: [Date], file: StaticString = #filePath, line: UInt = #line)
        throws -> [(production: (written: [String], answer: String), main: (written: [String], answer: String))] {
        try [false, true].map { ruleless in
            let production = try written(holders: holders, ruleless: ruleless, onMain: false)
            let main = try written(holders: holders, ruleless: ruleless, onMain: true)
            XCTAssertTrue(Set(production.written).isSubset(of: Set(main.written)),
                          "wrote \(production.written), main \(main.written)", file: file, line: line)
            return (production, main)
        }
    }

    /// The `/RID=` read as an instant is 18:00 local, 8 hours after the slot: the two readings differ.
    func testTheRecordHasTwoReadings() throws {
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + floatingRID, externalIdentifier: nil, occurrenceDate: nil,
                                                       isAllDay: false, isDetached: true, floating: true, zone: taipei))
        XCTAssertEqual(origin.slot, slot.addingTimeInterval(8 * 3600))
        XCTAssertEqual(origin.wallClock, slot)
    }

    /// `held`: an occurrence of the series at the instant reading. Neither undo writes anything: the same.
    func testHeldWritesWhatMainWrites() throws {
        for (production, main) in try compare(holders: [slot.addingTimeInterval(8 * 3600)]) {
            XCTAssertEqual(production.written, [])
            XCTAssertEqual(production.written, main.written)
            XCTAssertEqual(production.answer, main.answer)
            XCTAssertTrue(production.answer.contains("editedOccurrenceAlreadyHeld"), production.answer)
        }
    }

    /// `heldAtWallClockOnly`: a plain occurrence of the series at the wall-clock reading, none at the
    /// instant. `main` writes the one-off beside it (two events at one start, #539's report); this server
    /// writes nothing and keeps the entry: a part of what `main` wrote.
    func testHeldAtTheWallClockOnlyWritesNothingWhereMainWroteASecondEvent() throws {
        for (production, main) in try compare(holders: [slot]) {
            XCTAssertEqual(production.written, [])
            XCTAssertEqual(production.answer, "refused OccurrenceSlotWallClockRefusal, kept: true")
            XCTAssertEqual(main.written, ["\(Int(slot.timeIntervalSinceReferenceDate)) Edited"])
        }
    }

    /// `free`: no occurrence of the series at either reading. Both undos write the one-off: the same.
    func testFreeWritesWhatMainWrites() throws {
        for (production, main) in try compare(holders: [slot.addingTimeInterval(7 * day)]) {
            XCTAssertEqual(production.written, ["\(Int(slot.timeIntervalSinceReferenceDate)) Edited"])
            XCTAssertEqual(production.written, main.written)
            XCTAssertEqual(production.answer, main.answer)
        }
    }

    /// An edited holder at the wall-clock reading does not make the guard refuse (it is compared by its
    /// instant reading only): both undos write the one-off.
    func testAnEditedHolderAtTheWallClockReadingIsFreeAsOnMain() throws {
        let store = store(holders: [])
        let rid = "/RID=\(Int(slot.timeIntervalSinceReferenceDate))"
        let holder = FakeSeriesExceptionsStore.Event(id: "S" + rid, external: "X-S" + rid, calendar: "C", title: "Other edit", start: slot,
                                                     occurrenceDate: slot, detached: true)
        store.add(holder)
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + floatingRID, externalIdentifier: nil, occurrenceDate: nil,
                                                       isAllDay: false, isDetached: true, floating: true, zone: taipei))
        let holders = store.slotHolders(at: origin.slot, length: 3600, in: "C")
        XCTAssertEqual(holders.map(\.slot), [slot])
        XCTAssertEqual(holders.map(\.edited), [true])
        XCTAssertEqual(OccurrenceSlotGuard.answer(origin, recreatedAs: [], by: holders), .free)
        XCTAssertFalse(OccurrenceSlotGuard.isHeldOnMain(origin, recreatedAs: [], by: holders))
    }
}
