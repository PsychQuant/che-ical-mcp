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

    // MARK: - which saves are occurrence saves, and their series id (verify rounds 3-4: fail
    // toward "changed", never toward a stale "unchanged"; an occurrence edit across accounts is
    // refused before the save, so it never reaches this)

    private func series(isOccurrence: Bool = true, span: EKSpan = .thisEvent, refreshed: Bool,
                        master: String?, occurrence: String?) -> String? {
        UpdatedIdentifier.savedOccurrenceSeries(savedIsOccurrence: isOccurrence, span: span,
                                                masterRefreshed: refreshed, master: master, occurrence: occurrence)
    }

    func testOnlyAnOccurrenceSavedWithSpanThisHasASeriesIdentifier() {
        XCTAssertEqual(series(refreshed: true, master: "S", occurrence: "S/RID=1"), "S")
        XCTAssertNil(series(span: .futureEvents, refreshed: true, master: "S", occurrence: "NEW"), "a future split is a new series")
        XCTAssertNil(series(isOccurrence: false, refreshed: true, master: "S", occurrence: "S"))
    }

    func testARefreshedSeriesGivesItsIdentifier() {
        XCTAssertEqual(series(refreshed: true, master: "MASTER", occurrence: "OTHER/RID=1"), "MASTER")
        XCTAssertEqual(series(refreshed: true, master: "MASTER", occurrence: "UNRELATED"), "MASTER")
    }

    /// Verify round 4: a "master" that is itself an occurrence object (the stand-in) carries an
    /// occurrence id; its series part is what counts.
    func testAnOccurrenceIdAsTheMasterIsReducedToItsSeriesPart() {
        XCTAssertEqual(series(refreshed: true, master: "S/RID=99", occurrence: "UNRELATED"), "S")
        XCTAssertEqual(series(refreshed: true, master: "/RID=99", occurrence: "S/RID=1"), "S", "an empty series part falls through")
    }

    /// A series object that did not refresh is not read: the occurrence's series part, else keep
    /// the input ("": nothing known, and the save stayed in the account).
    func testAnUnrefreshedSeriesFallsBackToThePrefixOrKeepsTheInput() {
        XCTAssertEqual(series(refreshed: false, master: "STALE", occurrence: "S/RID=1"), "S")
        XCTAssertEqual(series(refreshed: false, master: "STALE", occurrence: "UNRELATED"), "")
        XCTAssertEqual(series(refreshed: false, master: nil, occurrence: nil), "")
    }

    func testARefreshedSeriesWithoutAnIdentifierFallsBackToThePrefixOrKeepsTheInput() {
        for master in [nil, ""] as [String?] {
            XCTAssertEqual(series(refreshed: true, master: master, occurrence: "S/RID=1"), "S")
            XCTAssertEqual(series(refreshed: true, master: master, occurrence: "UNRELATED"), "")
        }
    }

    // MARK: - verify round 4: an occurrence edit with a calendar of another account is refused

    func testAnOccurrenceEditWithACalendarOfAnotherAccountIsRefused() {
        XCTAssertTrue(EventKitManager.refusesOccurrenceEditAcrossAccounts(onOccurrence: true, span: .thisEvent, crossesAccounts: true))
        XCTAssertFalse(EventKitManager.refusesOccurrenceEditAcrossAccounts(onOccurrence: true, span: .thisEvent, crossesAccounts: false))
        XCTAssertFalse(EventKitManager.refusesOccurrenceEditAcrossAccounts(onOccurrence: false, span: .thisEvent, crossesAccounts: true),
                       "a one-off event moves on its own")
        XCTAssertFalse(EventKitManager.refusesOccurrenceEditAcrossAccounts(onOccurrence: true, span: .futureEvents, crossesAccounts: true),
                       "span future starts a new series and reports its id")
        let reason = EventKitManager.occurrenceAcrossAccountsReason
        XCTAssertTrue(reason.contains("moves the whole series"), reason)
        XCTAssertTrue(reason.contains("Nothing was written."), reason)
        XCTAssertFalse(reason.contains(where: { "&<>".contains($0) }), reason)
    }

    // MARK: - #426: a new calendar on one occurrence, within one account

    /// Measured on iCloud: span this with a calendar of the same account answered updated and every
    /// occurrence moved, through the series' id plus occurrence_date and through the occurrence's id.
    func testANewCalendarOnOneOccurrenceIsRefusedWithinOneAccountToo() {
        XCTAssertTrue(EventKitManager.refusesCalendarOnOccurrence(onOccurrence: true, span: .thisEvent, applyToAll: false, changesCalendar: true))
        XCTAssertFalse(EventKitManager.refusesCalendarOnOccurrence(onOccurrence: true, span: .thisEvent, applyToAll: false, changesCalendar: false), "the calendar it is in")
        XCTAssertFalse(EventKitManager.refusesCalendarOnOccurrence(onOccurrence: false, span: .thisEvent, applyToAll: false, changesCalendar: true), "a one-off")
        XCTAssertFalse(EventKitManager.refusesCalendarOnOccurrence(onOccurrence: true, span: .futureEvents, applyToAll: false, changesCalendar: true), "not this check")
        let reason = EventKitManager.occurrenceCalendarReason
        for phrase in ["moves the whole series", "use move_events_batch with span 'all'", "with its occurrence_dates and span 'this'", "leave calendar_name out", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), reason)
        }
    }

    func testTheCalendarRefusalComesBeforeTheFirstWrite() throws {
        let source = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        let refusal = try XCTUnwrap(source.range(of: "if Self.refusesCalendarOnOccurrence( onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span, applyToAll: applyToAll, changesCalendar: newCalendar.map { $0.calendarIdentifier != event.calendar?.calendarIdentifier } ?? false) { throw EventKitError.moveRefused(reason: Self.occurrenceCalendarReason) }"))
        let write = try XCTUnwrap(source.range(of: "if let t = title { event.title = t }"))
        XCTAssertLessThan(refusal.lowerBound, write.lowerBound)
    }

    // MARK: - #434 verify: the rule of a series is not changed through one occurrence

    /// Measured on iCloud: a rule saved on one occurrence (span this) left that occurrence as a
    /// one-off and deleted the rest of the series, and clear_recurrence there detached the
    /// occurrence as a one-off and left the series repeating. Span all and span future changed the
    /// rule.
    func testARuleChangeOnOneOccurrenceIsRefused() {
        XCTAssertTrue(EventKitManager.refusesRecurrenceChangeOnOccurrence(onOccurrence: true, span: .thisEvent, changesRecurrence: true))
        XCTAssertFalse(EventKitManager.refusesRecurrenceChangeOnOccurrence(onOccurrence: true, span: .thisEvent, changesRecurrence: false),
                       "an ordinary edit of one occurrence")
        XCTAssertFalse(EventKitManager.refusesRecurrenceChangeOnOccurrence(onOccurrence: false, span: .thisEvent, changesRecurrence: true),
                       "a one-off event gains a rule, and span all saves the series object")
        XCTAssertFalse(EventKitManager.refusesRecurrenceChangeOnOccurrence(onOccurrence: true, span: .futureEvents, changesRecurrence: true),
                       "span future from an occurrence splits the series and the rule applies from there")
    }

    /// PR #439 verify round 2, measured on iCloud and on v1.22.0: clear_recurrence with
    /// occurrence_date and span future left one event on the series' first day, of ten, so the
    /// occurrences before the one named went too, and answered `updated`. Span all has no
    /// occurrence object, and leaves that one event on purpose.
    func testClearingARuleFromOneOccurrenceIsRefused() {
        XCTAssertTrue(EventKitManager.refusesClearRecurrenceFromOccurrence(onOccurrenceObject: true, span: .futureEvents, clearRecurrence: true))
        XCTAssertFalse(EventKitManager.refusesClearRecurrenceFromOccurrence(onOccurrenceObject: false, span: .futureEvents, clearRecurrence: true),
                       "span all saves the series object")
        XCTAssertFalse(EventKitManager.refusesClearRecurrenceFromOccurrence(onOccurrenceObject: true, span: .futureEvents, clearRecurrence: false),
                       "a rule from one occurrence on")
    }

    /// PR #439 verify round 2: only a `/RID=` id or a detached event is its own address, and a
    /// stand-in was reached through the series' id.
    func testTheRefusalKnowsHowTheOccurrenceWasAddressed() {
        func address(_ id: String, detached: Bool, standIn: Bool = false) -> EventKitManager.RecurrenceChangeAddress {
            EventKitManager.recurrenceChangeAddress(identifier: id, isDetached: detached, viaStandIn: standIn)
        }
        XCTAssertEqual(address("S:E", detached: false), .seriesId)
        XCTAssertEqual(address("S:E/RID=123", detached: true), .occurrenceOwnId(series: "S:E"))
        XCTAssertEqual(address("X", detached: true), .occurrenceOwnId(series: nil), "another source's id")
        XCTAssertEqual(address("/RID=123", detached: true), .occurrenceOwnId(series: nil), "nothing before the marker")
        XCTAssertEqual(address("S:E", detached: true, standIn: true), .seriesId)
    }

    func testTheRefusalsPointAtWhatWorksFromTheAddressGiven() {
        func text(clearing: Bool, _ address: EventKitManager.RecurrenceChangeAddress) -> String {
            EventKitError.recurrenceChangeOnOccurrenceRefused(clearing: clearing, address: address).errorDescription ?? ""
        }
        let cases = [(false, EventKitManager.RecurrenceChangeAddress.seriesId), (true, .seriesId),
                     (false, .occurrenceOwnId(series: "S:E")), (true, .occurrenceOwnId(series: "S:E")),
                     (false, .occurrenceOwnId(series: nil)), (true, .occurrenceOwnId(series: nil))]
        for (clearing, address) in cases {
            let message = text(clearing: clearing, address)
            XCTAssertTrue(message.contains("Nothing was written."), message)
            XCTAssertTrue(message.contains("span 'all'"), message)
            XCTAssertFalse(message.contains(where: { "&<>".contains($0) }), message)
        }
        // A bare id: both ways to change the rule, and span future only for a rule.
        XCTAssertTrue(text(clearing: false, .seriesId).contains("span 'future' with occurrence_date"))
        // Clearing never goes through span future, which collapsed the series, and a refused caller
        // is not sent to a delete, which would take the occurrence named too (PR #439 verify round
        // 3). Measured on iCloud: span 'all' with end_date ends the series there and keeps its id; a
        // bare date ends it before that day's occurrence.
        for address in [EventKitManager.RecurrenceChangeAddress.seriesId, .occurrenceOwnId(series: "S:E"), .occurrenceOwnId(series: nil)] {
            let message = text(clearing: true, address)
            XCTAssertTrue(message.contains("deletes the other occurrences"), message)
            XCTAssertFalse(message.contains("Pass span 'future'"), message)
            XCTAssertFalse(message.contains("delete_event"), message)
            for phrase in ["span 'all'", "whole rule", "end_date", "23:59:59", "a bare date", "also one edited on its own"] {
                XCTAssertTrue(message.contains(phrase), "\(phrase): \(message)")
            }
        }
        // An occurrence's own id is told the series' id, not to add a span to itself, and span
        // future from the series' id does not find an occurrence edited on its own.
        for clearing in [false, true] {
            let message = text(clearing: clearing, .occurrenceOwnId(series: "S:E"))
            XCTAssertTrue(message.contains("the series' id, S:E,"), message)
            XCTAssertFalse(message.contains("Pass span"), message)
            let unnamed = text(clearing: clearing, .occurrenceOwnId(series: nil))
            XCTAssertTrue(unnamed.contains("the series' id"), unnamed)
            XCTAssertFalse(unnamed.contains("Pass span"), unnamed)
        }
        XCTAssertTrue(text(clearing: false, .occurrenceOwnId(series: "S:E")).contains("an occurrence not edited on its own"))
    }

    func testUpdateEventRefusesARuleChangeOnOneOccurrenceBeforeAnyWrite() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let refusal = "if Self.refusesRecurrenceChangeOnOccurrence( onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span, changesRecurrence: clearRecurrence || recurrenceRule != nil) || Self.refusesClearRecurrenceFromOccurrence( onOccurrenceObject: event !== masterEvent, span: span, clearRecurrence: clearRecurrence) { throw EventKitError.recurrenceChangeOnOccurrenceRefused( clearing: clearRecurrence, address: Self.recurrenceChangeAddress(identifier: identifier, isDetached: masterEvent.isDetached, viaStandIn: resolved.viaStandIn)) }"
        let refuse = try XCTUnwrap(flat.range(of: refusal), "refusal wired")
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        XCTAssertLessThan(refuse.lowerBound, firstWrite.lowerBound, "refused before the first field is assigned")
    }

    /// The wiring in `EventKitManager.updateEvent` (no in-memory store can run it).
    func testUpdateEventDerivesTheSeriesFromTheSavedObjectIdentity() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("let masterRefreshed = savedIsOccurrence && !resolved.viaStandIn && masterEvent.refresh() let seriesIdentifier"),
                      "refresh result kept, stand-in never trusted")
        XCTAssertTrue(flat.contains("UpdatedIdentifier.savedOccurrenceSeries( savedIsOccurrence: event !== masterEvent, span: span, masterRefreshed: masterRefreshed, master: masterRefreshed ? masterEvent.eventIdentifier : nil, occurrence: event.eventIdentifier)"),
                      String(flat.suffix(900)))
        XCTAssertTrue(flat.contains("let crossesAccounts = newCalendar.map { $0.calendarIdentifier != event.calendar?.calendarIdentifier && FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: event.calendar?.source?.sourceIdentifier, toSourceID: $0.source?.sourceIdentifier) } ?? false"), "the calendar it is already in moves nothing")
        XCTAssertTrue(flat.contains("changesAccount: crossesAccounts,"))
        let refusal = "if Self.refusesOccurrenceEditAcrossAccounts( onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span, crossesAccounts: crossesAccounts) { throw EventKitError.moveRefused(reason: Self.occurrenceAcrossAccountsReason) }"
        let refuse = try XCTUnwrap(flat.range(of: refusal), "refusal wired")
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        XCTAssertLessThan(refuse.lowerBound, firstWrite.lowerBound, "refused before the first field is assigned")
        let save = try XCTUnwrap(flat.range(of: "try eventStore.save(event, span: span)"))
        let seriesCall = try XCTUnwrap(flat.range(of: "UpdatedIdentifier.savedOccurrenceSeries("))
        XCTAssertLessThan(save.lowerBound, seriesCall.lowerBound, "read after the save")
    }

    // MARK: - The series' id through its first edited occurrence (#428 verify r1)

    /// The saved object is the occurrence: its id's part before /RID= is the series. With no /RID=
    /// the saved id itself is the series' id after the save, never the input, which may resolve to
    /// nothing now.
    func testTheFirstOccurrenceRouteReportsTheSeriesOfTheSavedId() {
        func fields(saved: String?) -> [String: Any] {
            UpdatedIdentifier.responseFields(input: "A", saved: saved,
                                             seriesIdentifier: UpdatedIdentifier.seriesThroughOccurrence(saved: saved))
        }
        let kept = fields(saved: "A/RID=5")
        XCTAssertEqual(kept["id"] as? String, "A")
        XCTAssertEqual(kept["id_changed"] as? Bool, false)
        XCTAssertEqual(kept["occurrence_id"] as? String, "A/RID=5")
        let split = fields(saved: "B/RID=5")
        XCTAssertEqual(split["id"] as? String, "B")
        XCTAssertEqual(split["id_changed"] as? Bool, true)
        XCTAssertEqual(split["previous_id"] as? String, "A")
        let plain = fields(saved: "B")
        XCTAssertEqual(plain["id"] as? String, "B", "not the input")
        XCTAssertEqual(plain["id_changed"] as? Bool, true)
        XCTAssertEqual(plain["previous_id"] as? String, "A")
        XCTAssertEqual(fields(saved: nil)["id"] as? String, "A")
        XCTAssertEqual(fields(saved: "")["id_changed"] as? Bool, false)
    }
}
