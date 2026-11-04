import XCTest

/// #357 (verify rounds 2–3): the six shipped TCC docs agree with the remedy text.
///
/// Every line that mentions `tccutil reset` is one of exactly two kinds (closed list):
/// 1. a warning against it (`does not work`, `Do not`, `Never`, `fails`), or
/// 2. the human-run last resort — a bare reset (no bundle id) on one line with its consequence
///    (every app), its precondition (v1.11.0+) and who runs it ("an agent must not"); allowed
///    only in README.md, mcpb/README.md and the troubleshoot-tcc skill, never in the
///    agent-facing `/check-tcc` command or plugin/CLAUDE.md.
/// No reset sits in a fenced code block (a copy-paste command without its consequence). No line
/// tells the user to press a remove or add button in the Calendar / Reminders panes, which have
/// none (observed on one Mac, macOS 27); the Full Disk Access steps for sshd are a different
/// pane and are exempt from the add-button check.
final class TCCRemedyDocsTests: XCTestCase {

    static let docs = [
        "README.md", "README_zh-TW.md", "mcpb/README.md",
        "plugin/skills/troubleshoot-tcc/SKILL.md", "plugin/commands/check-tcc.md", "plugin/CLAUDE.md",
    ]
    static let lastResortAllowed: Set<String> = ["README.md", "mcpb/README.md", "plugin/skills/troubleshoot-tcc/SKILL.md"]

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
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            let plain = raw.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            if raw.contains("−") { out.append("remove button (−): \(at)") }
            if plain.range(of: #"(?i)(^|\s)[-−]\s?button"#, options: .regularExpression) != nil {
                out.append("remove button (- button): \(at)")
            }
            if plain.range(of: #"(?i)remove (CheICalMCP|it) with"#, options: .regularExpression) != nil {
                out.append("remove instruction: \(at)")
            }
            let addButton = raw.contains("**+**") || plain.contains("click +") || plain.contains("Click +")
                || raw.contains("點 +") || raw.contains("按 +") || raw.contains("點 **+**")
            if addButton && !raw.contains("sshd") { out.append("add button: \(at)") }
            guard plain.contains("tccutil reset") else { continue }
            if fenced { out.append("reset in a fenced block: \(at)"); continue }
            let warning = ["not work", "Do not", "do not", "Never", "fails"].contains { plain.contains($0) }
            let lastResort = plain.contains("every app") && plain.contains("v1.11.0") && plain.contains("an agent must not")
            let bundleID = plain.range(of: #"tccutil reset \w+ com\.checheng"#, options: .regularExpression) != nil
            if bundleID && !warning { out.append("bundle-id reset offered: \(at)") }
            if !warning && !lastResort { out.append("reset without warning or the three last-resort parts: \(at)") }
            if lastResort && !lastResortAllowed.contains(doc) { out.append("last resort in an agent-facing doc: \(at)") }
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

    // Round-3 MEDIUM 5: the checks must catch these mutations.
    func testChecks_catchAFencedBareReset() {
        XCTAssertFalse(Self.findings(doc: "README.md", text: "```bash\ntccutil reset Calendar\n```").isEmpty)
    }

    func testChecks_catchARemindersBundleIDReset() {
        XCTAssertFalse(Self.findings(doc: "README.md", text: "Then run `tccutil reset Reminders com.checheng.CheICalMCP`.").isEmpty)
    }

    func testChecks_catchAnASCIIRemoveButton() {
        XCTAssertFalse(Self.findings(doc: "mcpb/README.md", text: "Select CheICalMCP and press the - button.").isEmpty)
    }

    func testChecks_catchALastResortInAnAgentFacingDoc() {
        let line = "Last resort: `tccutil reset Calendar` clears every app; only on v1.11.0+; the user decides and runs it, an agent must not."
        XCTAssertTrue(Self.findings(doc: "README.md", text: line).isEmpty)
        XCTAssertFalse(Self.findings(doc: "plugin/CLAUDE.md", text: line).isEmpty)
    }

    func testChecks_allowTheSshdFullDiskAccessStep() {
        XCTAssertTrue(Self.findings(doc: "README.md", text: "2. Click **+**, press ⌘⇧G, type `/usr/sbin/sshd`, and add it").isEmpty)
    }
}
