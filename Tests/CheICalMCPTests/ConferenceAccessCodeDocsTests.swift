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

    func testTheMaskedKindsAreAClosedList() throws {
        try assertOnce("**Access codes in copied program text are masked** (closed list).", in: Self.standard)
        try assertOnce("a query parameter named `pwd`, `pw`, `pass`, `passcode`, `password` or `p` (in any letter case)", in: Self.standard)
        try assertOnce("a password before the host (`https://user:REMOVED@host/…`)", in: Self.standard)
        try assertOnce("one of the labels `passcode` or `password` (in any letter case), `パスコード`, `パスワード`, `密碼` or `密码`", in: Self.standard)
        try assertOnce("the next line, when it is one token with no spaces", in: Self.standard)
        try assertOnce("is replaced by `REMOVED`", in: Self.standard)
    }

    func testMaskedTextIsWhatIsCompared() throws {
        try assertOnce("every comparison of the program's text with an event's notes uses the masked text", in: Self.standard)
        try assertOnce("is the module's own old copy", in: Self.standard)
    }

    func testTheSpecCarriesTheRuleAndItsScenarios() throws {
        try assertOnce("### Requirement: Access codes in copied program text are masked", in: Self.spec)
        try assertOnce("#### Scenario: A meeting link with a passcode in the program", in: Self.spec)
        try assertOnce("#### Scenario: A passcode line in the program", in: Self.spec)
        try assertOnce("#### Scenario: Re-pasting a masked program changes nothing", in: Self.spec)
        try assertOnce("#### Scenario: An event written before masking", in: Self.spec)
    }

    func testTheLayerPointsToTheMask() throws {
        let layer = try read(Self.layer)
        XCTAssertFalse(layer.contains("so a code the program text itself carries is not removed by the layer"))
        try assertOnce("the standard mode masks the access codes of `conference.md` section 4 in the text it copies", in: Self.layer)
        try assertOnce("**Conference module: access codes in copied program text are masked** (#514)", in: Self.changelog)
    }
}
