import XCTest

/// #514: the conference module copies program text into events. An access code in that text (a `?pwd=`
/// link, a `Passcode:` line) would sync to every device and share, so the standard mode masks a closed
/// list of kinds. The masked text is what the module writes and compares, so a re-paste does not see a
/// masked line as a change, and an old unmasked copy is replaced rather than moved below the marker.
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

    func testTheMaskedKindsAreAClosedList() throws {
        try assertOnce("**Access codes in copied program text are masked** (closed list).", in: Self.standard)
        try assertOnce("A **link** is a run of text that begins with `http://` or `https://` and ends at the next space or line end", in: Self.standard)
        try assertOnce("a query parameter named `pwd`, `pw`, `pass`, `passcode` or `password` (in any letter case), and one named `p` only when the host is `teams.microsoft.com` or `teams.live.com`", in: Self.standard)
        try assertOnce("a password before the host (`https://user:REMOVED@host/…`)", in: Self.standard)
        try assertOnce("A **label** is `passcode` or `password` (in any letter case) as a whole word, or `パスコード`, `パスワード`, `密碼` or `密码`, followed, after any spaces, by `:`, `：` or `=`", in: Self.standard)
        try assertOnce("the next line, when it is one token with no spaces", in: Self.standard)
        try assertOnce("is replaced by `REMOVED`", in: Self.standard)
    }

    /// Round 1: titles are never masked, and the location gets only the link rule.
    func testTitlesAreNeverMasked() throws {
        try assertOnce("Titles are never masked", in: Self.standard)
        try assertOnce("in the location, only rule 1 applies", in: Self.standard)
        try assertOnce("#### Scenario: A talk title with a label word", in: Self.spec)
    }

    func testMaskedTextIsWhatIsCompared() throws {
        try assertOnce("the module's own output is masked, and the event's notes and location are compared as stored", in: Self.standard)
        XCTAssertFalse(try read(Self.standard).contains("is the module's own old copy"))
        try assertOnce("the events in which this run masked a value", in: Self.standard)
    }

    /// Round 1 HIGH and MEDIUMs: an old code above the marker is asked about, never decided silently.
    func testAnOldCodeIsAskedAbout() throws {
        try assertOnce("\"mask the old code in <event>?\"", in: Self.standard)
        try assertOnce("The old-code row needs its own answer", in: Self.standard)
        try assertOnce("a no keeps the line as it is and moves it below the marker", in: Self.standard)
        try assertOnce("that event's notes are not rewritten and the row is pending", in: Self.standard)
        try assertOnce("a code already below the marker is the user's text and is never masked", in: Self.standard)
    }

    func testTheSpecCarriesTheRuleAndItsScenarios() throws {
        try assertOnce("### Requirement: Access codes in copied program text are masked", in: Self.spec)
        try assertOnce("#### Scenario: A meeting link with a passcode in the program", in: Self.spec)
        try assertOnce("#### Scenario: A passcode line in the program", in: Self.spec)
        try assertOnce("#### Scenario: Re-pasting a masked program changes nothing", in: Self.spec)
        try assertOnce("#### Scenario: An event written before masking", in: Self.spec)
        try assertOnce("#### Scenario: A code line the user edited", in: Self.spec)
        try assertOnce("#### Scenario: An old event whose meeting link changed", in: Self.spec)
    }

    func testTheLayerPointsToTheMask() throws {
        let layer = try read(Self.layer)
        XCTAssertFalse(layer.contains("so a code the program text itself carries is not removed by the layer"))
        try assertOnce("where the program had a code of `conference.md` section 4's closed list", in: Self.layer)
        try assertOnce("A difference that comes only from masking is not a program change", in: Self.layer)
        try assertOnce("**Conference module: access codes in copied program text are masked** (#514)", in: Self.changelog)
    }

    /// Round 1 MEDIUM: itinerary-check compares a program in masked form and never copies a code.
    func testItineraryCheckComparesInMaskedForm() throws {
        try assertOnce("masked by the closed list of `conference.md` section 4 before it is compared", in: Self.skill)
        try assertOnce("a meeting passcode or password", in: Self.skill)
    }
}
