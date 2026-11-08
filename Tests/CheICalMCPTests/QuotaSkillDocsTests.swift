import XCTest

/// #327: the quota skill's contract lines that other parts depend on. The reminders a user already has
/// are found again by the marker line and matched by the title template, so a reworded template or
/// marker would make `update` and `sync` miss them and create duplicates. The helper scripts and the
/// spec are pinned to the same strings.
final class QuotaSkillDocsTests: XCTestCase {

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: try repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    static let skill = "plugin/skills/quota/SKILL.md"
    static let spec = "openspec/changes/add-quota-reminders/specs/quota-reminders/spec.md"

    /// The frontmatter between the first two `---` lines.
    static func frontmatter(_ text: String) -> String {
        let parts = text.components(separatedBy: "\n---\n")
        guard text.hasPrefix("---\n"), parts.count > 1 else { return "" }
        return String(parts[0].dropFirst(4))
    }

    func testSkillIsNamedQuota() throws {
        let front = Self.frontmatter(try read(Self.skill))
        XCTAssertTrue(front.contains("\nname: quota\n") || front.hasPrefix("name: quota\n"), "frontmatter must name the skill quota (/che-ical-mcp:quota)")
    }

    func testDeleteIsNotPreApproved() throws {
        // Retire deletes only after a yes in this run; the harness asking once more is the second gate.
        let front = Self.frontmatter(try read(Self.skill))
        XCTAssertFalse(front.contains("delete_reminder"), "delete_reminder must not be in allowed-tools")
        XCTAssertFalse(front.contains("delete_calendar"), "the skill never deletes a list")
        XCTAssertTrue(front.contains("mcp__che-ical-mcp__update_reminder"))
        XCTAssertTrue(front.contains("mcp__che-ical-mcp__create_reminder"))
    }

    func testTemplateMarkerAndFileAgreeBetweenSkillAndSpec() throws {
        let skill = try read(Self.skill)
        let spec = try read(Self.spec)
        for pinned in ["Use up <name> (<account>, <when>)", "quota-module: <id>", "~/.claude/.ical/quotas.yaml",
                       "[<alarm_minutes>, 0]", "`[0]`"] {
            XCTAssertTrue(skill.contains(pinned), "\(Self.skill) lost: \(pinned)")
            XCTAssertTrue(spec.contains(pinned), "\(Self.spec) lost: \(pinned)")
        }
    }

    func testSkillCallsTheHelpers() throws {
        let skill = try read(Self.skill)
        XCTAssertTrue(skill.contains("bash \"${CLAUDE_PLUGIN_ROOT}/bin/find-ical-config.sh\" --quotas"))
        XCTAssertTrue(skill.contains("bash \"${CLAUDE_PLUGIN_ROOT}/bin/quota-dates.sh\""))
        let root = try repoRoot()
        for helper in ["plugin/bin/quota-dates.sh", "plugin/bin/find-ical-config.sh", "plugin/bin/tests/quota-dates.test.sh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(helper).path), "missing \(helper)")
        }
        let finder = try read("plugin/bin/find-ical-config.sh")
        XCTAssertTrue(finder.contains("\"--quotas\""), "find-ical-config.sh lost its --quotas mode")
    }

    func testEveryNotesLabelIsEscapedWhenCopied() throws {
        // A copied value that starts with a label gets "· " in front; the escape list must name every
        // label of the template, or a value could forge a labelled line.
        let skill = try read(Self.skill)
        guard let start = skill.range(of: "```\nTick this reminder"),
              let end = skill.range(of: "quota-module: <id>\n```", range: start.upperBound..<skill.endIndex) else {
            return XCTFail("notes template block not found")
        }
        let block = skill[start.upperBound..<end.lowerBound]
        let labels = block.components(separatedBy: "\n").compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[line.startIndex..<colon]
            return label.allSatisfy({ $0.isLetter }) && !label.isEmpty ? "`\(label):`" : nil
        }
        XCTAssertEqual(labels.count, 10, "template labels changed: \(labels)")
        guard let open = skill.range(of: "one of the labels above ("),
              let close = skill.range(of: ")", range: open.upperBound..<skill.endIndex) else {
            return XCTFail("escape list not found")
        }
        let escapeList = skill[open.upperBound..<close.lowerBound]
        for label in labels {
            XCTAssertTrue(escapeList.contains(label), "escape list misses \(label)")
        }
    }

    func testReadmeListsTheSkill() throws {
        let readme = try read("plugin/README.md")
        XCTAssertTrue(readme.contains("| `quota` |"), "plugin/README.md Skills table must list quota")
    }
}
