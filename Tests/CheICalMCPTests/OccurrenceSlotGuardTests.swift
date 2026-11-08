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

    func testAnOccurrenceOfTheSeriesAtTheSlotHoldsIt() {
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
    /// carries the series' title. The title is not compared (a holder has none), so it still holds.
    func testTheTitleIsNotCompared() {
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

    // MARK: - the holder's slot (PR #494 round 1, LOW)

    func testAHolderWithARIDIsAtItsRuleSlot() throws {
        let rid = at(slot)
        let moved = rid.addingTimeInterval(1800)
        let holder = OccurrenceSlotGuard.holder(eventIdentifier: "S/RID=\(Int(rid.timeIntervalSinceReferenceDate))", externalIdentifier: nil,
                                                occurrenceDate: moved, isAllDay: false, startDate: moved, hasRecurrenceRules: false, isDetached: true)
        XCTAssertEqual(try XCTUnwrap(holder).slot, rid)
    }

    func testAHolderWithoutARIDIsAtItsOccurrenceDate() throws {
        let holder = try XCTUnwrap(OccurrenceSlotGuard.holder(eventIdentifier: "S", externalIdentifier: "UID-S", occurrenceDate: at(slot),
                                                              isAllDay: false, startDate: at(slot).addingTimeInterval(60),
                                                              hasRecurrenceRules: true, isDetached: false))
        XCTAssertEqual(holder.slot, at(slot))
        XCTAssertEqual(holder.ids, .init(eventIdentifier: "S", externalIdentifier: "UID-S"))
    }

    /// A recurring event without an occurrenceDate is at its start.
    func testAHolderWithNeitherIsAtItsStart() throws {
        let holder = try XCTUnwrap(OccurrenceSlotGuard.holder(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: nil, isAllDay: false,
                                                              startDate: at(slot), hasRecurrenceRules: true, isDetached: false))
        XCTAssertEqual(holder.slot, at(slot))
    }

    /// PR #494 round 5: a plain one-off event (no rules, not detached, no `/RID=`) holds nothing,
    /// whatever its identifier: a series that lost its rule but kept its id is no series.
    func testAPlainOneOffEventIsNoHolder() {
        XCTAssertNil(OccurrenceSlotGuard.holder(eventIdentifier: "S", externalIdentifier: "UID-S", occurrenceDate: at(slot), isAllDay: false,
                                                startDate: at(slot), hasRecurrenceRules: false, isDetached: false))
    }

    /// An occurrence edited on its own has no rules of its own (iCloud); it still holds.
    func testADetachedOccurrenceWithoutRulesIsAHolder() {
        XCTAssertNotNil(OccurrenceSlotGuard.holder(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: at(slot), isAllDay: false,
                                                   startDate: at(slot), hasRecurrenceRules: false, isDetached: true))
        XCTAssertNotNil(OccurrenceSlotGuard.holder(eventIdentifier: "S/RID=1", externalIdentifier: nil, occurrenceDate: at(slot), isAllDay: false,
                                                   startDate: at(slot), hasRecurrenceRules: false, isDetached: false),
                        "a /RID= identifier marks an occurrence of a series")
    }

    /// An all-day RID is a floating date: the slot is local midnight of that day.
    func testAnAllDayHolderIsAtLocalMidnight() throws {
        let zone = TimeZone(identifier: "Asia/Taipei")!
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let floating = utc.date(from: DateComponents(year: 2028, month: 5, day: 8))!
        let holder = try XCTUnwrap(OccurrenceSlotGuard.holder(eventIdentifier: "S/RID=\(Int(floating.timeIntervalSinceReferenceDate))", externalIdentifier: nil,
                                                              occurrenceDate: nil, isAllDay: true, startDate: floating,
                                                              hasRecurrenceRules: false, isDetached: true, zone: zone))
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        XCTAssertEqual(holder.slot, local.date(from: DateComponents(year: 2028, month: 5, day: 8)))
    }
}
