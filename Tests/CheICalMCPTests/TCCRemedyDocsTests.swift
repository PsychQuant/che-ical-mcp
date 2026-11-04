import XCTest

/// Round-2 verify (#357): the shipped TCC docs agree with the remedy policy. Scans the six
/// human-facing doc files for a remove/add button in the Calendar / Reminders panes (none
/// exists, observed on one Mac, macOS 27), a bundle-id `tccutil reset`, and a bare
/// `tccutil reset` line without its every-app consequence.
final class TCCRemedyDocsTests: XCTestCase {

    private static let docs = [
        "README.md", "README_zh-TW.md", "mcpb/README.md",
        "plugin/skills/troubleshoot-tcc/SKILL.md", "plugin/commands/check-tcc.md", "plugin/CLAUDE.md",
    ]

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    func testDocs_noButtonNoBundleIDReset_everyBareResetNamesEveryApp() throws {
        let root = try repoRoot()
        for doc in Self.docs {
            let text = try String(contentsOf: root.appendingPathComponent(doc), encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let at = "\(doc):\(n + 1): \(line)"
                XCTAssertFalse(line.contains("−"), "remove button: \(at)")
                XCTAssertFalse(line.contains("**+**") || line.contains("click +") || line.contains("click `+`")
                               || line.contains("點 +") || line.contains("按 +"), "add button: \(at)")
                XCTAssertFalse(line.contains("remove CheICalMCP") || line.contains("remove it with"), at)
                guard line.contains("tccutil reset") else { continue }
                XCTAssertFalse(line.contains("tccutil reset Calendar com.checheng") && !line.contains("not work")
                               && !line.contains("Do not") && !line.contains("Never") && !line.contains("fails"),
                               "a bundle-id reset offered as a step: \(at)")
                let bare = line.range(of: #"tccutil reset (Calendar|Reminders)`"#, options: .regularExpression) != nil
                if bare {
                    XCTAssertTrue(line.contains("every app") || line.contains("所有 app"),
                                  "a bare reset without its every-app consequence: \(at)")
                }
            }
        }
    }
}
