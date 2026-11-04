import XCTest

/// #357 (verify rounds 2–4): the six shipped TCC docs agree with the remedy text.
///
/// Round 4 (R3) rules, closed list:
/// 1. A line with `tccutil reset` and `com.checheng` fails unless it is, exactly, one of the
///    warning lines in `bundleIDWarningLines` (no keyword exemption: "if --setup does not work,
///    run `tccutil reset Calendar com.checheng.CheICalMCP`" contains "not work" and is a step).
/// 2. A `tccutil reset` without a bundle id fails in every agent-facing doc (the troubleshoot-tcc
///    skill, `/check-tcc`, plugin/CLAUDE.md). In the three human docs it is allowed only with all
///    three conditions on the same line: every app, v1.11.0+, the user decides and runs it.
/// 3. No reset in a fenced code block.
/// 4. No remove or add button in the Calendar / Reminders panes, which have none (observed on
///    one Mac, macOS 27); the sshd Full Disk Access steps are a different pane and exempt.
final class TCCRemedyDocsTests: XCTestCase {

    static let docs = [
        "README.md", "README_zh-TW.md", "mcpb/README.md",
        "plugin/skills/troubleshoot-tcc/SKILL.md", "plugin/commands/check-tcc.md", "plugin/CLAUDE.md",
    ]
    static let humanDocs: Set<String> = ["README.md", "README_zh-TW.md", "mcpb/README.md"]

    /// The only lines allowed to name the bundle-id reset: warnings against it.
    static let bundleIDWarningLines: Set<String> = [
        "> ⚠️ **Erratum for the #108-era workaround**: `tccutil reset Calendar com.checheng.CheICalMCP` (or `Reminders`) does **not** work for a bare (non-bundled) binary — it fails with `OSStatus error -10814` (`kLSApplicationNotFoundErr`) because the binary has no LaunchServices registration.",
        "> Never `tccutil reset <service> com.checheng.CheICalMCP`: it fails with `OSStatus error -10814` for this bare binary, which has no LaunchServices registration (#357).",
        "> **Never `tccutil reset <service> com.checheng.CheICalMCP`: it fails with `OSStatus error -10814` for this bare binary, which has no LaunchServices registration** (#357).",
        "- Never offer `tccutil reset <service> com.checheng.CheICalMCP`: it fails with `OSStatus error -10814` for this bare binary (no LaunchServices registration; README erratum, #357).",
    ]

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    /// The findings for one document's text; empty means it passes. Pure, so the mutation
    /// tests below can feed it lines the real docs do not contain.
    static func findings(doc: String, text: String) -> [String] {
        var out: [String] = []
        var fenced = false
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            let at = "\(doc):\(n + 1): \(raw)"
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); continue }
            let plain = raw.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            if raw.contains("−") { out.append("remove button (−): \(at)") }
            if plain.range(of: #"(?i)(^|\s)[-−]\s?button"#, options: .regularExpression) != nil {
                out.append("remove button (- button): \(at)")
            }
            if plain.range(of: #"(?i)remove (CheICalMCP|it) with"#, options: .regularExpression) != nil {
                out.append("remove instruction: \(at)")
            }
            let addButton = raw.contains("**+**") || plain.contains("click +") || plain.contains("Click +")
                || raw.contains("點 +") || raw.contains("按 +")
            if addButton && !raw.contains("sshd") { out.append("add button: \(at)") }
            guard plain.contains("tccutil reset") else { continue }
            if fenced { out.append("reset in a fenced block: \(at)"); continue }
            if plain.contains("com.checheng") {
                if !bundleIDWarningLines.contains(line) { out.append("bundle-id reset outside the warning allowlist: \(at)") }
                continue
            }
            guard humanDocs.contains(doc) else { out.append("reset in an agent-facing doc: \(at)"); continue }
            let lower = plain.lowercased()
            let allThree = (lower.contains("every app") || plain.contains("所有 app"))
                && plain.contains("v1.11.0")
                && (lower.contains("the user decides and runs it") || plain.contains("由使用者決定並自己執行"))
            if !allThree { out.append("bare reset without consequence, v1.11.0+ and who runs it: \(at)") }
        }
        return out
    }

    func testShippedDocs_passTheRemedyChecks() throws {
        let root = try repoRoot()
        for doc in Self.docs {
            let text = try String(contentsOf: root.appendingPathComponent(doc), encoding: .utf8)
            for finding in Self.findings(doc: doc, text: text) { XCTFail(finding) }
        }
    }

    // Round-3 MEDIUM 5 and round-4 R3: the checks must catch these mutations.
    func testChecks_catchAFencedBareReset() {
        XCTAssertFalse(Self.findings(doc: "README.md", text: "```bash\ntccutil reset Calendar\n```").isEmpty)
    }

    func testChecks_catchARemindersBundleIDReset() {
        XCTAssertFalse(Self.findings(doc: "README.md", text: "Then run `tccutil reset Reminders com.checheng.CheICalMCP`.").isEmpty)
    }

    func testChecks_catchABundleIDResetDressedAsAWarning() {
        let line = "If --setup does not work, run `tccutil reset Calendar com.checheng.CheICalMCP`"
        for doc in Self.docs { XCTAssertFalse(Self.findings(doc: doc, text: line).isEmpty, doc) }
    }

    func testChecks_catchABareResetInTheSkill() {
        let line = "Last resort: `tccutil reset Calendar` clears every app; only on v1.11.0+; the user decides and runs it."
        XCTAssertFalse(Self.findings(doc: "plugin/skills/troubleshoot-tcc/SKILL.md", text: line).isEmpty)
        XCTAssertFalse(Self.findings(doc: "plugin/commands/check-tcc.md", text: line).isEmpty)
        XCTAssertFalse(Self.findings(doc: "plugin/CLAUDE.md", text: line).isEmpty)
        XCTAssertTrue(Self.findings(doc: "README.md", text: line).isEmpty, "allowed in a human doc with all three")
        XCTAssertFalse(Self.findings(doc: "README.md", text: "Last resort: `tccutil reset Calendar` clears every app.").isEmpty)
    }

    func testChecks_catchAnASCIIRemoveButton() {
        XCTAssertFalse(Self.findings(doc: "mcpb/README.md", text: "Select CheICalMCP and press the - button.").isEmpty)
    }

    func testChecks_allowTheExactWarningLines_andTheSshdStep() {
        for line in Self.bundleIDWarningLines { XCTAssertTrue(Self.findings(doc: "README.md", text: line).isEmpty, line) }
        XCTAssertTrue(Self.findings(doc: "README.md", text: "2. Click **+**, press ⌘⇧G, type `/usr/sbin/sshd`, and add it").isEmpty)
    }
}
