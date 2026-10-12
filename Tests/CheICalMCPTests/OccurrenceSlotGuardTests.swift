import XCTest
@testable import CheICalMCP

/// #285: the undo of a single-occurrence delete writes nothing when the series already holds the
/// slot (the series was recreated from its rules earlier, which brings every slot back).
final class OccurrenceSlotGuardTests: XCTestCase {
    private func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }
    private let slot = "2028-04-10T10:00:00+08:00"

    private func holder(_ title: String?, _ start: String, recurring: Bool) -> OccurrenceSlotGuard.Holder {
        OccurrenceSlotGuard.Holder(title: title, startDate: at(start), hasRecurrenceRules: recurring)
    }

    func testASeriesOccurrenceAtTheSlotWithTheSameTitleHoldsIt() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(title: "Standup", start: at(slot),
                                                 by: [holder("Standup", slot, recurring: true)]))
    }

    func testAOneOffAtTheSlotDoesNotHoldItBecauseTheUndoMustNotHideAnEarlierRestore() {
        // A one-off already there is what an earlier undo of this record wrote; writing a second
        // is the caller's repeated undo, which the record's single use already prevents.
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(title: "Standup", start: at(slot),
                                                  by: [holder("Standup", slot, recurring: false)]))
    }

    func testADifferentTitleDoesNotHoldTheSlot() {
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(title: "Standup", start: at(slot),
                                                  by: [holder("Retro", slot, recurring: true)]))
    }

    func testAnotherSlotDoesNotHoldIt() {
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(title: "Standup", start: at(slot),
                                                  by: [holder("Standup", "2028-04-17T10:00:00+08:00", recurring: true)]))
    }

    func testNothingThereHoldsNothing() {
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(title: "Standup", start: at(slot), by: []))
    }

    func testAMissingTitleOnBothSidesIsTheSameTitle() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(title: "", start: at(slot), by: [holder(nil, slot, recurring: true)]))
    }

    func testTheStartIsComparedToTheSecond() {
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(title: "Standup", start: at(slot).addingTimeInterval(0.4),
                                                 by: [holder("Standup", slot, recurring: true)]))
    }
}
