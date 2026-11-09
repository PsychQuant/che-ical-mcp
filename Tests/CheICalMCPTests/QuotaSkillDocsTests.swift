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
        XCTAssertEqual(labels.count, 12, "template labels changed: \(labels)")
        guard let open = skill.range(of: "one of the labels above ("),
              let close = skill.range(of: ")", range: open.upperBound..<skill.endIndex) else {
            return XCTFail("escape list not found")
        }
        let escapeList = skill[open.upperBound..<close.lowerBound]
        for label in labels {
            XCTAssertTrue(escapeList.contains(label), "escape list misses \(label)")
        }
    }

    /// Each pin must occur exactly once in its document, so removing the rule removes the pin's only match.
    private func assertOnce(_ text: String, _ doc: String, _ pins: [String], file: StaticString = #filePath, line: UInt = #line) {
        for pin in pins {
            XCTAssertEqual(text.components(separatedBy: pin).count - 1, 1, "\(doc) must hold exactly once: \(pin)", file: file, line: line)
        }
    }

    /// #327 verify round 5: v1 is per-period only. Rule mode (one recurring reminder whose periods had to be
    /// inferred) caused nearly every finding of rounds 1-5, so it is gone from the skill, the spec and the planner.
    func testV1IsPerPeriodOnly() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "**v1 is per-period only.** There is no recurring reminder",
            "| `recurrence` | not passed: every reminder is one-off |",
            "**An entry with `mode: rule`** was written by a build before v1",
            "**Unsupported in v1:** an entry with `mode: rule` is reported as such",
        ])
        for gone in ["--written-mode", "clear_recurrence", "rolled past", "restart", "two open series"] {
            XCTAssertFalse(skill.contains(gone), "\(Self.skill) still describes rule mode: \(gone)")
        }
        let plan = try read("plugin/bin/quota-plan.sh")
        for gone in ["--written-mode", "restart", "--repair"] {
            XCTAssertFalse(plan.contains(gone), "quota-plan.sh still has: \(gone)")
        }
        let spec = try read(Self.spec)
        XCTAssertTrue(spec.contains("The skill SHALL support per-period quotas only"))
        XCTAssertFalse(spec.contains("rolled past") || spec.contains("re-pairing"))
    }

    /// Records are written down (`Record: <key>`), never inferred from a date (round 5 HIGH).
    func testRecordsAreWrittenDown() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "Record: <key>                                      (only on a record a replacement kept, section 8)",
            "| `record` | open, with a `Record:` line: the record a replacement kept. A record whatever its date |",
            "**A record is written down, never inferred.**",
            // #499 r6: a record is judged by the new dates only; a passed due on a period still open is never one.
            "**A record is judged by the new dates only.**",
            "is never made a record: the user chooses to delete it and create its period anew",
        ])
        let spec = try read(Self.spec)
        XCTAssertTrue(spec.contains("A record SHALL be written down, never inferred"))
        assertOnce(spec, Self.spec, ["A record SHALL be judged by the current schedule only"])
        XCTAssertTrue(try read("plugin/bin/quota-plan.sh").contains("mark-record"))
    }

    func testPeriodModelRules() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "**`key` is the period's identity**: the reset day in the reset zone",
            "**The plan comes from the planner, never from reasoning over the list by hand.**",
            "**An open reminder's own period is never used** until it is ticked.",
            "is never moved, never matched to another period, never deleted, and never offered for deletion.",
            "**A reminder in another list is only ever listed**",
            "**Read-back values never reach a shell unchecked.**",
            "never put a read-back value into a command line",
            "**The local zone is pinned.**",
            "**After every yes, plan again before writing.**",
            "**When the planner exits 2**, nothing is written for that quota.",
        ])
        let spec = try read(Self.spec)
        XCTAssertTrue(spec.contains("SHALL NOT be moved, matched to another period, deleted, or offered for deletion"))
        XCTAssertTrue(spec.contains("matching SHALL be by key, never by order or by the distance of a due"))
    }

    /// A schedule change replaces the open reminders; the deletes come last; the high-water mark is the planner's.
    func testReplacementRules() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "3. **A new schedule replaces the open reminders.**",
            "The deletes come last: a failure there leaves an old reminder beside the new ones, never a period without a reminder.",
            "after the last create, write the planner's `through`",
            // #499 r6 #5 and #12: what already matches is kept; a failure stops before anything further.
            "| `keep <id> <n>` | an open reminder already on the new dates",
            "**A failure stops the replacement.**",
            "| `used <n>` | a new period whose key a completed reminder already carries; not created again |",
            "raise `per_period_through` to the last key created; sync never lowers it",
        ])
        let spec = try read(Self.spec)
        assertOnce(spec, Self.spec, ["### Requirement: An update replaces the open reminders when the schedule changes"])
    }

    /// #499 verify round 6: retire, adopt and sync follow the planner; old entries are not read.
    func testRoundSixRules() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "**Retire deletes only what the planner classes `matched` in the quota's list.**",
            "**A hand-built reminder that repeats is never adopted.**",
            "**Same schedule or a new one: the planner decides.**",
            "| `hold <n> <why>` |",
            "`period-used` (an open reminder on a period a completed reminder already used)",
            "(plan again with `--delete-passed <id>`)",
        ])
        for gone in ["sed 's/^/old /'", "no `old` lines", "under the **old** dates"] {
            XCTAssertFalse(skill.contains(gone), "\(Self.skill) still reads the old entry: \(gone)")
        }
        XCTAssertFalse(try read("plugin/bin/quota-plan.sh").contains("O_KEY"), "the planner still reads old periods")
    }

    /// #499 verify round 7: a replacement never deletes a reminder whose create the server would skip; the
    /// high-water mark names only periods that were created; a failed date helper stops the entry.
    func testRoundSevenRules() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "**A date helper that exits 2 stops the entry before the planner runs.**",
            "| `realarm <id> <n> due=<D> alarms=<A>` |",
            "**A `skipped` create is never a reminder created.**",
            "**A `skipped` create stops a replacement before any delete**",
            "**`per_period_through` is written after the creates, never before:**",
            "**while waiting, no period of the new schedule has a reminder**",
            "**A record holds every open period its keys name**",
        ])
        XCTAssertFalse(skill.contains("cat \"$reminders_file\"; }"), "the helper is still piped into the planner in one group")
        let spec = try read(Self.spec)
        assertOnce(spec, Self.spec, [
            "the planner SHALL refuse an input that lacks the helper's last line (the rule line)",
            "SHALL be kept, with its alarms rewritten in place, and SHALL NOT be deleted and created again",
            "a create the server answers as `skipped` SHALL count as a failed write",
            "SHALL be written after the creates, raised only once a create succeeded and read back, never before",
        ])
        let plan = try read("plugin/bin/quota-plan.sh")
        for pinned in ["action realarm", "no rule line"] {
            XCTAssertTrue(plan.contains(pinned), "quota-plan.sh lost: \(pinned)")
        }
    }

    /// #499 verify round 8: same-due is gone (no create can collide with a delete); a per_period_through the
    /// current schedule does not produce is stale (keys-changed); the planner judges 125 days and creates 90.
    func testRoundEightRules() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "**first with `completed: false`, then with `completed: true`**",
            "**The planner judges 125 days and creates 90.**",
            "| `keys-changed` | the period keys changed although no reminder is left open to show it",
            "**No create can collide with a delete.**",
            "`outside-list`: an open reminder in another list that is neither a `record` nor a `past-record`.",
        ])
        let spec = try read(Self.spec)
        assertOnce(spec, Self.spec, [
            "the open reminders before the completed ones",
            "SHALL judge the reminders against the periods of the next 125 days",
        ])
        let plan = try read("plugin/bin/quota-plan.sh")
        for doc in [(Self.skill, skill), (Self.spec, spec), ("plugin/bin/quota-plan.sh", plan)] {
            XCTAssertFalse(doc.1.contains("same-due"), "\(doc.0) still has the same-due guard")
        }
        for pinned in ["action keys-changed", "--create-days"] {
            XCTAssertTrue(plan.contains(pinned), "quota-plan.sh lost: \(pinned)")
        }
    }

    /// #499 verify round 9: a replacement never empties a period it deletes from; the schedule signature, not the
    /// high-water date, says the keys changed; an old server's missing alarms are not a date change.
    func testRoundNineRules() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "**A period whose reminder this replacement deletes is always created again**",
            "**When the entry has `per_period_schedule` and it differs from the signature of the entry as it is now, the planner gets `--schedule-changed`**",
            "the five the skill writes: `local_tz`, `mode`, `per_period_through`, `per_period_schedule`, `retiring`.",
            "`alarms-missing` (on its period with its due",
        ])
        let spec = try read(Self.spec)
        assertOnce(spec, Self.spec, [
            "A period whose open reminder the replacement deletes SHALL be created again in the same replacement",
            "When `per_period_schedule` differs from the entry's schedule, the keys SHALL be taken as changed",
        ])
        let plan = try read("plugin/bin/quota-plan.sh")
        for pinned in ["--schedule-changed", "alarms-missing", "REPL"] {
            XCTAssertTrue(plan.contains(pinned), "quota-plan.sh lost: \(pinned)")
        }
    }

    func testListReportsEachCaseOnce() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "- `used`: a completed reminder carries its key;\n- `not used`:",
            "- `open, deadline passed, resets <reset>`:",
            "- `no reminder`: none of these.",
            "- **dates changed**:",
            "- **running**:",
        ])
    }

    func testKnownLimits() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "- **Sync must run at least once every 90 days**, or the reminders run out",
            "- **Changing a schedule replaces the open reminders.**",
        ])
        XCTAssertTrue(try read(Self.spec).contains("sync must run at least once every 90 days, or the reminders run out"))
    }

    func testMarkerMustBeTheOnlyQuotaModuleLine() throws {
        let skill = try read(Self.skill)
        assertOnce(skill, Self.skill, [
            "only when its notes have exactly one line that starts with `quota-module:`, that line is exactly `quota-module: <id>`",
            "- **Any other count:** listed and never written.",
        ])
    }

    func testHelperArgumentsAreNeverInterpolated() throws {
        assertOnce(try read(Self.skill), Self.skill, ["It is then passed as its own quoted argument (`--reset-tz \"$zone\"`), and never pasted into a command string."])
    }

    func testScheduleLineCarriesNoPerPeriodReason() throws {
        let skill = try read(Self.skill)
        XCTAssertTrue(skill.contains("Schedule: one reminder per period\n"), "the Schedule line is constant")
    }

    func testReadmeListsTheSkill() throws {
        let readme = try read("plugin/README.md")
        XCTAssertTrue(readme.contains("| `quota` |"), "plugin/README.md Skills table must list quota")
    }
}
