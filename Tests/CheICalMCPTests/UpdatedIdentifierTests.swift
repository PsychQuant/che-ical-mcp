import EventKit
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

    // MARK: - which saves are occurrence saves, and their series id (verify round 3: fail toward
    // "changed", never toward a stale "unchanged")

    private func series(isOccurrence: Bool = true, span: EKSpan = .thisEvent, refreshed: Bool,
                        crossed: Bool, master: String?, occurrence: String?) -> String? {
        UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: isOccurrence, span: span,
                                                masterRefreshed: refreshed, crossedAccounts: crossed,
                                                master: master, occurrence: occurrence)
    }

    func testOnlyAnOccurrenceSavedWithSpanThisHasASeriesIdentifier() {
        XCTAssertEqual(series(refreshed: true, crossed: false, master: "S", occurrence: "S/RID=1"), "S")
        XCTAssertNil(series(span: .futureEvents, refreshed: true, crossed: false, master: "S", occurrence: "NEW"),
                     "a future split is a new series")
        XCTAssertNil(series(isOccurrence: false, refreshed: true, crossed: false, master: "S", occurrence: "S"))
    }

    /// Refreshed series object, same account: its identifier.
    func testARefreshedSeriesInTheSameAccountGivesItsIdentifier() {
        XCTAssertEqual(series(refreshed: true, crossed: false, master: "MASTER", occurrence: "OTHER/RID=1"), "MASTER")
        XCTAssertEqual(series(refreshed: true, crossed: false, master: "MASTER", occurrence: "UNRELATED"), "MASTER")
    }

    /// A save that crossed accounts: the series object may keep its old id, so it loses to the
    /// occurrence's series part; without one, the occurrence id itself (a change, not the old id).
    func testACrossAccountSaveNeverTrustsTheSeriesObject() {
        XCTAssertEqual(series(refreshed: true, crossed: true, master: "OLD", occurrence: "NEW/RID=1"), "NEW")
        XCTAssertEqual(series(refreshed: false, crossed: true, master: "OLD", occurrence: "NEW/RID=1"), "NEW")
        XCTAssertEqual(series(refreshed: true, crossed: true, master: "OLD", occurrence: "UNRELATED-NEW"), "UNRELATED-NEW")
        XCTAssertEqual(series(refreshed: false, crossed: true, master: nil, occurrence: "UNRELATED-NEW"), "UNRELATED-NEW")
    }

    /// A series object that did not refresh is not read: the occurrence's series part, else keep
    /// the input ("", same account, nothing known).
    func testAnUnrefreshedSeriesInTheSameAccountFallsBackToThePrefixOrKeepsTheInput() {
        XCTAssertEqual(series(refreshed: false, crossed: false, master: "STALE", occurrence: "S/RID=1"), "S")
        XCTAssertEqual(series(refreshed: false, crossed: false, master: "STALE", occurrence: "UNRELATED"), "")
        XCTAssertEqual(series(refreshed: false, crossed: false, master: nil, occurrence: nil), "")
    }

    /// A refreshed series object without an identifier, same account: prefix, else keep the input.
    func testARefreshedSeriesWithoutAnIdentifierFallsBackToThePrefixOrKeepsTheInput() {
        for master in [nil, ""] as [String?] {
            XCTAssertEqual(series(refreshed: true, crossed: false, master: master, occurrence: "S/RID=1"), "S")
            XCTAssertEqual(series(refreshed: true, crossed: false, master: master, occurrence: "UNRELATED"), "")
        }
    }

    /// End to end with `responseFields`: a crossed save with an unrelated occurrence id reports
    /// that id as the new `id` (changed), never the old one.
    func testACrossedSaveWithAnUnrelatedOccurrenceIdIsReportedAsAChange() {
        let seriesId = series(refreshed: true, crossed: true, master: "CAL:SERIES", occurrence: "NEW-OCC")
        let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: "NEW-OCC", seriesIdentifier: seriesId)
        XCTAssertEqual(fields["id"] as? String, "NEW-OCC")
        XCTAssertEqual(fields["id_changed"] as? Bool, true)
        XCTAssertEqual(fields["previous_id"] as? String, "CAL:SERIES")
        XCTAssertEqual(fields["occurrence_id"] as? String, "NEW-OCC")
    }

    /// The wiring in `EventKitManager.updateEvent` (no in-memory store can run it).
    func testUpdateEventDerivesTheSeriesFromTheSavedObjectIdentity() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("let masterRefreshed = savedIsOccurrence && masterEvent.refresh()"), "refresh result kept")
        XCTAssertTrue(flat.contains("UpdatedIdentifier.savedOccurrenceSeries( savedIsOccurrence: event !== masterEvent, span: span, masterRefreshed: masterRefreshed, crossedAccounts: crossesAccounts, master: masterRefreshed ? masterEvent.eventIdentifier : nil, occurrence: event.eventIdentifier)"),
                      String(flat.suffix(900)))
        // The same cross-account value the stand-in refusal uses, computed once before any write.
        XCTAssertTrue(flat.contains("let crossesAccounts = newCalendar.map { FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: event.calendar?.source?.sourceIdentifier, toSourceID: $0.source?.sourceIdentifier) } ?? false"))
        XCTAssertTrue(flat.contains("changesAccount: crossesAccounts,"))
        let save = try XCTUnwrap(flat.range(of: "try eventStore.save(event, span: span)"))
        let seriesCall = try XCTUnwrap(flat.range(of: "UpdatedIdentifier.savedOccurrenceSeries("))
        XCTAssertLessThan(save.lowerBound, seriesCall.lowerBound, "read after the save")
    }
}
