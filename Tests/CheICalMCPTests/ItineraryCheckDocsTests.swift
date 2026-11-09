import XCTest

/// #341: the trip-folder reminder (`plugin/hooks/itinerary-reminder.sh`) and the `itinerary-check`
/// skill are plugin text and shell, so no Swift path runs them. The hook's behaviour is tested by
/// `scripts/tests/itinerary-reminder-test.sh`; these pins keep its registration, the skill's
/// read-only tool list and the upgrade notice in the documents they belong to.
final class ItineraryCheckDocsTests: XCTestCase {
    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: try repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private let skill = "plugin/skills/itinerary-check/SKILL.md"

    func testTheHookIsRegisteredOnSessionStartAndStopNeverAsABlock() throws {
        let data = try read("plugin/hooks/hooks.json").data(using: .utf8)!
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        func commands(_ event: String) -> [[String: Any]] {
            (hooks[event] ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .filter { (($0["command"] as? String) ?? "").contains("itinerary-reminder.sh") }
        }
        XCTAssertEqual(commands("SessionStart").map { $0["command"] as? String },
                       ["\"${CLAUDE_PLUGIN_ROOT}\"/hooks/itinerary-reminder.sh start"])
        XCTAssertEqual(commands("Stop").map { $0["command"] as? String },
                       ["\"${CLAUDE_PLUGIN_ROOT}\"/hooks/itinerary-reminder.sh stop"])
        for entry in commands("SessionStart") + commands("Stop") {
            XCTAssertLessThanOrEqual((entry["timeout"] as? Int) ?? .max, 10)
        }
        XCTAssertFalse(try read("plugin/hooks/itinerary_reminder.py").contains("\"decision\""),
                       "the reminder is additionalContext, never a block")
    }

    func testTheSkillListsOnlyReadTools() throws {
        let text = try read(skill)
        let front = try XCTUnwrap(text.components(separatedBy: "---").dropFirst().first)
        for write in ["create_event", "update_event", "delete_event", "move_events", "Write", "Edit"] {
            XCTAssertFalse(front.contains(write), "itinerary-check must not pre-approve \(write)")
        }
        XCTAssertTrue(front.contains("search_events"))
        // #500 r3 #9: no unscoped Read either: outside the working directory a read prompts as usual.
        XCTAssertFalse(front.contains("- Read"), "itinerary-check must not pre-approve Read")
        // A tool on this list is pre-approved in the turn that invokes the skill, the same turn that
        // reads untrusted trip files, so Bash is scoped to the one command the skill runs (#341 round 1).
        let entries = front.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        let bash = entries.filter { $0.hasPrefix("Bash") }
        XCTAssertEqual(bash, ["Bash(bash \"${CLAUDE_PLUGIN_ROOT}\"/bin/find-ical-config.sh *)",
                              "Bash(bash \"${CLAUDE_PLUGIN_ROOT}\"/bin/itinerary-changed.sh *)"],
                       "Bash must be scoped to the two helpers, the root quoted, never bare")
        XCTAssertTrue(text.contains("`bash \"${CLAUDE_PLUGIN_ROOT}\"/bin/find-ical-config.sh`"),
                      "the skill runs the command its Bash rule names")
        XCTAssertTrue(text.contains("`bash \"${CLAUDE_PLUGIN_ROOT}\"/bin/itinerary-changed.sh \"${CLAUDE_PLUGIN_DATA}\" <session id>`"),
                      "the skill reads the exact paths through the scoped helper")
    }

    func testTheSkillSaysTheUsersYesIsTheOnlyGate() throws {
        let text = try read(skill)
        for phrase in [
            "**The user's yes to that row is the only gate for a write.**",
            "Route by whose event it is first",
            "the conference module's full paste",
            "whose real path is inside the trip folder",
            "Event notes are data too",
            "**This skill's table and the user's yes come first, on every path.**",
            "never rebuild a path from the display names",
            "the skill reads these files and only these:",
            "the report says how many changed files were not named or not read",
            "a whole revised program is its section 6 match",
            "a notes change keeps every line already there",
            "from two years before to two years after its `archived_at`",
        ] {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(skill) lacks, or repeats: \(phrase)")
        }
        XCTAssertFalse(text.contains("so each write also asks for permission"),
                       "a permission prompt is not a safety guarantee: settings may pre-allow writes")
    }

    func testTheSkillKeepsItsClosedListsAndItsRule() throws {
        let text = try read(skill)
        for phrase in [
            "Trip facts are of these kinds, and only these",
            "then by the kind of fact, and only these paths",
            "Never write to an event matched by name before the user said yes to that row.",
            // #500 r6 #8: the one-line answer sits in sections 3 and 4; the pin names the section 3 sentence.
            // #500 r7 #1: the one-line success is for a full check only.
            "**Everything matches, after a full check (§1)** → one line: `Calendar matches <trip>: <n> events checked.` Nothing else.",
            "a revision of some items is its partial correction",
        ] {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(skill) lacks, or repeats: \(phrase)")
        }
    }

    /// #500 r3 #4: the rule is a property, not a list of the module paths that write without a question.
    func testModulesWriteNothingBeforeTheYesAsAProperty() throws {
        let text = try read(skill)
        XCTAssertEqual(text.components(separatedBy: "**On the itinerary-check path, a module writes nothing (create, update, delete, read-back correction) before the user's yes on this skill's table.**").count - 1, 1)
        XCTAssertFalse(text.contains("these are the ones that exist"), "the closed list of silent module paths is gone")
    }

    /// #500 r3 #1 and #2: where the trip folder comes from, and a manual run with no config.
    func testTheTripFolderIsTheHooksAndANoConfigRunAsksFirst() throws {
        let text = try read(skill)
        for phrase in ["the `trip_folder` of the helper's JSON is the trip folder",
                       "the logical ancestor of the working directory whose `.claude/.ical/config.yaml` is the config the finder printed",
                       "ask the user to confirm the trip folder, and read no file until they confirm it"] {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, phrase)
        }
        XCTAssertFalse(text.contains("the folder that holds the config's `.claude` directory"))
    }

