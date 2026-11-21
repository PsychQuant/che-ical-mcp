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

    /// PR #494 round 1: the origin says whether the occurrence had been edited on its own.
    func testTheOriginSaysWhetherTheOccurrenceWasEdited() throws {
        XCTAssertFalse(try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: slot, isAllDay: false)).edited)
        XCTAssertTrue(try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + rid, externalIdentifier: nil, occurrenceDate: slot, isAllDay: false)).edited)
        XCTAssertTrue(try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: slot, isAllDay: false,
                                                        isDetached: true)).edited)
    }

    /// PR #558 round 2 (ruling J, H22): the zone an origin is taken with is its series'. Through the series'
    /// identifier the resolved event's own zone is the series'; through an occurrence's own identifier the
    /// series object is read under the part before `/RID=`, and when it cannot be read the origin takes one
    /// reading. The three producers hand this in (`SlotReadingsZoneWiringTests`).
    func testAnOriginIsTakenWithItsSeriesZone() {
        var asked: [String] = []
        func series(_ answer: Bool?) -> (String) -> Bool? { { id in asked.append(id); return answer } }
        // Through the series' identifier: the event's own zone, the series object not read.
        XCTAssertTrue(OccurrenceOrigin.seriesIsFloating(eventIdentifier: "S", externalIdentifier: "X-S", ownFloating: true, seriesFloating: series(false)))
        XCTAssertFalse(OccurrenceOrigin.seriesIsFloating(eventIdentifier: "S", externalIdentifier: "X-S", ownFloating: false, seriesFloating: series(true)))
        XCTAssertEqual(asked, [])
        // Through an occurrence's own identifier: the series', whatever the occurrence's own zone.
        XCTAssertFalse(OccurrenceOrigin.seriesIsFloating(eventIdentifier: "S/RID=825458400", externalIdentifier: "X-S/RID=825458400", ownFloating: true, seriesFloating: series(false)))
        XCTAssertTrue(OccurrenceOrigin.seriesIsFloating(eventIdentifier: "S/RID=825458400", externalIdentifier: "X-S/RID=825458400", ownFloating: false, seriesFloating: series(true)))
        // The series cannot be read there: one reading.
        XCTAssertFalse(OccurrenceOrigin.seriesIsFloating(eventIdentifier: "S/RID=825458400", externalIdentifier: "X-S/RID=825458400", ownFloating: true, seriesFloating: series(nil)))
        XCTAssertEqual(asked, ["S", "S", "S"])
        // No identifier: the event's own.
        XCTAssertTrue(OccurrenceOrigin.seriesIsFloating(eventIdentifier: nil, externalIdentifier: nil, ownFloating: true, seriesFloating: series(false)))
    }

    /// PR #558 fix round 4 (verify finding C5, Codex): an occurrence whose `/RID=` is only in its external
    /// identifier (an opaque event identifier) names no series object to read, so its origin takes one
    /// reading, J's fallback, not the occurrence's own zone; and its slot check then answers as `main`'s.
    func testAnOriginWhoseRIDIsOnlyInTheExternalIdentifierTakesOneReading() throws {
        var asked: [String] = []
        let floating = OccurrenceOrigin.seriesIsFloating(eventIdentifier: "OPAQUE", externalIdentifier: "X-S/RID=825458400",
                                                         ownFloating: true, seriesFloating: { id in asked.append(id); return true })
        XCTAssertFalse(floating)
        XCTAssertEqual(asked, [], "no series object is read through an external identifier")
        let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "OPAQUE", externalIdentifier: "X-S/RID=825458400", occurrenceDate: nil,
                                                       isAllDay: false, isDetached: true, floating: floating,
                                                       zone: TimeZone(identifier: "Asia/Taipei")!))
        XCTAssertNil(origin.wallClock, "one reading")
    }
}
