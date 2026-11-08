import XCTest
@testable import CheICalMCP

/// #321: what an occurrence delete records about the series it came from (`OccurrenceOrigin`), and
/// the series that undo recreated in this process (`SeriesRecreations`). Before #321 the record held
/// only the occurrence's title and start, so the duplicate guard matched any recurring event with
/// that title at that second.
final class OccurrenceOriginTests: XCTestCase {
    private let slot = Date(timeIntervalSinceReferenceDate: 837_050_400)
    private var rid: String { "/RID=\(Int(slot.timeIntervalSinceReferenceDate))" }

    func testAnUneditedOccurrenceIsTiedToItsSeriesAtItsOccurrenceDate() throws {
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S", externalIdentifier: "UID-S",
                                                       occurrenceDate: slot, isAllDay: false))
        XCTAssertEqual(origin.series, UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "UID-S"))
        XCTAssertEqual(origin.slot, slot)
    }

    /// An occurrence edited on its own reads back as `<series>/RID=<slot>` (iCloud, #311): the
    /// series is the part before the suffix, and the slot is the RID, not the drifted occurrenceDate.
    func testAnEditedOccurrenceIsTiedToItsSeriesAtItsRuleSlot() throws {
        let drifted = slot.addingTimeInterval(1800)
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + rid, externalIdentifier: "UID-S" + rid,
                                                       occurrenceDate: drifted, isAllDay: false))
        XCTAssertEqual(origin.series, UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "UID-S"))
        XCTAssertEqual(origin.slot, slot)
    }

    /// The all-day RID is a floating date; the slot is local midnight of that day (#311 round 4).
    func testAnAllDayRuleSlotIsLocalMidnight() throws {
        let zone = TimeZone(identifier: "Asia/Taipei")!
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let floating = utc.date(from: DateComponents(year: 2028, month: 5, day: 8))!
        let origin = try XCTUnwrap(OccurrenceOrigin.of(
            eventIdentifier: "S/RID=\(Int(floating.timeIntervalSinceReferenceDate))", externalIdentifier: nil,
            occurrenceDate: nil, isAllDay: true, zone: zone))
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        XCTAssertEqual(origin.slot, local.date(from: DateComponents(year: 2028, month: 5, day: 8)))
        XCTAssertEqual(origin.series.eventIdentifier, "S")
    }

    /// No slot (no occurrenceDate, no RID) or no identifier: nothing to tie it by, so no origin,
    /// and the guard cannot decide (the undo then writes the one-off).
    func testNoSlotOrNoIdentifierGivesNoOrigin() {
        XCTAssertNil(OccurrenceOrigin.of(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: nil, isAllDay: false))
        XCTAssertNil(OccurrenceOrigin.of(eventIdentifier: nil, externalIdentifier: nil, occurrenceDate: slot, isAllDay: false))
        XCTAssertNil(OccurrenceOrigin.of(eventIdentifier: "", externalIdentifier: "", occurrenceDate: slot, isAllDay: false))
    }

    func testTheSeriesIdentifiersDropTheSlotSuffix() {
        XCTAssertEqual(OccurrenceOrigin.seriesIDs(eventIdentifier: "S" + rid, externalIdentifier: "UID-S" + rid),
                       UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "UID-S"))
        XCTAssertEqual(OccurrenceOrigin.seriesIDs(eventIdentifier: "S", externalIdentifier: nil),
                       UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: nil))
        XCTAssertNil(OccurrenceOrigin.seriesIDs(eventIdentifier: nil, externalIdentifier: ""))
    }

    // MARK: - SeriesRecreations

    private func ids(_ id: String, _ external: String? = nil) -> UndoPostState.OccurrenceIDs {
        UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: external)
    }

    func testARecreationIsFoundByTheRecordedSeries() {
        var log = SeriesRecreations()
        log.note(ids("S", "UID-S"), recreatedAs: ids("S2", "UID-S2"))
        XCTAssertEqual(log.recreations(of: ids("S", "UID-S")), [ids("S2", "UID-S2")])
        XCTAssertEqual(log.recreations(of: ids("T", "UID-T")), [])
    }

    /// Either identifier ties the recorded series (another store may give a new event identifier
    /// and keep the UID, #285).
    func testEitherIdentifierFindsTheRecreation() {
        var log = SeriesRecreations()
        log.note(ids("S", "UID-S"), recreatedAs: ids("S2"))
        XCTAssertEqual(log.recreations(of: ids("other", "UID-S")), [ids("S2")])
        XCTAssertEqual(log.recreations(of: ids("S", nil)), [ids("S2")])
    }

    /// A series deleted and undone twice: the occurrence of the first record is held by the
    /// series of the second recreation.
    func testRecreationsAreFollowedThroughLaterOnes() {
        var log = SeriesRecreations()
        log.note(ids("S"), recreatedAs: ids("S2"))
        log.note(ids("S2"), recreatedAs: ids("S3"))
        XCTAssertEqual(log.recreations(of: ids("S")), [ids("S2"), ids("S3")])
    }

    func testACycleEnds() {
        var log = SeriesRecreations()
        log.note(ids("S"), recreatedAs: ids("S2"))
        log.note(ids("S2"), recreatedAs: ids("S"))
        XCTAssertEqual(log.recreations(of: ids("S")), [ids("S2")])
    }

    func testEmptyIdentifiersMatchNothing() {
        var log = SeriesRecreations()
        log.note(ids("", ""), recreatedAs: ids("S2"))
        XCTAssertEqual(log.recreations(of: ids("", "")), [])
    }
}
