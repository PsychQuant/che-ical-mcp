import EventKit
import XCTest
@testable import CheICalMCP

/// #416: writes that take a span, addressed through the identifier of an occurrence that was edited
/// on its own. Measured on device (iCloud, 2026-11-05) against `main` without these refusals:
///
/// | Occurrence (its own id) | `update_event` span `all` | `delete_event` / batch span `all` |
/// |---|---|---|
/// | middle, earlier ones remain | split; only it and the later ones updated | only it deleted, answered "all" |
/// | first | every occurrence updated, id kept | only it deleted, answered "all" |
/// | first left, first one deleted | every remaining one updated, new id | only it deleted, answered "all" |
/// | the only one left | it updated, new id | it deleted |
///
/// What is refused is what did something other than what the caller asked for: update span `all`
/// with an earlier occurrence left, delete span `all` with any other occurrence left. Span `future`
/// through such an identifier does what the span says and is not refused. These are the
/// coordinator's defaults while the maintainer has not answered.
///
/// The neighbours come from a scan of the series. An occurrence with no series to scan (no `/RID=`
/// on another source, #320, not checked) has unknown neighbours and is refused: nothing is written.
final class DetachedOccurrenceSpanTests: XCTestCase {
    private let series = "CAL-1:SERIES-1"
    private let iCloudOccurrence = "CAL-1:SERIES-1/RID=826768800"
    /// What #320 expects of other sources, not checked: no `/RID=` slot.
    private let otherSourceOccurrence = "CAL-2:OCCURRENCE-7"

    private let day: TimeInterval = 86_400

    private func unedited(_ days: Double) -> FirstRemainingOccurrence.Candidate {
        .init(eventIdentifier: series, isDetached: false, hasRecurrenceRules: true,
              start: Date(timeIntervalSinceReferenceDate: days * day))
    }

    private func edited(_ days: Double, id: String? = nil, start: Double? = nil) -> FirstRemainingOccurrence.Candidate {
        let slot = Date(timeIntervalSinceReferenceDate: days * day)
        return .init(eventIdentifier: id ?? "\(series)/RID=\(Int(days * day))", isDetached: true, hasRecurrenceRules: false,
                     start: start.map { Date(timeIntervalSinceReferenceDate: $0 * day) } ?? slot, slot: slot)
    }

    private func neighbours(of own: FirstRemainingOccurrence.Candidate,
                            among others: [FirstRemainingOccurrence.Candidate]) -> DetachedOccurrenceSpan.Neighbours {
        DetachedOccurrenceSpan.neighbours(of: own.eventIdentifier ?? "", slot: own.slot ?? own.start, among: others + [own])
    }

    // MARK: - Recognizing an occurrence

