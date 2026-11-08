import XCTest
@testable import CheICalMCP

/// #285: the undo of a single-occurrence delete writes nothing when the series already holds the
/// slot (the series was recreated from its rules earlier, which brings every slot back).
/// #321: "the series" is the recorded one or a series undo recreated from it, matched by
/// identifier, and "the slot" is the rule slot; the title is not compared.
final class OccurrenceSlotGuardTests: XCTestCase {
    private func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }
    private let slot = "2028-04-10T10:00:00+08:00"
    private let series = UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "UID-S")
    private var origin: OccurrenceOrigin { OccurrenceOrigin(series: series, slot: at(slot)) }

    private func holder(_ id: String, at start: String, external: String? = nil) -> OccurrenceSlotGuard.SeriesHolder {
        OccurrenceSlotGuard.SeriesHolder(ids: .init(eventIdentifier: id, externalIdentifier: external), slot: at(start))
    }

    func testASeriesOccurrenceAtTheSlotWithTheSameTitleHoldsIt() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("S", at: slot)]))
    }

    func testAOneOffAtTheSlotDoesNotHoldItBecauseTheUndoMustNotHideAnEarlierRestore() {
        // A one-off already there (another event, its own identifier) is not the series' slot.
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("ONE-OFF", at: slot)]))
    }

    /// #321: an unrelated series with the same title at that second used to hold the slot, so the
    /// undo answered success and wrote nothing. It does not hold it now.
    func testAnotherSeriesWithTheSameTitleAtTheSlotDoesNotHoldIt() {
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("T", at: slot, external: "UID-T")]))
    }

    /// #321: the series recreated by the undo of the whole-series delete has new identifiers; it
    /// holds the slot through the recreation log.
    func testTheRecreatedSeriesHoldsTheSlot() {
        let recreated = UndoPostState.OccurrenceIDs(eventIdentifier: "S2", externalIdentifier: "UID-S2")
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [recreated], by: [holder("S2", at: slot, external: "UID-S2")]))
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("S2", at: slot, external: "UID-S2")]),
                       "without the log the new series is another series")
    }

    /// #321: the occurrence's title was edited before its delete; the series' occurrence at the slot
    /// carries the series' title. The title is not compared, so it still holds.
    func testAMissingTitleOnBothSidesIsTheSameTitle() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("S", at: slot, external: "UID-S")]))
    }

    /// An occurrence edited on its own and held at its rule slot (its identifier carries the RID).
    func testAnEditedOccurrenceOfTheSeriesAtTheSlotHoldsIt() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("S/RID=1", at: slot, external: "UID-S/RID=1")]))
    }

    /// The external identifier alone ties a holder to the series (another store may change the
    /// event identifier and keep the UID).
    func testTheExternalIdentifierAloneTiesAHolder() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("unrelated", at: slot, external: "UID-S")]))
    }

    func testAnotherSlotDoesNotHoldIt() {
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder("S", at: "2028-04-17T10:00:00+08:00")]))
    }

    func testNothingThereHoldsNothing() {
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: []))
    }

    func testTheStartIsComparedToTheSecond() {
        let near = OccurrenceOrigin(series: series, slot: at(slot).addingTimeInterval(0.4))
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(near, recreatedAs: [], by: [holder("S", at: slot)]))
    }
}
