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
    static let conferenceSpec = "openspec/changes/add-conference-module/specs/conference-module/spec.md"

    /// The one exception to "Whose text is whose" (conference.md section 6): moving the layer's lines
    /// below the marker would make them the user's text, and they would come back on every paste.
    static let dropException = "the recommendation layer's block lines and marks are dropped, not moved below the marker pair"

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

    /// Number of times `pin` occurs in `text`. A docs pin must occur exactly once, so a second copy
    /// elsewhere in the document cannot keep the test green after the pinned rule is removed.
    static func count(_ pin: String, in text: String) -> Int {
        text.components(separatedBy: pin).count - 1
    }

    private func assertOnce(_ pin: String, in path: String, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let n = Self.count(pin, in: try read(path))
        XCTAssertEqual(n, 1, "\(path): expected exactly one \"\(pin)\", found \(n). \(message)", file: file, line: line)
    }

    /// The whole fenced template, so a deleted or reordered line fails even though the single
    /// `conference-recommend: begin` / `end` strings also occur in the prose (verify round 2, INFO).
    static let blockTemplate = """
        ```
        conference-recommend: begin
        Recommended: <room> #<number> <title>, <start> — <reason>
        Alternate: <room> #<number> <title>, <start>
        Online: <meeting link>
        conference-recommend-item: <standard title> | <YYYY-MM-DDTHH:MM> <zone>
        conference-recommend-location: <standard location>
        conference-recommend-marks: <line numbers, comma-separated, or none>
        conference-recommend: end
        ```
        """

    func testBlockLinesAppearInOrderInContractAndSpec() throws {
        try assertOnce(Self.blockTemplate, in: Self.layer, "section 3 block lost or reordered")
        // One unique stretch of the spec's block sentence, so a lost line cannot hide behind another
        // mention of the same prefix elsewhere in the spec.
        try assertOnce("`conference-recommend-item: <standard title> | <YYYY-MM-DDTHH:MM> <zone>` (the layer's item identifier: the start in the conference's zone and that zone, read as the text after the last ` | `); `conference-recommend-location: <standard location>`; `conference-recommend-marks: <line numbers or none>`; `conference-recommend: end`.", in: Self.spec)
        try assertOnce("A decorated event's notes SHALL start with one block of whole lines: `conference-recommend: begin`;", in: Self.spec)
    }

    func testModeIsAClosedThreeStepOrder() throws {
        let one = Self.section(try read(Self.layer), 1)
        let rules = one.components(separatedBy: "\n").filter { $0.range(of: #"^[0-9]+\. \*\*"#, options: .regularExpression) != nil }
        guard rules.count == 3 else { return XCTFail("mode rules changed: \(rules)") }
        XCTAssertTrue(rules[1].contains("`conference_mode`"))
        XCTAssertTrue(rules[2].contains("`standard`"))
        let rows = one.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }
        XCTAssertEqual(rows.map { String($0.prefix(24)) }, ["| `standard` | not used |", "| `recommend` | given | i", "| `recommend` | none | st"].map { String($0.prefix(24)) })
        try assertOnce("asks once: remove the recommendations, or keep them?", in: Self.layer,
                       "a run must not remove recommendations the message did not ask to remove")
    }

    func testPicksNotAppliedIsAClosedList() throws {
        let two = Self.section(try read(Self.layer), 2)
        guard let start = two.range(of: "**A pick is not applied, and the report says why** (closed list):"),
              let end = two.range(of: "\n\n**Never written**", range: start.upperBound..<two.endIndex) else {
            return XCTFail("not-applied list not found")
        }
        let bullets = two[start.upperBound..<end.lowerBound].components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 8, "not-applied cases changed: \(bullets)")
        XCTAssertTrue(bullets.contains { $0.contains("`（未報名）`") })
        // The shared rule "Whose event it is": an event with two modules' markers belongs to neither,
        // so the layer does not decorate it either.
        XCTAssertTrue(bullets.contains { $0.contains("the event also carries a `lodging-module:` marker line") })
        let spec = try read(Self.spec)
        XCTAssertEqual(spec.components(separatedBy: "the event also carries a `lodging-module:` marker line").count - 1, 1,
                       "the spec's closed list names the two-module event once")
        XCTAssertEqual(spec.components(separatedBy: "#### Scenario: A pick for a slot whose event also carries a lodging marker").count - 1, 1)
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

    // MARK: - #346 verify round 1

    /// HIGH 1 / MEDIUM 5: a link can carry the passcode (`?pwd=`), so "never written" must cover links.
    func testMeetingLinksNeverCarryACode() throws {
        let two = Self.section(try read(Self.layer), 2)
        XCTAssertTrue(two.contains("**A meeting link is written only in one of these forms** (closed list):"))
        XCTAssertTrue(two.contains("`https://<host>/j/<digits>`"), "the Zoom form must drop the query (pwd)")
        XCTAssertTrue(two.contains("Any other link is **left out**"))
        let spec = try read(Self.spec)
        XCTAssertTrue(spec.contains("#### Scenario: A link with an embedded passcode"))
        XCTAssertTrue(spec.contains("`pwd=` appears nowhere"))
    }

    /// MEDIUM 2 / LOW 9: stored values round-trip, and the start is read after the last separator.
    func testStoredValuesAreEncodedReversibly() throws {
        let three = Self.section(try read(Self.layer), 3)
        XCTAssertTrue(three.contains("a backslash as `\\\\`, a line feed as `\\n` and a carriage return as `\\r`"),
                      "the encoding of the stored title and location must be reversible")
        XCTAssertTrue(three.contains("the text after the **last** ` | `"))
        XCTAssertTrue(try read(Self.spec).contains("#### Scenario: A location on two lines survives a restore"))
    }

    /// MEDIUM 3 / LOW 13: a block that is not well-formed is dropped, never moved below the marker.
    func testMalformedBlockIsDroppedNotMoved() throws {
        // Verify round 2, MEDIUM 4: the same exception, worded the same, in all four documents.
        for path in [Self.standard, Self.conferenceSpec, Self.layer, Self.spec] {
            try assertOnce(Self.dropException, in: path, "the drop exception must read the same in every document")
        }
        let three = Self.section(try read(Self.layer), 3)
        XCTAssertTrue(three.contains("Lines below the marker pair are the user's and are never parsed as block lines."))
    }

    /// MEDIUM 4: program text cannot plant a block. The shared escape list owns the prefix.
    func testCopiedTextCannotFormABlock() throws {
        let index = try read(Self.index)
        // The prefix list is main's (#365); `conference-` covers the layer's block lines.
        XCTAssertTrue(index.contains("and only these: `conference-` (marker lines and block lines), `lodging-module`."),
                      "the shared copy escape must cover every conference- line")
        let three = Self.section(try read(Self.layer), 3)
        let wellFormed = three.components(separatedBy: "\n").filter { $0.range(of: #"^[0-9]+\. "#, options: .regularExpression) != nil }
        XCTAssertEqual(wellFormed.count, 6, "well-formed criteria changed: \(wellFormed)")
        XCTAssertTrue(wellFormed.contains { $0.contains("it starts on the first line of the notes") })
    }

    /// MEDIUM 6: the server skips only an equal title, so the client compares the standard form first.
    func testClientSideSkipBeforeEveryCreate() throws {
        let six = Self.section(try read(Self.standard), 6)
        XCTAssertTrue(six.contains("**Before every `create_event` of a session**"))
        XCTAssertTrue(six.contains("so it never skips a decorated event (#346, measured 2026-11-09)"))
    }

    /// LOW 7, 8, 10, 11, 12, 14.
    func testSmallerRulesOfRoundOne() throws {
        let layer = try read(Self.layer)
        let one = Self.section(layer, 1)
        XCTAssertTrue(one.contains("A request that names slots is a `recommend` run with `none` for those slots"))
        // Round 3 narrowed v1: a title or start change always has a row, so only the exact-match fields remain here,
        // and a message without a program is no longer a recommendation run (the 60/365-day search is gone).
        try assertOnce("an exact match whose end, location, notes or registration the standard flow would change", in: Self.layer)
        XCTAssertFalse(one.contains("from 60 days before to 365 days after the date the message names"))
        XCTAssertTrue(one.contains("**On a first paste with picks**, the standard flow creates and reads back first"))
        let index = try read(Self.index)
        XCTAssertTrue(index.contains("no trigger, switch or calendar of its own"), "the index row must say the layer is not a module")
    }

    // MARK: - #346 verify round 2

    /// MEDIUM 1: a line the user typed inside the block is never deleted. A block with any other line
    /// between begin and end is not well-formed, and the drop removes only the block's own line kinds.
    func testAUserLineInsideTheBlockIsNeverDeleted() throws {
        try assertOnce("no other line lies between `conference-recommend: begin` and `conference-recommend: end`", in: Self.layer)
        try assertOnce("**Block lines** (closed list):", in: Self.layer)
        try assertOnce("Every other line in that range is the user's text", in: Self.layer,
                       "a drop must move the user's lines below the marker, not delete them")
        try assertOnce("#### Scenario: A line the user typed inside the block", in: Self.spec)
    }

    /// MEDIUM 2: a decorated event moved by hand pairs with its item through its item line, so it goes to
    /// the mapping table instead of the item being offered as "not in the set".
    func testAMalformedBlockIsComparedByOneRule() throws {
        try assertOnce("its **comparison title**", in: Self.standard, "the comparison title must be defined once, in conference.md")
        try assertOnce("is never an exact match (Match rule 1)", in: Self.standard,
                       "a malformed decorated event must never be rewritten silently")
        try assertOnce("only for an event that carries this module's marker pair", in: Self.standard,
                       "a planted item line in a hand-built event must not count")
        try assertOnce("by its comparison title (`conference.md`, opening paragraph)", in: Self.layer)
        try assertOnce("#### Scenario: A decorated event moved by hand", in: Self.spec)
        XCTAssertFalse(try read(Self.layer).contains("For the client-side skip, such an event is compared by the title in its item line"),
                       "the second, layer-only rule for the client-side skip is back")
    }

    /// MEDIUM 3 (the client-side skip of another kind): only a timed event holds a session's slot.
    func testTheClientSideSkipNeedsATimedEvent() throws {
        let six = Self.section(try read(Self.standard), 6)
        XCTAssertEqual(Self.count("a timed event whose comparison title equals the item's title", in: six), 1)
        try assertOnce("#### Scenario: A same-named all-day event does not block a session", in: Self.spec)
    }

    /// MEDIUM 5: no run removes a recommendation that its message did not ask to remove without asking.
    func testRemovalIsAClosedListOfAskedWays() throws {
        let one = Self.section(try read(Self.layer), 1)
        guard let start = one.range(of: "**A recommendation is removed only in these ways** (closed list):"),
              let end = one.range(of: "\n\nIn no other case is a decorated event written without its block.", range: start.upperBound..<one.endIndex) else {
            return XCTFail("removal list not found")
        }
        let bullets = one[start.upperBound..<end.lowerBound].components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 3, "removal ways changed: \(bullets)")
        try assertOnce("**The recommendation question.**", in: Self.layer)
        try assertOnce("the mode is `standard` by rule 2 or rule 3", in: Self.layer,
                       "a config of standard must ask too, not only the default")
        XCTAssertFalse(try read(Self.layer).contains("**A mode that is standard only by rule 3**"))
        let spec = try read(Self.spec)
        XCTAssertFalse(spec.contains("standard` only by the last rule"))
        try assertOnce("#### Scenario: A one-off recommendation under `conference_mode: standard`", in: Self.spec)
        try assertOnce("#### Scenario: Nobody answers the recommendation question", in: Self.spec)
        try assertOnce("**Every row that names a decorated event says that its recommendation goes on a yes**", in: Self.layer,
                       "a plain yes to the table must never remove a recommendation the user was not told about")
        try assertOnce("Every row that names a decorated event SHALL say that its recommendation goes on a yes", in: Self.spec)
    }

    /// LOW: conference.md line 7's list of what is parsed from notes includes the layer's block.
    func testNotesParseListIncludesTheBlock() throws {
        try assertOnce("only the two marker lines (section 6) and the recommendation layer's block lines (`conference-recommend.md` section 3) are parsed",
                       in: Self.standard)
    }

    /// LOW: the scenario's item line carries the zone that well-formed criterion 5 needs.
    func testSpecScenarioItemLineHasAZone() throws {
        let spec = try read(Self.spec)
        XCTAssertFalse(spec.contains("`conference-recommend-item: ES2026 午前1：… | 2026-11-10T10:30`"))
        try assertOnce("`conference-recommend-item: ES2026 午前1：… | 2026-11-10T10:30 Asia/Tokyo`", in: Self.spec)
    }

    // MARK: - #346 verify round 3 (v1 narrowed)

    /// MEDIUM 6: a message without a program never reaches the module, so it is not a recommendation run.
    func testPicksNeedAProgram() throws {
        try assertOnce("**A message without a program** (only picks, or only a request to remove the recommendations) is not a recommendation run", in: Self.layer)
        XCTAssertFalse(try read(Self.layer).contains("**A run without a program**"))
        try assertOnce("a message with picks or a removal request and no program is not a recommendation run", in: Self.index)
        XCTAssertFalse(try read(Self.index).contains("a run that only gives picks or asks to remove them"))
        try assertOnce("SHALL NOT be a recommendation run", in: Self.spec)
    }

    /// MEDIUM 5: the layer writes only to an event no unanswered question names.
    func testTheLayerWritesOnlyEventsNothingPendingNames() throws {
        try assertOnce("**The events the layer may write** (closed list):", in: Self.layer)
        try assertOnce("the event is not one the layer may write in this run (section 1)", in: Self.layer)
        try assertOnce("#### Scenario: A pick while the slot's row is unanswered", in: Self.spec)
        try assertOnce("#### Scenario: A pick while the rename question is unanswered", in: Self.spec)
    }

    /// MEDIUM 3: remove writes the stored standard form, never a title or start of its own.
    func testRemoveWritesOnlyTheStoredStandardForm() throws {
        try assertOnce("It never changes a title or a start on its own.", in: Self.layer)
        try assertOnce("SHALL NOT change a title or a start on its own", in: Self.spec)
    }

    /// MEDIUM 2: the client-side skip reads every set's module events, so another set's decorated
    /// session holds its slot as the server's skip did before #346.
    func testTheClientSideSkipReadsEverySet() throws {
        let phrase = "every module event the run's search of its calendar read (step 1, every set)"
        try assertOnce(phrase, in: Self.standard)
        try assertOnce(phrase, in: Self.spec)
        XCTAssertFalse(try read(Self.standard).contains("the events already read in this run (the set of step 1 and the hand-built events of step 3)"))
    }

    /// MEDIUM 1: "no keeps" only when the client-side skip will hold the slot.
    func testNoKeepsOnlyWhenTheSlotIsHeld() throws {
        try assertOnce("the row reads \"no keeps <event> in its place\" only when its comparison title equals the item's title and it covers the item's start", in: Self.layer)
        try assertOnce("#### Scenario: A block whose item line was deleted", in: Self.spec)
    }

    /// MEDIUM 4: on a candidate set's set-level yes a decorated session takes the new marker too.
    func testACandidateSetsYesLeavesNoOrphan() throws {
        try assertOnce("so no session is left under the old marker", in: Self.layer)
        try assertOnce("A set-level row, the rename question and the choice among several sets each name the set's decorated sessions and say that their recommendations go on a yes", in: Self.layer)
        try assertOnce("A set-level row, the rename question and the choice among several sets SHALL each name the set's decorated sessions", in: Self.spec)
        try assertOnce("#### Scenario: A candidate set's set-level yes", in: Self.spec)
    }

    /// LOW: a talk's room and number must name exactly one listing line.
    func testATalkMustBeInTheSlot() throws {
        try assertOnce("a talk's room and number do not name exactly one line of the slot's listing", in: Self.layer)
        try assertOnce("#### Scenario: A pick whose number is not in the slot", in: Self.spec)
    }

    func testIndexListsTheLayer() throws {
        XCTAssertTrue(try read(Self.index).contains("[`modules/conference-recommend.md`](modules/conference-recommend.md)"))
    }
}
