import XCTest

/// #514: the conference module copies program text into events. An access code in that text (a `?pwd=`
/// link, a `Passcode:` line) would sync to every device and share, so the standard mode masks a closed
/// list of kinds. The masked text is what the module writes and compares, so a re-paste does not see a
/// masked line as a change. Round 2 dropped the old-code row: an event written before #514 is handled as
/// main handles any line the module does not write (moved below the marker), and the report names it.
/// Round 3 masks titles too and has the recommendation layer mask what it stores and restores.
final class ConferenceAccessCodeDocsTests: XCTestCase {

    static let standard = "plugin/rules/modules/conference.md"
    static let spec = "openspec/changes/add-conference-module/specs/conference-module/spec.md"
    static let layer = "plugin/rules/modules/conference-recommend.md"
    static let changelog = "plugin/CHANGELOG.md"

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

    /// A docs pin must occur exactly once, so a second copy cannot keep the test green after the rule goes.
    private func assertOnce(_ pin: String, in path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let n = try read(path).components(separatedBy: pin).count - 1
        XCTAssertEqual(n, 1, "\(path): expected exactly one \"\(pin)\", found \(n)", file: file, line: line)
    }

    static let skill = "plugin/skills/itinerary-check/SKILL.md"
    static let layerSpec = "openspec/changes/add-conference-recommend-layer/specs/conference-recommend-layer/spec.md"

    func testTheMaskedKindsAreAClosedList() throws {
        try assertOnce("**Access codes in copied program text are masked** (closed list).", in: Self.standard)
        try assertOnce("A **link** is a run of text that begins with `http://` or `https://` and ends before the first character that is not one of RFC 3986's unreserved or reserved characters or `%`", in: Self.standard)
        try assertOnce("next line that begins with `http://` or `https://` gets rule 1 only", in: Self.standard)
        try assertOnce("A **space** here is U+0020, U+3000, a tab or U+00A0", in: Self.standard)
        try assertOnce("a query or fragment parameter named `pwd`, `pw`, `pass`, `passcode` or `password` (in any letter case), and one named `p` only when the host is `teams.microsoft.com` or `teams.live.com`", in: Self.standard)
        try assertOnce("The scheme and the host are matched in any letter case", in: Self.standard)
        try assertOnce("(no letter or digit of any script, and no `_`, directly before or after it)", in: Self.standard)
        try assertOnce("after any leading `>` and spaces (a quoted thread)", in: Self.standard)
        try assertOnce("a sentence with no spaces under a label is masked as one token", in: Self.standard)
        try assertOnce("a password before the host (`https://user:REMOVED@host/…`)", in: Self.standard)
        try assertOnce("A **label** is `passcode` or `password` (in any letter case) as a whole word", in: Self.standard)
        try assertOnce("except a label that directly follows `?`, `&` or `#`", in: Self.standard)
        try assertOnce("when what remains is one token with no spaces", in: Self.standard)
        try assertOnce("is replaced by `REMOVED`", in: Self.standard)
    }

    /// Round 3: titles are masked by rules 1 and 2 (round 1's exemption was wrong: "Password Managers" has
    /// no separator, so it was never a label); the location gets only the link rule.
    func testTitlesAreNeverMasked() throws {
        XCTAssertFalse(try read(Self.standard).contains("Titles are never masked"))
        try assertOnce("In a title, rules 1 and 2 apply", in: Self.standard)
        try assertOnce("is quoted masked, an old event's stored title included", in: Self.standard)
        try assertOnce("in the location, only rule 1 applies", in: Self.standard)
        try assertOnce("#### Scenario: A talk title with a label word", in: Self.spec)
        try assertOnce("#### Scenario: An access code in an item's title", in: Self.spec)
        try assertOnce("`オンライン懇親会（Zoom パスコード：482913）`", in: Self.spec)
        XCTAssertFalse(try read(Self.spec).contains("It SHALL NOT mask a title"))
        try assertOnce("A space SHALL be U+0020, U+3000, a tab or U+00A0, and a line SHALL end at LF, CR or CRLF", in: Self.spec)
    }

