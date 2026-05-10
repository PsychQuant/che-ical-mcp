import XCTest
@testable import CheICalMCP

/// Source-string contract tests for list/search envelope shape (#107).
///
/// Background: #107 unified 5 list/search envelopes to top-level `<entity>_count`
/// with pre-limit semantic. Snapshot tests via handler instances would require
/// EventKitManager test seam refactor (per CLAUDE.md only `reminderCleanupSource`
/// is narrow-protocol injected, per #31). To avoid scope creep into broader test
/// seam work, this file uses source-string contracts — read `Server.swift` and
/// regex-assert envelope shape invariants.
///
/// **Brittle on syntax changes**, but catches wire-format drift directly:
/// - If maintainer accidentally puts `event_count` in `metadata` instead of
///   top level, these tests RED.
/// - If maintainer removes `search_reminders.limit` parameter, these tests RED.
/// - Symbol rename (e.g. `event_count` → `eventCount`) requires test update.
///
/// Test seam upgrade (extracting list/search handler narrow protocols) is
/// tracked as a future hardening concern, not blocking #107.
final class EnvelopeShapeTests: XCTestCase {

    // MARK: - Helpers

    /// Load Server.swift source for regex inspection.
    /// Falls back gracefully if path resolution differs in test environment.
    private func loadServerSource() throws -> String {
        // Resolve repo root via #file (Tests/CheICalMCPTests/EnvelopeShapeTests.swift)
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()  // CheICalMCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let serverPath = repoRoot.appendingPathComponent("Sources/CheICalMCP/Server.swift")
        return try String(contentsOf: serverPath, encoding: .utf8)
    }

    /// Find handler body (from `private func <name>(`/`func <name>(` to next
    /// `private func ` or `func ` at column 4 — i.e. method boundary).
    private func handlerBody(_ source: String, handlerName: String) -> String? {
        let pattern = #"(?:private func|func)\s+\#(handlerName)\([^{]*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let firstMatch = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else {
            return nil
        }
        let startIdx = source.index(source.startIndex, offsetBy: firstMatch.range.location)

        // Find next handler boundary (`    private func ` or `    func ` at line start with 4-space indent)
        let nextHandlerPattern = #"\n    (?:private func|func) [a-zA-Z]"#
        guard let nextRegex = try? NSRegularExpression(pattern: nextHandlerPattern) else {
            return String(source[startIdx...])
        }
        let restOfSource = String(source[startIdx...])
        if let nextMatch = nextRegex.firstMatch(in: restOfSource, range: NSRange(restOfSource.startIndex..., in: restOfSource)) {
            let endIdx = restOfSource.index(restOfSource.startIndex, offsetBy: nextMatch.range.location)
            return String(restOfSource[restOfSource.startIndex..<endIdx])
        }
        return restOfSource
    }

    // MARK: - Envelope shape contracts (#107)

    func testListEventsEnvelopeShape() throws {
        let source = try loadServerSource()
        guard let body = handlerBody(source, handlerName: "handleListEvents") else {
            XCTFail("Could not locate handleListEvents in Server.swift")
            return
        }

        // Top-level event_count present
        XCTAssertTrue(body.contains("\"event_count\":"),
            "handleListEvents response should include top-level event_count (#107)")
        // metadata.returned removed
        XCTAssertFalse(body.contains("\"returned\":"),
            "handleListEvents metadata.returned should be removed (#107 A1)")
    }

    func testListRemindersEnvelopeShape() throws {
        let source = try loadServerSource()
        guard let body = handlerBody(source, handlerName: "handleListReminders") else {
            XCTFail("Could not locate handleListReminders in Server.swift")
            return
        }

        XCTAssertTrue(body.contains("\"reminder_count\":"),
            "handleListReminders response should include top-level reminder_count (#107)")
        XCTAssertFalse(body.contains("\"returned\":"),
            "handleListReminders metadata.returned should be removed (#107 A1)")
    }

    func testSearchEventsEnvelopeShape() throws {
        let source = try loadServerSource()
        guard let body = handlerBody(source, handlerName: "handleSearchEvents") else {
            XCTFail("Could not locate handleSearchEvents in Server.swift")
            return
        }

        // Existing pattern: top-level event_count = totalCount (pre-#107, preserved)
        XCTAssertTrue(body.contains("\"event_count\":"),
            "handleSearchEvents response should include top-level event_count (preserved post-#107)")
    }

    func testSearchRemindersEnvelopeShape() throws {
        let source = try loadServerSource()
        guard let body = handlerBody(source, handlerName: "handleSearchReminders") else {
            XCTFail("Could not locate handleSearchReminders in Server.swift")
            return
        }

        // #107 B1: top-level reminder_count = totalCount (pre-limit)
        XCTAssertTrue(body.contains("\"reminder_count\":"),
            "handleSearchReminders response should include top-level reminder_count (#107)")
        XCTAssertTrue(body.contains("totalCount"),
            "handleSearchReminders should capture pre-limit total via totalCount (#107 B1)")
        // #107 B1: limit param added
        XCTAssertTrue(body.contains("requireOptionalLimit"),
            "handleSearchReminders should call requireOptionalLimit for new limit parameter (#107 B1)")
        // #107 B1: prefix truncation present
        XCTAssertTrue(body.contains("reminders.prefix(limit)"),
            "handleSearchReminders should truncate via prefix(limit) (#107 B1)")
        // #107 B1: limit echo when present
        XCTAssertTrue(body.contains("response[\"limit\"] = limit"),
            "handleSearchReminders should echo limit when caller specified (#107 B1)")
    }

    func testListEventsQuickEnvelopeShape() throws {
        let source = try loadServerSource()
        guard let body = handlerBody(source, handlerName: "handleListEventsQuick") else {
            XCTFail("Could not locate handleListEventsQuick in Server.swift")
            return
        }

        // Existing pattern: top-level event_count = totalCount (pre-#107, preserved)
        XCTAssertTrue(body.contains("\"event_count\":"),
            "handleListEventsQuick response should include top-level event_count (preserved post-#107)")
    }

    // MARK: - Tool schema contract (#107 B1)

    func testSearchRemindersSchemaHasLimitParameter() throws {
        let source = try loadServerSource()

        // Find search_reminders Tool block
        let searchRemindersStart = source.range(of: "name: \"search_reminders\"")
        XCTAssertNotNil(searchRemindersStart, "Could not locate search_reminders tool registration")
        guard let startRange = searchRemindersStart else { return }

        // Extract roughly 2500 chars after start (covers the whole Tool block;
        // search_reminders block is ~2200 chars per current source).
        let endIndex = source.index(startRange.lowerBound, offsetBy: 2500, limitedBy: source.endIndex) ?? source.endIndex
        let searchRemindersBlock = String(source[startRange.lowerBound..<endIndex])

        // Limit parameter should be declared
        XCTAssertTrue(searchRemindersBlock.contains("\"limit\":"),
            "search_reminders schema should declare limit parameter (#107 B1)")
        XCTAssertTrue(searchRemindersBlock.contains("Maximum number of reminders to return"),
            "search_reminders limit parameter should have descriptive text (#107 B1)")
    }
}
