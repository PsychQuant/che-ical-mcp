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

    // MARK: - #539: both readings of a timed `/RID=`

    private func rid(_ digits: Date) -> String { "/RID=\(Int(digits.timeIntervalSinceReferenceDate))" }

    /// The `/RID=` digits of `slot` written floating: its wall-clock time in `zone`, as UTC.
    private func floatingDigits(_ slot: Date, in zone: TimeZone) -> Date {
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot))!
    }

    /// The argument of `isHeld`'s doc comment as a test: on hosts at the widest offsets (+14:00,
    /// -12:00) and an odd one (+05:45), for a daily series and a weekly one on adjacent days, with a
    /// zone and without one, the wrong reading of every occurrence's `/RID=` is no slot of the rule,
    /// so a plain occurrence of the series never holds it; the right reading always is held.
    func testTheWrongReadingIsNoSlotOfTheSeriesAtTheWidestOffsets() throws {
        let zones = ["Pacific/Kiritimati", "Etc/GMT+12", "Asia/Kathmandu"].map { TimeZone(identifier: $0)! }
        let ids = UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "UID-S")
        for zone in zones {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let first = calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 23, minute: 30))!   // a Monday
            let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                                    occurrenceCount: 60, hasOtherParts: false)
            let adjacent = DeletedOccurrenceCheck.Rule(frequency: .weekly, interval: 1, daysOfWeek: [2, 3, 4], daysOfMonth: [], endDate: nil,
                                                       occurrenceCount: 60, hasOtherParts: false)
            for rule in [daily, adjacent] {
                let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule, firstStart: first,
                                                                              until: first.addingTimeInterval(400 * 86_400), calendar: calendar))
                let holders = slots.map { OccurrenceSlotGuard.SeriesHolder(ids: ids, slot: $0) }
                for slot in slots {
                    for digits in [slot, floatingDigits(slot, in: zone)] {
                        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + rid(digits), externalIdentifier: nil,
                                                                       occurrenceDate: nil, isAllDay: false, isDetached: true, zone: zone))
                        let wrong = origin.readings.filter { !UndoPostState.sameInstant($0, slot) }
                        XCTAssertEqual(wrong.count, 1, "\(zone.identifier): two readings, one of them the slot")
                        XCTAssertFalse(wrong.contains { w in slots.contains { UndoPostState.sameInstant($0, w) } },
                                       "\(zone.identifier) \(rule.frequency.rawValue): the wrong reading is no slot")
                        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: holders.filter { UndoPostState.sameInstant($0.slot, slot) }))
                        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: holders.filter { !UndoPostState.sameInstant($0.slot, slot) }),
                                       "\(zone.identifier) \(rule.frequency.rawValue): no other occurrence of the series holds it")
                    }
                }
            }
        }
    }

    /// Another series in the same calendar with an occurrence exactly at the origin's wrong reading,
    /// and one exactly at its true slot: neither holds the slot, as neither is tied to the recorded
    /// series (the shape of the #321 gate's step 2).
    func testAnotherSeriesAtEitherReadingHoldsNothing() throws {
        let zone = TimeZone(identifier: "Asia/Taipei")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let slot = calendar.date(from: DateComponents(year: 2027, month: 2, day: 25, hour: 10))!
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + rid(floatingDigits(slot, in: zone)), externalIdentifier: nil,
                                                       occurrenceDate: nil, isAllDay: false, isDetached: true, zone: zone))
        let other = UndoPostState.OccurrenceIDs(eventIdentifier: "T", externalIdentifier: "UID-T")
        let atWrong = OccurrenceSlotGuard.SeriesHolder(ids: other, slot: origin.slot)
        let atTrue = OccurrenceSlotGuard.SeriesHolder(ids: other, slot: slot)
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [atWrong, atTrue]))
    }

    /// Two edited occurrences are compared by their readings: the same `/RID=` digits hold.
    func testAnEditedHolderWithTheSameRIDHolds() throws {
        let zone = TimeZone(identifier: "Asia/Taipei")!
        let digits = Date(timeIntervalSinceReferenceDate: 793_965_600)
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                       isAllDay: false, isDetached: true, zone: zone))
        let holder = try XCTUnwrap(OccurrenceSlotGuard.holder(eventIdentifier: "S" + rid(digits), externalIdentifier: nil,
                                                              occurrenceDate: digits.addingTimeInterval(3600), isAllDay: false,
                                                              startDate: digits.addingTimeInterval(3600), hasRecurrenceRules: false,
                                                              isDetached: true, zone: zone))
        XCTAssertEqual(holder.readings.count, 2)
        XCTAssertTrue(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [holder]))
        XCTAssertFalse(OccurrenceSlotGuard.isHeld(origin, recreatedAs: [], by: [OccurrenceSlotGuard.SeriesHolder(
            ids: .init(eventIdentifier: "S", externalIdentifier: nil), slot: digits.addingTimeInterval(86_400))]))
    }
}
