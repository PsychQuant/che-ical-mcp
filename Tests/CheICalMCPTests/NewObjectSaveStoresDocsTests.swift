import XCTest

/// #294: the Google results of the #261 probe (2026-11-05) are recorded where #261's limits are:
/// the `NewObjectSave` header and the #261 CHANGELOG entry, with a pointer in [Unreleased].
/// Exchange and local calendars stay open. PR #508 round 1: every added sentence is pinned whole,
/// with its numbers and error codes, and each occurs exactly once in its document (doc-comment line
/// breaks read as spaces), so a pin cannot survive its sentence's removal or a changed fact.
final class NewObjectSaveStoresDocsTests: XCTestCase {
    private func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Doc-comment and Markdown line breaks read as one space.
    private func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: #"\n[ \t]*(///)?[ \t]*"#, with: " ", options: .regularExpression)
    }

    private func once(_ phrase: String, in text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, phrase, file: file, line: line)
    }

    static let headerSentences = [
        "stores other than iCloud, with one measured (#294, 2026-11-05, a standalone probe beside the server).",
        "On a Google-hosted calendar, with the calendar deleted through Google and the probe waiting 305 seconds for the deletion to reach EventKit, a new event and a new recurring event that failed at commit (EKCADErrorDomain 1010) were not written by a later save, one run each.",
        "Removing a failed recurring event with `remove(span: .thisEvent, commit: false)` made the next save fail with EKCADErrorDomain 1001 and lose what it wrote, as on iCloud (one run).",
        "A new store found a normally saved event in 10 of 10 runs; events do not go through this check.",
        "The source refuses a new event calendar (EKErrorDomain 17), and the refused one was not written later; that is not a NewObjectSave path.",
        "The reminder and reminder-list paths cannot run on that source: it refuses a new reminder list (EKErrorDomain 24).",
        "Every failure was local: a refusal by Google's server was not produced.",
        "Exchange and local calendars: not measured (#294).",
        "(Google: in the list of what was not covered, below)",
    ]

    static let changelogSentences = [
        "Other stores (#294, 2026-11-05, a standalone EventKit probe; the server itself was not exercised): on a Google-hosted calendar, with the calendar deleted through Google and a 305-second wait for the deletion to reach EventKit, a new event and a new recurring event that failed at commit (EKCADErrorDomain 1010) were not written by a later save (one run each), and a new store found a normally saved event in 10 of 10 runs (events do not go through this check).",
        "The source refuses a new event calendar (EKErrorDomain 17), and the refused one was not written later; that is not a NewObjectSave path.",
        "The reminder and reminder-list paths cannot run there: the source refuses a new reminder list (EKErrorDomain 24).",
        "Every failure was local; a refusal by Google's server was not produced.",
        "Exchange and local calendars were not measured (#294).",
        "The same happened on a Google-hosted calendar (EKCADErrorDomain 1001, one run, #294).",
        "- **The Google results of the #261 probe are recorded** (#294): see the #261 entry under 1.20.0 and the `NewObjectSave` header. Exchange and local calendars were not measured.",
    ]

    func testTheHeaderRecordsTheGoogleResultAndTheOpenStores() throws {
        let header = flattened(try read("Sources/CheICalMCP/EventKit/NewObjectSave.swift"))
        for sentence in Self.headerSentences { once(sentence, in: header) }
        XCTAssertFalse(header.contains("a new event calendar that failed at commit"), "the calendar was refused by the source, not at commit")
        XCTAssertFalse(header.contains("the failure induced as on iCloud"))
    }

    func testTheChangelogRecordsTheGoogleResultAndTheOpenStores() throws {
        let log = flattened(try read("CHANGELOG.md"))
        for sentence in Self.changelogSentences { once(sentence, in: log) }
        XCTAssertFalse(log.contains("a new event calendar that failed at commit"))
    }
}