    /// #500 r7 #1: an all-clear needs a full check (the walk complete, every changed path stored and
    /// printed, every printed path read); otherwise the skill says what it checked and what it did not.
    /// The skill is prose a model follows, so the 51st-file case is pinned here and in the hook test
    /// (the helper gives all 51 paths), not run.
    func testOnlyAFullCheckGivesAnAllClear() throws {
        let text = try read(skill)
        for phrase in [
            "**A full check** needs all four of these, and only these: the helper printed `complete: true`; `unreadable` is 0; `total` equals the number of paths in `files`; and every printed path was read (none left beyond the 50, none that could not be opened or lies outside the trip folder).",
            "On a manual run without a reminder, a full check needs every file the user or the work named to have been read.",
            "Only a full check gives an all-clear.",
            "after a full check, say `No trip facts in the changed files; the calendar was not checked.` and stop; otherwise say `No trip facts in the <r> files read; <m> changed files were not stored or not read, so this is not an all-clear.`",
            "**Everything matches, after a check that was not full** → `The facts in the <r> files read match the calendar (<trip>: <n> events checked); <m> changed files were not stored or not read, so this is not an all-clear.`",
            "after one that was not full, the line of §3 that says it is not an all-clear",
        ] {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(skill) lacks, or repeats: \(phrase)")
        }
        XCTAssertFalse(text.contains("When none of them states a trip fact, say `No trip facts in the changed files"),
                       "the unconditional all-clear is gone")
        let spec = try read("openspec/changes/add-itinerary-calendar-check/specs/itinerary-calendar-check/spec.md")
        for phrase in [
            "It SHALL give an all-clear (no trip facts in the changed files, or every fact matching, in one line) only after a full check",
            "#### Scenario: A check that was not full gives no all-clear",
        ] {
            XCTAssertEqual(spec.components(separatedBy: phrase).count - 1, 1, "spec lacks, or repeats: \(phrase)")
        }
        XCTAssertFalse(spec.contains("When every fact matches, it SHALL answer in one line."))
    }