    func testAnOccurrenceIsRecognizedByIsDetachedOrByItsRIDSlot() {
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: iCloudOccurrence, isDetached: true))
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: iCloudOccurrence, isDetached: false),
                      "the /RID= slot alone is enough")
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: otherSourceOccurrence, isDetached: true),
                      "isDetached alone is enough (#320 expects no /RID= on other sources)")
        XCTAssertFalse(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: series, isDetached: false))
    }

    func testTheSeriesIdentifierIsThePartBeforeTheSlot() {
        XCTAssertEqual(DetachedOccurrenceSpan.seriesIdentifier(of: iCloudOccurrence), series)
        XCTAssertNil(DetachedOccurrenceSpan.seriesIdentifier(of: otherSourceOccurrence), "nothing to derive it from")
        XCTAssertNil(DetachedOccurrenceSpan.seriesIdentifier(of: "/RID=1"), "an empty series identifier is none")
    }

    // MARK: - Neighbours (the measured shapes)

    func testTheFourMeasuredShapes() {
        let middle = neighbours(of: edited(14), among: [unedited(0), unedited(7), unedited(21), unedited(28)])
        XCTAssertEqual(middle, .init(earlierRemain: true, othersRemain: true))
        let first = neighbours(of: edited(0), among: [unedited(7), unedited(14), unedited(21), unedited(28)])
        XCTAssertEqual(first, .init(earlierRemain: false, othersRemain: true))
        // The first occurrence was deleted, the second edited: nothing is left before it either.
        let firstLeft = neighbours(of: edited(7), among: [unedited(14), unedited(21), unedited(28)])
        XCTAssertEqual(firstLeft, .init(earlierRemain: false, othersRemain: true))
        let only = neighbours(of: edited(14), among: [])
        XCTAssertEqual(only, .init(earlierRemain: false, othersRemain: false))
    }

    func testSlotsDecideWhatIsEarlierNotTheShownTimes() {
        // The first occurrence moved past the second is still the first by slot.
        XCTAssertFalse(neighbours(of: edited(0, start: 10), among: [unedited(7)]).earlierRemain)
        // An earlier slot moved later still counts as earlier, and an edited one counts at all.
        XCTAssertTrue(neighbours(of: edited(14), among: [edited(7, start: 20)]).earlierRemain)
    }

    // MARK: - update_event

    func testUpdateSpanAllIsRefusedOnlyWithAnEarlierOccurrenceLeft() {
        let earlier = DetachedOccurrenceSpan.Neighbours(earlierRemain: true, othersRemain: true)
        let none = DetachedOccurrenceSpan.Neighbours(earlierRemain: false, othersRemain: true)
        XCTAssertTrue(DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, neighbours: earlier))
        XCTAssertTrue(DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: false, wholeSeries: true, neighbours: earlier),
                      "the /RID= arm")
        XCTAssertTrue(DetachedOccurrenceSpan.refusesUpdate(identifier: otherSourceOccurrence, isDetached: true, wholeSeries: true, neighbours: earlier),
                      "the isDetached arm")
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, neighbours: none),
                       "the first occurrence, or the first left: the update reaches every occurrence (measured)")
    }

    func testUnknownNeighboursAreRefusedForSpanAll() {
        XCTAssertTrue(DetachedOccurrenceSpan.refusesUpdate(identifier: otherSourceOccurrence, isDetached: true, wholeSeries: true, neighbours: nil))
    }

    func testSpanFutureAndSpanThisAreNotRefused() {
        let earlier = DetachedOccurrenceSpan.Neighbours(earlierRemain: true, othersRemain: true)
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, neighbours: earlier))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, neighbours: nil))
    }

    func testTheNeighboursAreNotScannedUnlessTheAnswerDependsOnThem() {
        var scans = 0
        let scan = { () -> DetachedOccurrenceSpan.Neighbours? in scans += 1; return nil }
        _ = DetachedOccurrenceSpan.refusesUpdate(identifier: series, isDetached: false, wholeSeries: true, neighbours: scan())
        _ = DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, neighbours: scan())
        _ = DetachedOccurrenceSpan.refusesSeriesDelete(identifier: series, isDetached: false, neighbours: scan())
        XCTAssertEqual(scans, 0)
        _ = DetachedOccurrenceSpan.refusesUpdate(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, neighbours: scan())
        XCTAssertEqual(scans, 1)
    }

    func testUpdateThroughTheSeriesIdentifierIsNotRefused() {
        let earlier = DetachedOccurrenceSpan.Neighbours(earlierRemain: true, othersRemain: true)
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: series, isDetached: false, wholeSeries: true, neighbours: earlier))
    }

    // MARK: - delete span all

    func testASeriesDeleteIsRefusedOnlyWithAnotherOccurrenceLeft() {
        for shape in [DetachedOccurrenceSpan.Neighbours(earlierRemain: true, othersRemain: true),
                      DetachedOccurrenceSpan.Neighbours(earlierRemain: false, othersRemain: true)] {
            XCTAssertTrue(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: iCloudOccurrence, isDetached: true, neighbours: shape))
            XCTAssertTrue(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: otherSourceOccurrence, isDetached: true, neighbours: shape))
        }
        XCTAssertFalse(DetachedOccurrenceSpan.refusesSeriesDelete(
            identifier: iCloudOccurrence, isDetached: true, neighbours: .init(earlierRemain: false, othersRemain: false)),
                       "the only occurrence left: deleting it deletes all that is left (measured)")
        XCTAssertTrue(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: otherSourceOccurrence, isDetached: true, neighbours: nil))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesSeriesDelete(
            identifier: series, isDetached: false, neighbours: .init(earlierRemain: true, othersRemain: true)))
    }

    // MARK: - Messages

    /// Only routes that were run on a device (iCloud, 2026-11-05): the earliest occurrence's id with
    /// span all updates every occurrence, the series id with span all deletes the series, and an
    /// edited earliest occurrence's id with span future deletes the series. The series id plus the
    /// edited occurrence's date is not named: it does not reach that occurrence.
    func testTheUpdateRefusalSaysWhatWouldHappenAndNamesRoutesThatWork() {
        let reason = DetachedOccurrenceSpan.updateReason
        XCTAssertTrue(reason.contains("span 'all'"), reason)
        XCTAssertTrue(reason.contains("split the series"), reason)
        XCTAssertTrue(reason.contains("earlier occurrences"), reason)
        XCTAssertTrue(reason.contains(DetachedOccurrenceSpan.earliestHint), reason)
        XCTAssertTrue(reason.contains("span 'future'"), "the update from this occurrence on stays available: \(reason)")
        XCTAssertTrue(reason.contains("span 'this'"), "the per-occurrence edit is still offered: \(reason)")
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
        XCTAssertFalse(reason.contains("occurrence_date"), "the series id plus this date does not reach an edited occurrence: \(reason)")
    }

    func testTheDeleteRefusalSaysWhatWouldHappenAndNamesRoutesThatWork() {
        for (reason, suffix) in [(DetachedOccurrenceSpan.seriesDeleteReason, "Nothing was deleted."),
                                 (DetachedOccurrenceSpan.seriesDeleteBatchReason, "This row deleted nothing.")] {
            XCTAssertTrue(reason.contains("only this occurrence"), reason)
            XCTAssertTrue(reason.contains(DetachedOccurrenceSpan.earliestHint), reason)
            XCTAssertTrue(reason.contains("span 'all' when that id has no /RID=… part"), reason)
            XCTAssertTrue(reason.contains("span 'future' when it has one"), reason)
            XCTAssertTrue(reason.contains("span 'this'"), reason)
            XCTAssertTrue(reason.hasSuffix(suffix), reason)
        }
        XCTAssertTrue(DetachedOccurrenceSpan.seriesDeleteReason.hasPrefix("event_id names"))
        XCTAssertFalse(DetachedOccurrenceSpan.seriesDeleteBatchReason.contains("event_id "), "the batch names event_ids")
        XCTAssertFalse(DetachedOccurrenceSpan.seriesDeleteBatchReason.contains("Nothing was deleted"), "the batch's other rows may have been")
    }

    func testTheRefusalSurfacesItsReasonVerbatim() {
        let reason = DetachedOccurrenceSpan.seriesDeleteReason
        let error = EventKitError.occurrenceAddressRefused(reason: reason)
        XCTAssertEqual(error.errorDescription, reason)
        XCTAssertEqual(EventKitErrorSanitizer.sanitizeForResponse(error).code, reason,
                       "a fixed text, so it reaches the caller as written")
    }

    // MARK: - Wiring (source pins: the writes cannot be driven without EventKit access)

    private func collapsed(_ declaration: String, upTo end: String, in file: String) throws -> String {
        let source = SourceScan.strippingComments(try SourcePins.source(file))
        let body = try XCTUnwrap(SourcePins.body(of: declaration, in: source), declaration)
        let until = try XCTUnwrap(body.range(of: end), "\(declaration) … \(end)")
        return SourceScan.collapsingWhitespace(String(body[..<until.lowerBound]))
    }

    func testUpdateEventChecksBeforeItTakesTheSnapshotOrWrites() throws {
        let head = try collapsed("func updateEvent(", upTo: "let oldSnapshot = EventSnapshot(from: masterEvent)", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(head.contains("if DetachedOccurrenceSpan.refusesUpdate( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, neighbours: occurrenceNeighbours(of: masterEvent, id: identifier)) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.updateReason) }"), head)
    }

    func testTheSeriesDeletesCheckBeforeTheyRemove() throws {
        let single = try collapsed("func deleteEventSeries(identifier: String)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(single.contains("if refusesSeriesDelete(event, id: identifier) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.seriesDeleteReason) }"), single)
        let batch = try collapsed("func deleteEventSeriesBatch(identifiers: [String], refusingOccurrenceIdentifiers: Bool)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(batch.contains("if refusingOccurrenceIdentifiers, refusesSeriesDelete(event, id: id) { failures.append((id, DetachedOccurrenceSpan.seriesDeleteBatchReason)) continue }"), batch)
    }

    /// The preview by `event_ids` does not list what the real call refuses, for span all only.
    func testTheDryRunByEventIdsUsesTheRefusal() throws {
        let source = SourceScan.strippingComments(try SourcePins.source("Server.swift"))
        let batch = try XCTUnwrap(source.range(of: "private func handleDeleteEventsBatch("))
        let rest = source[batch.upperBound...]
        let until = try XCTUnwrap(rest.range(of: "\"start_date_local\""))
        let preview = SourceScan.collapsingWhitespace(String(rest[..<until.lowerBound]))
        XCTAssertTrue(preview.contains("if spanStr == \"all\", await eventKitManager.refusesSeriesDelete(identifier: id) { preview.append([\"event_id\": id, \"error\": DetachedOccurrenceSpan.seriesDeleteBatchReason]) continue }"), preview)
    }
}
