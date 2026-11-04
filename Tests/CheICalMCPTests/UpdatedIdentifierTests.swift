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

    /// Device (iCloud, 2026-11-04): an edit of one occurrence (occurrence_date, span this) saves a
    /// detached occurrence that reads back as `<series>/RID=<seconds>`. That id addresses only the
    /// occurrence; the series keeps its identifier, so `id` stays the input and the occurrence's
    /// own id is a separate field.
    func testAnOccurrenceOfTheSameSeriesKeepsTheSeriesIdentifier() {
        let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: "CAL:SERIES/RID=834627600")
        XCTAssertEqual(fields["id"] as? String, "CAL:SERIES")
        XCTAssertEqual(fields["id_changed"] as? Bool, false)
        XCTAssertEqual(fields["occurrence_id"] as? String, "CAL:SERIES/RID=834627600")
        XCTAssertNil(fields["previous_id"])
    }

    /// Another series' occurrence (a cross-account move of an occurrence, a split) is a change.
    func testAnOccurrenceOfAnotherSeriesIsAChange() {
        let fields = UpdatedIdentifier.responseFields(input: "CAL:SERIES", saved: "OTHER:NEW/RID=834627600")
        XCTAssertEqual(fields["id"] as? String, "OTHER:NEW/RID=834627600")
        XCTAssertEqual(fields["id_changed"] as? Bool, true)
        XCTAssertNil(fields["occurrence_id"])
        let prefixOnly = UpdatedIdentifier.responseFields(input: "CAL:SER", saved: "CAL:SERIES/RID=1")
        XCTAssertEqual(prefixOnly["id_changed"] as? Bool, true, "a longer series id sharing the prefix is another item")
    }
}

