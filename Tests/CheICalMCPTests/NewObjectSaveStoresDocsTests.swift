import XCTest

/// #294: the Google results of the #261 probe (2026-11-05) are recorded where #261's limits are:
/// the `NewObjectSave` header and the #261 CHANGELOG entry. Exchange and local calendars stay open.
/// Each phrase occurs exactly once in its document, so a pin cannot survive its sentence's removal.
final class NewObjectSaveStoresDocsTests: XCTestCase {
    private func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func once(_ phrase: String, in text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, phrase, file: file, line: line)
    }

    func testTheHeaderRecordsTheGoogleResultAndTheOpenStores() throws {
        let header = try read("Sources/CheICalMCP/EventKit/NewObjectSave.swift")
        once("On a Google-hosted calendar (#294, 2026-11-05", in: header)
        once("the reminder and reminder-list paths cannot run on that source", in: header)
        once("Exchange and local calendars: not measured (#294).", in: header)
        XCTAssertFalse(header.contains("/// - stores other than iCloud.\n"), "the bare line is replaced")
    }

    func testTheChangelogEntryRecordsTheGoogleResultAndTheOpenStores() throws {
        let log = try read("CHANGELOG.md")
        once("Other stores (#294, 2026-11-05, one run per row):", in: log)
        once("Exchange and local calendars were not measured (#294).", in: log)
    }
}
