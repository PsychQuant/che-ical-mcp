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
        XCTAssertEqual(labels.count, 11, "template labels changed: \(labels)")
        guard let open = skill.range(of: "one of the labels above ("),
              let close = skill.range(of: ")", range: open.upperBound..<skill.endIndex) else {
            return XCTFail("escape list not found")
        }
        let escapeList = skill[open.upperBound..<close.lowerBound]
        for label in labels {
            XCTAssertTrue(escapeList.contains(label), "escape list misses \(label)")
        }
    }

    /// #327 verify rounds 1-2: periods have a stable identity, the history boundary comes from used periods
    /// only, and past or completed reminders are never rewritten. Each phrase is a rule the planner and the
    /// skill depend on; losing one reopens a HIGH finding.
    func testPeriodModelRules() throws {
        let skill = try read(Self.skill)
        for pinned in [
            "**`key` is the period's identity**: the reset day in the reset zone",
            "Periods are matched by key, never by order.",
            "**The plan comes from the planner, never from reasoning over the list by hand.**",
            "**An open reminder's own period is never used** until it is ticked.",
            "**The history boundary** is the latest used period.",
            "is never moved, never matched to another period, and never offered for deletion.",
            "This holds whether it is period 0 or older.",
            "Period: <key>",
        ] {
            XCTAssertTrue(skill.contains(pinned), "\(Self.skill) lost: \(pinned)")
        }
        let spec = try read(Self.spec)
        XCTAssertTrue(spec.contains("Period: <key>"), "spec lost the Period line")
        XCTAssertTrue(spec.contains("SHALL NOT be moved, matched to another period, or offered for deletion"))
        XCTAssertTrue(spec.contains("SHALL NOT count an open reminder's own period as used"))
    }

    func testListReportsEachCaseOnce() throws {
        let skill = try read(Self.skill)
        for state in ["- `used`: a completed reminder is on it;", "- `not used`: an open reminder is on it (the overdue record);",
                      "- `rolled past`:", "- `no record`: none of these.", "- `open, due <due>`:",
                      "- `open, deadline passed, resets <reset>`:", "- `no reminder`: none of these.",
                      "**mode mismatch**", "**dates changed**", "**rule mode, running**", "**rule mode, stopped**", "**rule mode, missing**"] {
            XCTAssertTrue(skill.contains(state), "list lost the case: \(state)")
        }
        XCTAssertTrue(skill.contains("It is not ticked with a \"not used\" note, because a ticked reminder reads as used."),
                      "the stopped-series trade-off must say why the record is not ticked")
    }

    /// Round 2: the mode is compared before anything else (notify_at can flip it), the local zone is pinned,
    /// sync never creates next to reminders written under other dates, and a cleaned-up or half-retired
    /// period is never recreated unasked.
    func testRoundTwoRules() throws {
        let skill = try read(Self.skill)
        for pinned in [
            "2. **The mode, compared first.**",
            "Any change of field can change the mode, `notify_at` included.",
            "**The local zone is pinned.**",
            "passes `--local-tz \"$local_tz\"`",
            "**While the host is in another zone than `local_tz`**, the skill writes nothing",
            "`sync` never creates anything for this quota until the user says yes.",
            "Listed with an offer to create it, never created unasked",
            "So a deleted period is never created again.",
            "or is another entry's id followed by `-` and more",
            "bash \"${CLAUDE_PLUGIN_ROOT}/bin/quota-plan.sh\"",
        ] {
            XCTAssertTrue(skill.contains(pinned), "\(Self.skill) lost: \(pinned)")
        }
        let root = try repoRoot()
        for file in ["plugin/bin/quota-plan.sh", "plugin/bin/tests/quota-plan.test.sh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), "missing \(file)")
        }
    }

    func testMarkerMustBeTheOnlyQuotaModuleLine() throws {
        let skill = try read(Self.skill)
        XCTAssertTrue(skill.contains("only when its notes have exactly one line that starts with `quota-module:`, and that line is exactly `quota-module: <id>`"))
        XCTAssertTrue(skill.contains("- **Any other count:** listed and never written."))
    }

    func testHelperArgumentsAreNeverInterpolated() throws {
        XCTAssertTrue(try read(Self.skill).contains("It is then passed as its own quoted argument (`--reset-tz \"$zone\"`), and never pasted into a command string."))
    }

    func testScheduleLineCarriesNoPerPeriodReason() throws {
        let skill = try read(Self.skill)
        XCTAssertTrue(skill.contains("Schedule: one recurring reminder | one reminder per period\n"),
                      "the Schedule line must be constant so notes compare equal from period to period")
        XCTAssertTrue(skill.contains("The reason goes in the report, never in the notes."))
    }

    func testReadmeListsTheSkill() throws {
        let readme = try read("plugin/README.md")
        XCTAssertTrue(readme.contains("| `quota` |"), "plugin/README.md Skills table must list quota")
    }
}