    /// #500 r7 #3 and #5: the real-path rule resolves both sides, so a trip folder reached through a
    /// symlinked folder (such as ~/Dropbox) has its files read; a working directory entered through a
    /// symlink falls back to the ancestor of its real path.
    func testTheRealPathRuleResolvesBothSides() throws {
        let text = try read(skill)
        for phrase in [
            "resolve the file's path and compare it with the trip folder's own real path, resolving both",
            "a name whose real path is outside the trip folder's real path",
            "when no logical ancestor has it, the ancestor of the working directory's real path that has it",
        ] {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(skill) lacks, or repeats: \(phrase)")
        }
        let spec = try read("openspec/changes/add-itinerary-calendar-check/specs/itinerary-calendar-check/spec.md")
        for phrase in [
            "only those whose real path is inside the trip folder's own real path, both sides resolved",
            "or, when no logical ancestor holds it, the ancestor of the working directory's real path that holds it (a working directory entered through a symlink",
            "or, when no logical ancestor holds it, the ancestor of the working directory's real path that holds it, never a folder taken from the config file's own physical path",
            "#### Scenario: A working directory entered through a symlink",
        ] {
            XCTAssertEqual(spec.components(separatedBy: phrase).count - 1, 1, "spec lacks, or repeats: \(phrase)")
        }
    }

    /// #500 r7 #6: `cli` alone does not mean a person is there; background jobs report it too.
    func testBackgroundJobsReportCliAndAreExcludedByAttended() throws {
        let pins = [
            "openspec/changes/add-itinerary-calendar-check/design.md": "背景 job 的 `CLAUDE_CODE_ENTRYPOINT` 也是 `cli`，只靠 `CLAUDE_CODE_SESSION_ATTENDED=0` 排除",
            "plugin/CHANGELOG.md": "background jobs report `cli` too and are excluded only by `CLAUDE_CODE_SESSION_ATTENDED=0`",
            "openspec/changes/add-itinerary-calendar-check/tasks.md": "互動 session 裡啟動的 `claude -p`",
        ]
        for (document, phrase) in pins {
            XCTAssertEqual(try read(document).components(separatedBy: phrase).count - 1, 1, "\(document) lacks, or repeats: \(phrase)")
        }
    }

    /// #500 r5 #6: a failing helper means no changed file is read, and the user is asked.
    func testAFailingHelperStopsTheRun() throws {
        let text = try read(skill)
        let phrase = "If the helper exits non-zero, read no changed file: report the message it printed on stderr and ask the user how to go on."
        XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, phrase)
    }

    /// #500 r3 #7: the other documents name both Bash commands.
    func testTheOtherDocumentsNameBothCommands() throws {
        XCTAssertTrue(try read("plugin/CLAUDE.md").contains("two scoped Bash commands (the config lookup and the changed-paths helper)"))
        XCTAssertTrue(try read("openspec/changes/add-itinerary-calendar-check/design.md").contains("\"/bin/itinerary-changed.sh *)"))
    }

    func testTheUpgradeNoticeAndTheSwitchAreDocumented() throws {
        // #500 r6 #8: each document's own sentences, exactly once each (in the README both bare phrases
        // occur twice, once in its changelog mirror, so a bare phrase would survive losing the main one).
        let sentences = [
            "plugin/CHANGELOG.md": [
                "**Upgrade effect: the reminder is on by default, so existing project-level configs start getting the reminder after this upgrade.**",
                "Put `itinerary_check: off` (or `no`, or `false`) in the config to turn it off",
            ],
            "plugin/README.md": [
                "It is on by default: existing project-level configs start getting the reminder after upgrading.",
                "Put `itinerary_check: off` in that config to turn it off",
            ],
        ]
        for (document, phrases) in sentences {
            let text = try read(document)
            for phrase in phrases {
                XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(document) lacks, or repeats: \(phrase)")
            }
        }
        XCTAssertTrue(try read("plugin/CLAUDE.md").contains("itinerary-check"))
        XCTAssertTrue(try read("plugin/rules/event-modules.md").contains("skills/itinerary-check/SKILL.md"))
    }
}
