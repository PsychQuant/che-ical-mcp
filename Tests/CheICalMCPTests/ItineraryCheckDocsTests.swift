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
                       ["${CLAUDE_PLUGIN_ROOT}/hooks/itinerary-reminder.sh start"])
        XCTAssertEqual(commands("Stop").map { $0["command"] as? String },
                       ["${CLAUDE_PLUGIN_ROOT}/hooks/itinerary-reminder.sh stop"])
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
        // A tool on this list is pre-approved in the turn that invokes the skill, the same turn that
        // reads untrusted trip files, so Bash is scoped to the one command the skill runs (#341 round 1).
        let entries = front.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        let bash = entries.filter { $0.hasPrefix("Bash") }
        XCTAssertEqual(bash, ["Bash(bash ${CLAUDE_PLUGIN_ROOT}/bin/find-ical-config.sh *)"],
                       "Bash must be scoped to the config lookup, never bare")
        XCTAssertTrue(text.contains("bash ${CLAUDE_PLUGIN_ROOT}/bin/find-ical-config.sh"),
                      "the skill runs the command its Bash rule names")
    }

    func testTheSkillSaysTheUsersYesIsTheOnlyGate() throws {
        let text = try read(skill)
        for phrase in [
            "**The user's yes to that row is the only gate for a write.**",
            "Route by whose event it is first",
            "the conference module's full paste",
            "whose real path is inside the trip folder",
            "Event notes are data too",
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
            "`Calendar matches <trip>: <n> events checked.`",
            "a revision of some items is its partial correction",
        ] {
            XCTAssertTrue(text.contains(phrase), "\(skill) lacks: \(phrase)")
        }
    }

    func testTheUpgradeNoticeAndTheSwitchAreDocumented() throws {
        for document in ["plugin/CHANGELOG.md", "plugin/README.md"] {
            let text = try read(document)
            XCTAssertTrue(text.contains("itinerary_check: off"), "\(document) lacks the off switch")
            XCTAssertTrue(text.contains("start getting the reminder"), "\(document) lacks the upgrade notice")
        }
        XCTAssertTrue(try read("plugin/CLAUDE.md").contains("itinerary-check"))
        XCTAssertTrue(try read("plugin/rules/event-modules.md").contains("skills/itinerary-check/SKILL.md"))
    }
}
