import Foundation
import XCTest
@testable import CheICalMCP

/// #335 item 6: `delete_events_batch` (its rows, and its `dry_run` by `event_ids`) answered a bare
/// series id refused because of an earlier edited occurrence with `delete_event`'s text, which
/// tells the caller to use `occurrence_date` and span 'this' — parameters the batch by `event_ids`
/// does not have. The batch now gives its own text, naming what reaches a single occurrence from
/// a batch caller: `delete_event` with `occurrence_date`, or this tool by calendar and date range.
final class StandInBatchReasonTests: XCTestCase {
    func testTheBatchTextNamesWaysABatchCallerHas() {
        let text = EventKitManager.standInEditedBeforeBatchReason
        for phrase in ["delete_event", "occurrence_date", "span 'this'", "calendar_name", "date range"] {
            XCTAssertTrue(text.contains(phrase), "should name '\(phrase)': \(text)")
        }
        XCTAssertFalse(text.contains("RID"), "the route is named in words a caller can use, not an id's shape")
        XCTAssertNotEqual(text, EventKitManager.standInEditedBeforeReason)
    }

    func testOnlyTheEditedBeforeReasonIsReplacedForBatchRows() {
        XCTAssertEqual(EventKitManager.batchRowReason(EventKitManager.standInEditedBeforeReason),
                       EventKitManager.standInEditedBeforeBatchReason)
        XCTAssertEqual(EventKitManager.batchRowReason(EventKitManager.standInAllEditedReason),
                       EventKitManager.standInAllEditedReason, "the all-edited hint (/RID= ids) works for event_ids too")
        XCTAssertEqual(EventKitManager.batchRowReason("Event not found"), "Event not found")
    }

    func testTheDryRunErrorIsMappedTheSameWay() {
        guard case EventKitError.standInRefused(let reason) =
                EventKitManager.batchRowError(EventKitError.standInRefused(reason: EventKitManager.standInEditedBeforeReason)) else {
            return XCTFail("still a stand-in refusal")
        }
        XCTAssertEqual(reason, EventKitManager.standInEditedBeforeBatchReason)
        guard case EventKitError.eventNotFound(let id) = EventKitManager.batchRowError(EventKitError.eventNotFound(identifier: "x")) else {
            return XCTFail("other errors pass through")
        }
        XCTAssertEqual(id, "x")
    }

    /// The wiring (source pins: the paths need a real event store): both batch row sites go through
    /// `notFoundReason`, which maps for batch rows, and the `event_ids` dry run maps its error.
    func testTheBatchPathsUseTheBatchText() throws {
        let guardSource = try SourcePins.source("EventKit/EventKitManager+UndoGuard.swift")
        let reason = try XCTUnwrap(SourcePins.body(of: "func notFoundReason(id: String)", in: guardSource))
        XCTAssertTrue(reason.contains("batchRowReason("), reason)
        let server = try SourcePins.source("Server.swift")
        let handler = try XCTUnwrap(SourcePins.body(of: "private func handleDeleteEventsBatch(", in: server))
        XCTAssertTrue(SourceScan.collapsingWhitespace(handler).contains("error: EventKitManager.batchRowError(error)"), handler)
    }
}
