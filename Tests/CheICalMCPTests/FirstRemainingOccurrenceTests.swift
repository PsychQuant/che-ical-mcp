import CheMCPKit
import XCTest
@testable import CheICalMCP

/// Pure-unit tests for resolving a series whose first occurrence was deleted (#326, root cause #284).
///
/// For such a series `event(withIdentifier: <series id>)` still returns the series object, but its
/// `refresh()` returns false, so `freshEvent` returned nil and move, update, copy and delete all
/// reported "Event not found" (device, iCloud, 2026-10-19). The remaining occurrences are still
/// listed with the series identifier, so the earliest of them stands in for the series. Which
/// listed event qualifies is decided here; the narrow conditions keep a detached occurrence
/// (no rules of its own, so a caller would treat it as a one-off) and a different series out.
final class FirstRemainingOccurrenceTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func candidate(_ id: String?, detached: Bool = false, rules: Bool = true, dayOffset: Double,
                           slotOffset: Double? = nil, sameSeriesByExternalID: Bool = false) -> FirstRemainingOccurrence.Candidate {
        .init(eventIdentifier: id, isDetached: detached, hasRecurrenceRules: rules,
              start: start.addingTimeInterval(dayOffset * day),
              slot: slotOffset.map { start.addingTimeInterval($0 * day) },
              sameSeriesByExternalID: sameSeriesByExternalID)
    }

    func testTheEarliestOccurrenceOfTheSeriesIsPicked() {
        let listed = [candidate("S", dayOffset: 14), candidate("S", dayOffset: 7), candidate("S", dayOffset: 21)]
        XCTAssertEqual(FirstRemainingOccurrence.pick(listed, identifier: "S"), 1)
    }

    func testAnotherSeriesAndAnEditedOccurrenceAreNotPicked() {
        let listed = [
            candidate("T", dayOffset: 1),                              // another series
            candidate("S/RID=1", detached: true, rules: false, dayOffset: 12, slotOffset: 12), // edited, after the stand-in
            candidate("S", detached: true, dayOffset: 30, slotOffset: 30), // detached even though it kept the id (after the stand-in)
            candidate("S", rules: false, dayOffset: 4),                // a one-off sharing the id: not the series
            candidate(nil, dayOffset: 5),
            candidate("S", dayOffset: 9)
        ]
        XCTAssertEqual(FirstRemainingOccurrence.pick(listed, identifier: "S"), 5)
    }

    func testNothingIsPickedWhenTheSeriesHasNoOccurrenceLeft() {
        XCTAssertNil(FirstRemainingOccurrence.pick([], identifier: "S"))
        XCTAssertNil(FirstRemainingOccurrence.pick([candidate("T", dayOffset: 1), candidate("S", detached: true, dayOffset: 2)],
                                                   identifier: "S"))
    }

    func testTheIdentifierMustMatchExactlyNotByPrefix() {
        XCTAssertNil(FirstRemainingOccurrence.pick([candidate("S2", dayOffset: 1), candidate("S/RID=5", dayOffset: 2)],
                                                   identifier: "S"))
    }

    /// Ties go to the one listed first, so the answer does not depend on sort stability.
    func testTwoOccurrencesStartingTogetherGiveTheFirstListed() {
        XCTAssertEqual(FirstRemainingOccurrence.pick([candidate("S", dayOffset: 3), candidate("S", dayOffset: 3)], identifier: "S"), 0)
    }

    /// An occurrence edited on its own whose slot is before the stand-in would be left behind by a
    /// write from the stand-in (a delete or update with `.futureEvents` covers its slot onward):
    /// the call would report success with part of the series untouched (verify round 1, #326). The
    /// series then stays not found, and the edited occurrence's own id is the way in.
    func testASeriesWithAnEditedOccurrenceBeforeTheStandInIsNotResolved() {
        let listed = [candidate("S", dayOffset: 14),
                      candidate("S/RID=5", detached: true, rules: false, dayOffset: 8, slotOffset: 7)]
        XCTAssertNil(FirstRemainingOccurrence.pick(listed, identifier: "S"))
    }

    /// The refusal is conservative about how an edited occurrence is tied to its series (verify
    /// round 2): a detached occurrence that kept the bare series id, and one that other stores give
    /// an unrelated identifier but the same iCalendar UID (the external identifier), count too.
    func testAnEditedOccurrenceKeepingTheBareIdOrTheSameUIDAlsoBlocks() {
        XCTAssertNil(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S", detached: true, dayOffset: 3, slotOffset: 3)], identifier: "S"))
        XCTAssertNil(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14),
             candidate("unrelated-id", detached: true, rules: false, dayOffset: 3, slotOffset: 3, sameSeriesByExternalID: true)],
            identifier: "S"))
        XCTAssertEqual(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("unrelated-id", detached: true, rules: false, dayOffset: 3, slotOffset: 3)],
            identifier: "S"), 0, "an unrelated detached event is not the series' edited occurrence")
    }

    /// A move changes the calendar of the whole series and a copy copies one occurrence, so neither
    /// leaves an edited occurrence behind (device, iCloud, 2026-10-21: a move from the stand-in
    /// with an edited occurrence before it moved all 16 events; a delete from it left that
    /// occurrence in place). They resolve the stand-in without the edited-before refusal
    /// (verify round 4); deletes and updates keep it.
    func testTheEditedBeforeRefusalCanBeSwitchedOffForMoveAndCopy() {
        let listed = [candidate("S", dayOffset: 14),
                      candidate("S/RID=5", detached: true, rules: false, dayOffset: 8, slotOffset: 7)]
        XCTAssertNil(FirstRemainingOccurrence.pick(listed, identifier: "S"))
        XCTAssertNil(FirstRemainingOccurrence.pick(listed, identifier: "S", refuseWhenEditedBefore: true))
        XCTAssertEqual(FirstRemainingOccurrence.pick(listed, identifier: "S", refuseWhenEditedBefore: false), 0)
    }

    /// The refusal of span future at the stand-in itself turns on `<=`: an occurrence that starts
    /// at the stand-in is the stand-in (refused), a later one is not (verify round 4: nothing
    /// pinned the operator).
    func testSpanFutureAtTheStandInIsRefusedAndLaterOccurrencesAreNot() {
        let standIn = start
        XCTAssertTrue(FirstRemainingOccurrence.refusesFutureUpdate(viaStandIn: true, isFutureSpan: true,
                                                                   occurrenceStart: standIn, standInStart: standIn))
        XCTAssertTrue(FirstRemainingOccurrence.refusesFutureUpdate(viaStandIn: true, isFutureSpan: true,
                                                                   occurrenceStart: standIn.addingTimeInterval(-day), standInStart: standIn))
        XCTAssertFalse(FirstRemainingOccurrence.refusesFutureUpdate(viaStandIn: true, isFutureSpan: true,
                                                                    occurrenceStart: standIn.addingTimeInterval(day), standInStart: standIn))
        XCTAssertFalse(FirstRemainingOccurrence.refusesFutureUpdate(viaStandIn: false, isFutureSpan: true,
                                                                    occurrenceStart: standIn, standInStart: standIn), "a healthy series is never refused")
        XCTAssertFalse(FirstRemainingOccurrence.refusesFutureUpdate(viaStandIn: true, isFutureSpan: false,
                                                                    occurrenceStart: standIn, standInStart: standIn))
    }

    /// An occurrence's own id is not a way round the refusal: updating the whole series from an
    /// occurrence edited on its own splits it too (device, iCloud, 2026-10-21, on a series that
    /// had lost no occurrence), so the message does not recommend it.
    func testTheRefusalDoesNotRecommendAnOccurrencesOwnId() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.contains("static let standInSplitReason") })
        XCTAssertFalse(line.contains("own id"), line)
    }

    func testMoveAndCopyResolveWithoutTheEditedBeforeRefusal() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for name in ["func copyEvent(", "func moveEventForCopyTool(", "func moveEvent("] {
            let from = try XCTUnwrap(source.range(of: name), name)
            XCTAssertTrue(source[from.upperBound...].prefix(900).contains("refuseWhenEditedBefore: false"), name)
        }
        for name in ["func deleteEvent(identifier", "func deleteEventSeries(", "func deleteEventsBatch("] {
            let from = try XCTUnwrap(source.range(of: name), name)
            XCTAssertFalse(source[from.upperBound...].prefix(900).contains("refuseWhenEditedBefore: false"), name)
        }
    }

    /// Judged by its slot, not by where it was moved: moved later than the stand-in but originally
    /// before it still blocks; moved earlier but originally after it does not.
    func testTheEditedOccurrenceIsJudgedByItsSlot() {
        XCTAssertNil(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S/RID=5", detached: true, rules: false, dayOffset: 30, slotOffset: 7)], identifier: "S"))
        XCTAssertEqual(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S/RID=5", detached: true, rules: false, dayOffset: 3, slotOffset: 21)], identifier: "S"), 0)
        XCTAssertEqual(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S/RID=5", detached: true, rules: false, dayOffset: 30, slotOffset: 21)], identifier: "S"), 0)
    }

    /// The resolution flow of `freshEvent`, with lookup, refresh and the stand-in injected
    /// (closure seam, #182): the cases a source-string check cannot tell apart (verify round 1).
    func testResolutionReturnsTheStoredObjectWhenItRefreshesAndNeverAsksForAStandIn() {
        var askedStandIn = false
        let result = FirstRemainingOccurrence.resolve(stored: "series", refresh: { _ in true },
                                                      standIn: { _ in askedStandIn = true; return "occurrence" })
        XCTAssertEqual(result?.event, "series")
        XCTAssertEqual(result?.viaStandIn, false)
        XCTAssertFalse(askedStandIn)
    }

    func testResolutionReturnsTheStandInAndSaysSoWhenTheStoredObjectDoesNotRefresh() {
        let result = FirstRemainingOccurrence.resolve(stored: "series", refresh: { _ in false }, standIn: { _ in "occurrence" })
        XCTAssertEqual(result?.event, "occurrence")
        XCTAssertEqual(result?.viaStandIn, true)
    }

    func testResolutionIsNilWhenNothingIsStoredOrNoStandInExists() {
        XCTAssertNil(FirstRemainingOccurrence.resolve(stored: String?.none, refresh: { _ in true }, standIn: { _ in "occurrence" }))
        XCTAssertNil(FirstRemainingOccurrence.resolve(stored: "series", refresh: { _ in false }, standIn: { _ in nil }))
    }

    /// A write to the whole series from the stand-in is a `.futureEvents` save on a middle
    /// occurrence, which EventKit splits into a new series with a new identifier (device, iCloud,
    /// 2026-10-20: after `update_event` span all the old id was "Event not found"; for an invitee
    /// it reads as the series cancelled and a new one sent). update_event refuses it for span all
    /// and for span future at the stand-in itself (verify round 3), before any write, with its
    /// own error (not labelled as a time range problem); move, copy and delete keep the
    /// identifier (device) and are not refused.
    func testUpdateRefusesAWholeSeriesSaveFromTheStandInBeforeAnyWrite() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func updateEvent("))
        let rest = source[from.upperBound...]
        let lookup = try XCTUnwrap(rest.range(of: "freshEventWithOrigin(id: identifier)"))
        let wholeRefusal = try XCTUnwrap(rest.range(of: "applyToAll, resolved.viaStandIn"))
        let futureRefusal = try XCTUnwrap(rest.range(of: "FirstRemainingOccurrence.refusesFutureUpdate("))
        let firstWrite = try XCTUnwrap(rest.range(of: "event.title = "))
        let save = try XCTUnwrap(rest.range(of: "try eventStore.save(event, span: span)"))
        XCTAssertLessThan(lookup.lowerBound, wholeRefusal.lowerBound)
        XCTAssertLessThan(wholeRefusal.lowerBound, futureRefusal.lowerBound)
        XCTAssertLessThan(futureRefusal.lowerBound, firstWrite.lowerBound, "refused before any field is written")
        XCTAssertLessThan(futureRefusal.lowerBound, save.lowerBound)
        XCTAssertFalse(rest.prefix(3000).contains("invalidTimeRange(\n                message: \"This series"), "own error, not a time range")
        let moveFrom = try XCTUnwrap(source.range(of: "func moveEvent("))
        XCTAssertFalse(source[moveFrom.lowerBound...].prefix(1500).contains("viaStandIn"), "move is not refused")
    }

    func testTheStandInRefusalIsATrustedFixedMessage() {
        let error = EventKitError.standInRefused(reason: "fixed reason")
        XCTAssertEqual(error.localizedDescription, "fixed reason")
        XCTAssertTrue((error as Error) is TrustedErrorMessage)
    }

    /// The guard that looks for edited occurrences lists the same ranges as #285's exception
    /// capture: the window and a year on each side (verify round 3), so one moved a few months out
    /// is seen too.
    func testTheStandInSearchListsTheSameRangesAsTheSeriesExceptionCapture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("SeriesExceptionsPlanner.listingRanges(for: window)"))
    }

    /// `freshEvent` and the dry-run preview (`getEvent`) both resolve through it; the preview used
    /// to read the unrefreshed object and so showed the deleted occurrence's date.
    func testGetEventResolvesThroughFreshEvent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func getEvent(identifier: String) async throws -> EKEvent {"))
        let to = try XCTUnwrap(source.range(of: "// MARK: - Search and Conflict Detection", range: from.upperBound..<source.endIndex))
        XCTAssertTrue(source[from.lowerBound..<to.lowerBound].contains("freshEvent(id: identifier)"))
    }

    /// `freshEvent` falls back to the earliest remaining occurrence only when the series object
    /// fails to refresh, and gives it back only if that occurrence refreshes too; a series whose
    /// object refreshes is returned as before, and one that is really gone stays nil.
    func testFreshEventFallsBackOnlyWhenTheSeriesObjectFailsToRefresh() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager+UndoGuard.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func freshEvent(id: String) -> EKEvent?"))
        let to = try XCTUnwrap(source.range(of: "func freshReminder(id: String)", range: from.upperBound..<source.endIndex))
        let body = String(source[from.lowerBound..<to.lowerBound])
        // The branches themselves are tested through `resolve`; this pins that freshEvent uses it.
        XCTAssertTrue(body.contains("FirstRemainingOccurrence.resolve("))
        XCTAssertTrue(body.contains("firstRemainingOccurrence(of:"))
    }
}
