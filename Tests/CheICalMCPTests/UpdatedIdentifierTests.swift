import XCTest
@testable import CheICalMCP

/// #268: `update_event` / `update_reminder` report the identifier the item has after the save.
final class UpdatedIdentifierTests: XCTestCase {
    func testADifferentSavedIdentifierIsReportedAndFlagged() {
        let fields = UpdatedIdentifier.responseFields(input: "old-id", saved: "new-id")
        XCTAssertEqual(fields["id"] as? String, "new-id")
        XCTAssertEqual(fields["id_changed"] as? Bool, true)
        XCTAssertEqual(fields["previous_id"] as? String, "old-id")
    }

    func testTheSameIdentifierIsReportedUnchangedWithoutPreviousId() {
        let fields = UpdatedIdentifier.responseFields(input: "same", saved: "same")
        XCTAssertEqual(fields["id"] as? String, "same")
        XCTAssertEqual(fields["id_changed"] as? Bool, false)
        XCTAssertNil(fields["previous_id"])
    }

    func testAMissingSavedIdentifierFallsBackToTheInput() {
        for saved in [nil, ""] as [String?] {
            let fields = UpdatedIdentifier.responseFields(input: "kept", saved: saved)
            XCTAssertEqual(fields["id"] as? String, "kept")
            XCTAssertEqual(fields["id_changed"] as? Bool, false)
            XCTAssertNil(fields["previous_id"])
        }
    }

    // MARK: - PR #387 verify round 2: an occurrence save is known structurally, not by id shape

    /// One occurrence edited on its own (span this): `id` is the series' identifier after the save
    /// and the saved occurrence's id, whatever its shape, is `occurrence_id`.
    func testAnOccurrenceSaveKeepsTheSeriesIdentifierWhateverTheOccurrenceIdLooksLike() {
        for occurrence in ["CAL:SERIES/RID=834627600", "UNRELATED-OCCURRENCE-ID"] {
            let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: occurrence, seriesIdentifier: "CAL:SERIES")
            XCTAssertEqual(fields["id"] as? String, "CAL:SERIES")
            XCTAssertEqual(fields["id_changed"] as? Bool, false)
            XCTAssertEqual(fields["occurrence_id"] as? String, occurrence)
            XCTAssertNil(fields["previous_id"])
        }
    }

    /// An occurrence edit that also moves the series to another account: `id` is the new series id.
    func testAnOccurrenceSaveThatMovedTheSeriesReportsTheNewSeriesIdentifier() {
        let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: "OTHER:NEW/RID=834627600",
                                                      seriesIdentifier: "OTHER:NEW")
        XCTAssertEqual(fields["id"] as? String, "OTHER:NEW")
        XCTAssertEqual(fields["id_changed"] as? Bool, true)
        XCTAssertEqual(fields["previous_id"] as? String, "CAL:SERIES")
        XCTAssertEqual(fields["occurrence_id"] as? String, "OTHER:NEW/RID=834627600")
    }

    /// Without the occurrence flag the shape means nothing: a different saved id is a change.
    func testWithoutTheOccurrenceFlagADifferentIdIsAChangeWhateverItsShape() {
        let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: "CAL:SERIES/RID=1")
        XCTAssertEqual(fields["id"] as? String, "CAL:SERIES/RID=1")
        XCTAssertEqual(fields["id_changed"] as? Bool, true)
        XCTAssertNil(fields["occurrence_id"])
    }

    func testAnEmptySeriesIdentifierFallsBackToTheInput() {
        let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: "OCC", seriesIdentifier: "")
        XCTAssertEqual(fields["id"] as? String, "CAL:SERIES")
        XCTAssertEqual(fields["id_changed"] as? Bool, false)
        XCTAssertEqual(fields["occurrence_id"] as? String, "OCC")
    }

    // MARK: - which saves are occurrence saves, and their series id

    func testOnlyAnOccurrenceSavedWithSpanThisHasASeriesIdentifier() {
        XCTAssertEqual(UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: true, span: .thisEvent,
                                                               master: "S", occurrence: "S/RID=1"), "S")
        XCTAssertNil(UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: true, span: .futureEvents,
                                                             master: "S", occurrence: "NEW"), "a future split is a new series")
        XCTAssertNil(UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: false, span: .thisEvent,
                                                             master: "S", occurrence: "S"))
    }

    /// The series object after the save comes first; when it has no identifier, the part of the
    /// occurrence id before `/RID=` (iCloud's shape) is the fallback, and nil without either.
    func testTheSeriesIdentifierPrefersTheSeriesObjectThenTheOccurrencePrefix() {
        XCTAssertEqual(UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: true, span: .thisEvent,
                                                               master: "MASTER", occurrence: "OTHER/RID=1"), "MASTER")
        for master in [nil, ""] as [String?] {
            XCTAssertEqual(UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: true, span: .thisEvent,
                                                                   master: master, occurrence: "NEW/RID=1"), "NEW")
            XCTAssertNil(UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: true, span: .thisEvent,
                                                                 master: master, occurrence: "UNRELATED"))
        }
    }

    /// The wiring in `EventKitManager.updateEvent` (no in-memory store can run it): the flag is
    /// the object identity of the saved event and the resolved series, with the call's span.
    func testUpdateEventDerivesTheSeriesFromTheSavedObjectIdentity() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("UpdatedIdentifier.savedOccurrenceSeries( savedIsOccurrence: event !== masterEvent, span: span,"), flat.suffix(600).description)
        XCTAssertTrue(flat.contains("occurrence: event.eventIdentifier)"))
        let save = try XCTUnwrap(flat.range(of: "try eventStore.save(event, span: span)"))
        let series = try XCTUnwrap(flat.range(of: "UpdatedIdentifier.savedOccurrenceSeries("))
        XCTAssertLessThan(save.lowerBound, series.lowerBound, "read after the save")
    }
}
