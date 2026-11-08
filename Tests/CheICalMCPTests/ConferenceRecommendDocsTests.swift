import XCTest

/// #346: the recommendation layer of the conference module. Decorated events are found again only by
/// the block's lines, and the standard dedup reads them through the standard form, so a reworded block
/// line, a lost hook in conference.md or a widened mode list would make a re-paste duplicate a slot.
/// The device check of 2026-11-09 showed that `create_event`'s own skip does not catch that: it compares
/// the decorated title.
final class ConferenceRecommendDocsTests: XCTestCase {

    static let layer = "plugin/rules/modules/conference-recommend.md"
    static let standard = "plugin/rules/modules/conference.md"
    static let index = "plugin/rules/event-modules.md"
    static let spec = "openspec/changes/add-conference-recommend-layer/specs/conference-recommend-layer/spec.md"

    static let blockLines = [
        "conference-recommend: begin",
        "conference-recommend-item: <standard title> | <YYYY-MM-DDTHH:MM>",
        "conference-recommend-location: <standard location>",
        "conference-recommend-marks: <line numbers",
        "conference-recommend: end",
    ]

    private func read(_ path: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    /// The text of a markdown section, from its `## <n>.` heading to the next `## `.
    static func section(_ text: String, _ number: Int) -> String {
        guard let start = text.range(of: "\n## \(number). ") else { return "" }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\n## ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    func testStandardContractHooksTheStandardForm() throws {
        let text = try read(Self.standard)
        XCTAssertTrue(text.contains("[`conference-recommend.md`](conference-recommend.md)"))
        XCTAssertTrue(text.contains("**Every comparison and write in section 6, and the duplicate search before any `create_event`, uses an event's standard form**"),
                      "conference.md lost the hook that makes section 6 read decorated events in their standard form")
        XCTAssertFalse(text.contains("is not part of this contract; it is tracked in #346"), "the old deferral sentence is back")
    }

    func testBlockLinesAppearInOrderInContractAndSpec() throws {
        let layer = try read(Self.layer)
        let block = Self.section(layer, 3)
        var cursor = block.startIndex
        for line in Self.blockLines {
            guard let hit = block.range(of: line, range: cursor..<block.endIndex) else {
                return XCTFail("section 3 block lost or reordered: \(line)")
            }
            cursor = hit.upperBound
        }
        let spec = try read(Self.spec)
        for line in Self.blockLines {
            XCTAssertTrue(spec.contains(line.components(separatedBy: " <").first!), "spec does not name \(line)")
        }
        XCTAssertTrue(spec.contains("`conference-recommend-item: <standard title> | <YYYY-MM-DDTHH:MM>`"))
    }

    func testModeIsAClosedThreeStepOrder() throws {
        let one = Self.section(try read(Self.layer), 1)
        let rules = one.components(separatedBy: "\n").filter { $0.range(of: #"^[0-9]+\. \*\*"#, options: .regularExpression) != nil }
        XCTAssertEqual(rules.count, 3, "mode rules changed: \(rules)")
        XCTAssertTrue(rules[1].contains("`conference_mode`"))
        XCTAssertTrue(rules[2].contains("`standard`"))
        let rows = one.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }
        XCTAssertEqual(rows.map { String($0.prefix(24)) }, ["| `standard` | not used |", "| `recommend` | given | i", "| `recommend` | none | st"].map { String($0.prefix(24)) })
        XCTAssertTrue(one.contains("asks once: remove the recommendations, or keep them?"),
                      "a default-standard run must not remove recommendations without asking")
    }

    func testPicksNotAppliedIsAClosedList() throws {
        let two = Self.section(try read(Self.layer), 2)
        guard let start = two.range(of: "**A pick is not applied, and the report says why** (closed list):"),
              let end = two.range(of: "\n\n**Never written**", range: start.upperBound..<two.endIndex) else {
            return XCTFail("not-applied list not found")
        }
        let bullets = two[start.upperBound..<end.lowerBound].components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 6, "not-applied cases changed: \(bullets)")
        XCTAssertTrue(bullets.contains { $0.contains("`（未報名）`") })
    }

    func testAccessCodesAreNeverWritten() throws {
        XCTAssertTrue(try read(Self.layer).contains("**Never written**: a meeting passcode, a password, or any other access code"))
        XCTAssertTrue(try read(Self.spec).contains("SHALL NOT write a meeting passcode, a password or any other access code"))
    }

    func testLayerWritesOnlyByUpdate() throws {
        let five = Self.section(try read(Self.layer), 5)
        XCTAssertTrue(five.contains("**One `update_event` per event**"))
        XCTAssertTrue(five.contains("It is never `create_event`, and never `delete_event`."))
        XCTAssertTrue(five.contains("`calendar_name` set to the set's calendar"), "read-backs must stay scoped to the set's calendar")
    }

    func testIndexListsTheLayer() throws {
        XCTAssertTrue(try read(Self.index).contains("[`modules/conference-recommend.md`](modules/conference-recommend.md)"))
    }
}
