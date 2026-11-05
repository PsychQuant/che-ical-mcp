import EventKit
import XCTest
@testable import CheICalMCP

/// #416: a whole-series write addressed through the identifier of an occurrence that was edited on
/// its own. Measured on device (iCloud, 2026-11-05): `update_event` with span `all` or `future`
/// split the series into a new one with a new identifier, and `delete_event` with span `all`
/// deleted that occurrence only while answering that the series was deleted. Both are refused
/// before anything is written (the coordinator's default A while the maintainer has not answered).
///
/// An occurrence is recognized by the object's `isDetached` or by `/RID=` in the identifier: on
/// Google and Exchange an edited occurrence carries no `/RID=` (#320), so the identifier alone
/// would miss it. Only iCloud was measured on device.
final class DetachedOccurrenceSpanTests: XCTestCase {
    private let series = "CAL-1:SERIES-1"
    private let iCloudOccurrence = "CAL-1:SERIES-1/RID=826768800"
    /// The shape #320 reports for Google and Exchange: no `/RID=` slot.
    private let otherSourceOccurrence = "CAL-2:OCCURRENCE-7"

    // MARK: - Recognizing an occurrence

    func testAnOccurrenceIsRecognizedByIsDetachedOrByItsRIDSlot() {
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: iCloudOccurrence, isDetached: true))
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: iCloudOccurrence, isDetached: false),
                      "the /RID= slot alone is enough")
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: otherSourceOccurrence, isDetached: true),
                      "isDetached alone is enough (#320: no /RID= on Google or Exchange)")
        XCTAssertFalse(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: series, isDetached: false))
    }

    // MARK: - update_event

    func testUpdateThroughAnOccurrenceIsRefusedForAllAndFuture() {
        for (identifier, isDetached) in [(iCloudOccurrence, true), (iCloudOccurrence, false), (otherSourceOccurrence, true)] {
            XCTAssertTrue(DetachedOccurrenceSpan.refusesUpdate(identifier: identifier, isDetached: isDetached,
                                                               wholeSeries: true, span: .futureEvents),
                          "span all through \(identifier), isDetached \(isDetached)")
            XCTAssertTrue(DetachedOccurrenceSpan.refusesUpdate(identifier: identifier, isDetached: isDetached,
                                                               wholeSeries: false, span: .futureEvents),
                          "span future through \(identifier), isDetached \(isDetached)")
            XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: identifier, isDetached: isDetached,
                                                                wholeSeries: false, span: .thisEvent),
                           "span this through \(identifier) edits that occurrence and stays allowed")
        }
    }

    func testUpdateThroughTheSeriesIdentifierIsNotRefused() {
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: series, isDetached: false, wholeSeries: true, span: .futureEvents))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: series, isDetached: false, wholeSeries: false, span: .futureEvents))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesUpdate(identifier: series, isDetached: false, wholeSeries: false, span: .thisEvent))
    }

    // MARK: - delete span all

    func testASeriesDeleteThroughAnOccurrenceIsRefused() {
        XCTAssertTrue(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: iCloudOccurrence, isDetached: true))
        XCTAssertTrue(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: iCloudOccurrence, isDetached: false))
        XCTAssertTrue(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: otherSourceOccurrence, isDetached: true))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesSeriesDelete(identifier: series, isDetached: false))
    }

    // MARK: - Messages

    func testTheUpdateRefusalNamesTheSpanAndPointsToTheSeriesIdentifier() {
        for (wholeSeries, name) in [(true, "'all'"), (false, "'future'")] {
            let reason = DetachedOccurrenceSpan.updateReason(wholeSeries: wholeSeries)
            XCTAssertTrue(reason.contains("span \(name)"), reason)
            XCTAssertTrue(reason.contains("split the series"), reason)
            XCTAssertTrue(reason.contains("series' identifier"), reason)
            XCTAssertTrue(reason.contains("/RID="), reason)
            XCTAssertTrue(reason.contains("occurrence_date"), reason)
            XCTAssertTrue(reason.contains("span 'this'"), "the per-occurrence edit is still offered: \(reason)")
            XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
        }
    }

    func testTheDeleteRefusalSaysWhatWouldHaveHappened() {
        let reason = DetachedOccurrenceSpan.seriesDeleteReason
        XCTAssertTrue(reason.contains("span 'all'"), reason)
        XCTAssertTrue(reason.contains("only that occurrence"), reason)
        XCTAssertTrue(reason.contains("series' identifier"), reason)
        XCTAssertTrue(reason.contains("span 'this'"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was deleted."), reason)
    }

    func testTheRefusalSurfacesItsReasonVerbatim() {
        let reason = DetachedOccurrenceSpan.seriesDeleteReason
        let error = EventKitError.occurrenceAddressRefused(reason: reason)
        XCTAssertEqual(error.errorDescription, reason)
        XCTAssertEqual(EventKitErrorSanitizer.sanitizeForResponse(error).code, reason,
                       "a fixed text, so it reaches the caller as written")
    }

    /// The batch row speaks for that row: other rows of the same call may have been deleted, and
    /// `delete_events_batch` calls the parameter `event_ids`.
    func testTheBatchRowReasonSpeaksForItsRow() {
        let reason = DetachedOccurrenceSpan.seriesDeleteBatchReason
        XCTAssertTrue(reason.contains("only that occurrence"), reason)
        XCTAssertTrue(reason.contains("series' identifier"), reason)
        XCTAssertTrue(reason.contains("span 'this'"), reason)
        XCTAssertTrue(reason.hasSuffix("This row deleted nothing."), reason)
        XCTAssertFalse(reason.contains("Nothing was deleted"), "the batch's other rows may have been")
        XCTAssertFalse(reason.contains("event_id "), reason)
    }

    // MARK: - delete_events_batch dry run

    /// The preview by `event_ids` tells what the real call will refuse, for span all only.
    func testTheDryRunReportsTheRefusalForSpanAllOnly() {
        XCTAssertEqual(DetachedOccurrenceSpan.dryRunRefusal(span: "all", identifier: iCloudOccurrence, isDetached: true),
                       DetachedOccurrenceSpan.seriesDeleteBatchReason)
        XCTAssertEqual(DetachedOccurrenceSpan.dryRunRefusal(span: "all", identifier: otherSourceOccurrence, isDetached: true),
                       DetachedOccurrenceSpan.seriesDeleteBatchReason)
        XCTAssertNil(DetachedOccurrenceSpan.dryRunRefusal(span: "all", identifier: series, isDetached: false))
        XCTAssertNil(DetachedOccurrenceSpan.dryRunRefusal(span: "this", identifier: iCloudOccurrence, isDetached: true))
        XCTAssertNil(DetachedOccurrenceSpan.dryRunRefusal(span: "future", identifier: iCloudOccurrence, isDetached: true))
    }

    func testTheDryRunByEventIdsUsesTheRefusal() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/Server.swift")
        let source = SourceScan.strippingComments(try String(contentsOf: url, encoding: .utf8))
        let preview = try slice(source, from: "let event = try await eventKitManager.getEvent(identifier: id)", to: "\"start_date_local\"")
        XCTAssertTrue(preview.contains("if let refusal = DetachedOccurrenceSpan.dryRunRefusal(span: spanStr, identifier: id, isDetached: event.isDetached) { preview.append([\"event_id\": id, \"error\": refusal]) continue }"), preview)
    }

    // MARK: - Wiring (source pins: the writes cannot be driven without EventKit access)

    private func managerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        return SourceScan.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// The slice of `source` from `start` up to the first `end` after it.
    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), start)
        let rest = source[from.upperBound...]
        let until = try XCTUnwrap(rest.range(of: end), "\(start) … \(end)")
        return SourceScan.collapsingWhitespace(String(rest[..<until.lowerBound]))
    }

    func testUpdateEventChecksBeforeItTakesTheSnapshotOrWrites() throws {
        let head = try slice(try managerSource(), from: "func updateEvent(", to: "let oldSnapshot = EventSnapshot(from: masterEvent)")
        XCTAssertTrue(head.contains("if DetachedOccurrenceSpan.refusesUpdate( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, span: span) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.updateReason(wholeSeries: applyToAll)) }"),
                      head)
    }

    func testTheSeriesDeletesCheckBeforeTheyRemove() throws {
        let source = try managerSource()
        let single = try slice(source, from: "func deleteEventSeries(identifier: String)", to: "eventStore.remove(")
        XCTAssertTrue(single.contains("if DetachedOccurrenceSpan.refusesSeriesDelete(identifier: identifier, isDetached: event.isDetached) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.seriesDeleteReason) }"),
                      single)
        let batch = try slice(source, from: "func deleteEventSeriesBatch(", to: "eventStore.remove(")
        XCTAssertTrue(batch.contains("if refusingOccurrenceIdentifiers, DetachedOccurrenceSpan.refusesSeriesDelete(identifier: id, isDetached: event.isDetached) { failures.append((id, DetachedOccurrenceSpan.seriesDeleteBatchReason)) continue }"),
                      batch)
    }
}