    func testMaskedTextIsWhatIsCompared() throws {
        try assertOnce("the module's own output is masked, and the event's title, notes and location are compared as stored", in: Self.standard)
        XCTAssertFalse(try read(Self.standard).contains("is the module's own old copy"))
        try assertOnce("the events in which this run wrote a masked value", in: Self.standard)
    }

    /// Round 2: no old-code row. An old code is moved below the marker as main does, and the report names it.
    func testAnOldCodeIsMovedAndReported() throws {
        let standard = try read(Self.standard)
        XCTAssertFalse(standard.contains("mask the old code in <event>?"))
        XCTAssertFalse(standard.contains("old-code row"))
        try assertOnce("Masking applies only to what the module writes now", in: Self.standard)
        try assertOnce("an access code was kept in <event> as your text; remove it by hand if it should not be there", in: Self.standard)
        XCTAssertFalse(try read(Self.standard).contains("from before #514 was kept"))
        try assertOnce("or a line above the marker holds a value of section 4's closed list that the module does not write as it stands", in: Self.standard)
        try assertOnce("Old codes, above and below the marker, are not masked by v1", in: Self.spec)
        try assertOnce("old codes, above and below the marker, are not masked", in: Self.changelog)
    }

    func testTheSpecCarriesTheRuleAndItsScenarios() throws {
        try assertOnce("### Requirement: Access codes in copied program text are masked", in: Self.spec)
        try assertOnce("#### Scenario: A meeting link with a passcode in the program", in: Self.spec)
        try assertOnce("#### Scenario: A passcode line in the program", in: Self.spec)
        try assertOnce("#### Scenario: Re-pasting a masked program changes nothing", in: Self.spec)
        try assertOnce("#### Scenario: An event written before masking", in: Self.spec)
        try assertOnce("#### Scenario: A code line the user edited", in: Self.spec)
        XCTAssertFalse(try read(Self.spec).contains("#### Scenario: An old event whose meeting link changed"))
        try assertOnce("#### Scenario: A passcode in full-width brackets after a link", in: Self.spec)
        try assertOnce("`https://zoom.us/j/12345678901（パスコード：987654）`", in: Self.spec)
        try assertOnce("#### Scenario: A passcode after a link and an ideographic space", in: Self.spec)
    }

    func testTheLayerPointsToTheMask() throws {
        let layer = try read(Self.layer)
        XCTAssertFalse(layer.contains("so a code the program text itself carries is not removed by the layer"))
        try assertOnce("where the program had a code of that closed list", in: Self.layer)
        try assertOnce("A difference that comes only from masking is not a program change", in: Self.layer)
        XCTAssertFalse(try read(Self.layer).contains("old-code row"))
        try assertOnce("in the same `update_event` that keeps the block", in: Self.layer)
        try assertOnce("*Keep*, and nobody to answer, write nothing for it", in: Self.layer)
        try assertOnce("with rule 1 applied to the stored location and the closed list of `conference.md` section 4 to the stored title", in: Self.layer)
        try assertOnce("The block's item and location lines are stored standard values, masked by the same rule", in: Self.layer)
        XCTAssertFalse(try read(Self.layer).contains("comes back on a restore (a known limit)"))
        try assertOnce("a difference that comes only from masking SHALL NOT raise the recommendation question", in: Self.layerSpec)
        try assertOnce("with the link rule applied to the stored location and the closed list to the stored title", in: Self.layerSpec)
        try assertOnce("**Conference module: access codes in copied program text are masked** (#514)", in: Self.changelog)
    }

    /// Round 1 MEDIUM: itinerary-check compares a program in masked form and never copies a code.
    func testItineraryCheckComparesInMaskedForm() throws {
        try assertOnce("both the program's text and the events' titles, notes and locations are masked by the closed list of `conference.md` section 4 (a location by its rule 1 only) before they are compared or quoted", in: Self.skill)
        try assertOnce("an access code will be moved below the marker / masked in <event>", in: Self.skill)
        try assertOnce("from an event's title, notes or location", in: Self.skill)
        try assertOnce("a meeting passcode or password", in: Self.skill)
    }
}
