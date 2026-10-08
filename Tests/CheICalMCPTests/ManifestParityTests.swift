import XCTest
@testable import CheICalMCP

/// Guards against drift between the two places the MCP tool surface is advertised:
///
/// 1. `Server.defineTools()` — the runtime tool list exposed via MCP
/// 2. `mcpb/manifest.json` — the bundle manifest shipped to Claude Desktop
///
/// If either advertises a tool the other doesn't, users see tools that don't work,
/// or miss tools that are actually implemented. The #21 two-commit history
/// (feat commit added only Server.swift; docs commit added manifest entry) showed
/// how easy this drift is. This test catches it at `swift test` time.
final class ManifestParityTests: XCTestCase {

    /// Walk up from this test file until `mcpb/manifest.json` is found.
    /// Robust against `swift test` working-directory quirks across CI and local runs.
    private func locateManifest() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("mcpb/manifest.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        throw XCTSkip("mcpb/manifest.json not found within 10 parent directories of \(#filePath)")
    }

    func testManifestToolsMatchDefineTools() throws {
        let manifestURL = try locateManifest()
        let data = try Data(contentsOf: manifestURL)

        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = manifest["tools"] as? [[String: Any]]
        else {
            XCTFail("mcpb/manifest.json did not parse as object with 'tools' array")
            return
        }

        let manifestNames = Set(tools.compactMap { $0["name"] as? String })
        let declaredNames = Set(CheICalMCPServer.defineTools().map { $0.name })

        let missingFromManifest = declaredNames.subtracting(manifestNames)
        let extraInManifest = manifestNames.subtracting(declaredNames)

        XCTAssertTrue(
            missingFromManifest.isEmpty,
            "Tools declared in defineTools() but missing from mcpb/manifest.json: \(missingFromManifest.sorted())"
        )
        XCTAssertTrue(
            extraInManifest.isEmpty,
            "Tools in mcpb/manifest.json but not in defineTools(): \(extraInManifest.sorted())"
        )
    }

    /// Every manifest entry must carry a non-empty description, so bundle
    /// consumers (Claude Desktop, etc.) can render a meaningful tool list.
    func testManifestEntriesHaveNonEmptyDescriptions() throws {
        let manifestURL = try locateManifest()
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = manifest?["tools"] as? [[String: Any]] ?? []

        var emptyDescriptionTools: [String] = []
        for entry in tools {
            let name = (entry["name"] as? String) ?? "<unknown>"
            let description = (entry["description"] as? String) ?? ""
            if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyDescriptionTools.append(name)
            }
        }
        XCTAssertTrue(
            emptyDescriptionTools.isEmpty,
            "Tools in manifest with empty descriptions: \(emptyDescriptionTools)"
        )
    }

    /// `AppVersion.mcpServerName` — the constant that feeds the running server's
    /// `serverInfo.name` at `Server.swift` — MUST equal the manifest / extension
    /// id (`mcpb/manifest.json` `name`). Both are kebab `che-ical-mcp`.
    ///
    /// Motivation (#166): `serverInfo.name` was PascalCase `CheICalMCP` while the
    /// manifest id is kebab `che-ical-mcp`; the leading (Desktop-side **unproven**)
    /// hypothesis is that Claude Desktop 1.18286.0 reconciles the two and drops the
    /// whole server on mismatch. A matching name is a baseline MCP expectation
    /// regardless, and this guards the same drift class as `tools[].name` above.
    ///
    /// SCOPE (deliberate): this asserts the **constant ↔ manifest** value parity.
    /// It does NOT assert the live `Server(name:)` **wiring** (that `Server.swift`
    /// actually passes `mcpServerName` rather than `AppVersion.name`) — a wiring
    /// revert would not be caught here. That wiring is grep- + runtime-probe-
    /// verified; a true wiring seam is tracked as a follow-up.
    func testServerInfoNameMatchesManifestName() throws {
        let manifestURL = try locateManifest()
        let data = try Data(contentsOf: manifestURL)

        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifestName = manifest["name"] as? String
        else {
            XCTFail("mcpb/manifest.json did not parse as object with a 'name' string")
            return
        }

        XCTAssertEqual(
            AppVersion.mcpServerName, manifestName,
            "serverInfo.name (AppVersion.mcpServerName=\"\(AppVersion.mcpServerName)\") must equal mcpb/manifest.json name (\"\(manifestName)\") so Claude Desktop can reconcile the running server against its extension id (#166)."
        )
    }

    /// #166 CONFIRMED ROOT CAUSE: a literal `&` (ampersand) in the manifest
    /// `display_name` makes Claude Desktop 1.18286.0's tool-injection layer
    /// silently drop the ENTIRE server from every conversation — handshake and
    /// `tools/list` still complete, so nothing surfaces in any log.
    ///
    /// Proven by single-variable intervention on the exact failing Desktop
    /// install (2026-07-03): with the 29-tool binary + manifest unchanged except
    /// `display_name` "macOS Calendar & Reminders" → "macOS Calendar and
    /// Reminders", the server flipped from dropped → injecting real EventKit
    /// data. Two earlier hypotheses (serverInfo.name mismatch; tool
    /// schema-depth / description-length / tool-count) were empirically refuted
    /// — they survived every test precisely because `display_name` was never the
    /// varied variable.
    ///
    /// `&` is the only character CONFIRMED to break injection; `<` and `>` are
    /// guarded alongside it as defense-in-depth (same XML/HTML metacharacter
    /// class, unverified) so this bug class cannot silently recur.
    func testDisplayNameHasNoXMLMetacharacters() throws {
        let manifestURL = try locateManifest()
        let data = try Data(contentsOf: manifestURL)

        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displayName = manifest["display_name"] as? String
        else {
            XCTFail("mcpb/manifest.json did not parse as object with a 'display_name' string")
            return
        }

        let forbidden = displayName.filter { "&<>".contains($0) }
        XCTAssertTrue(
            forbidden.isEmpty,
            "mcpb/manifest.json display_name (\"\(displayName)\") must not contain XML/HTML metacharacters \(Array("&<>")) — a literal `&` makes Claude Desktop 1.18286.0 silently drop the whole server from conversations (#166, confirmed root cause). Found: \(Array(forbidden))."
        )
    }

    /// #231: `alarms[].minutes_before` flips EventKit's sign (EventKit: negative =
    /// before), so both places a client first reads about the field state the sign.
    func testReminderReadToolsStateTheSignOfMinutesBefore() throws {
        let sign = "positive = before the due date, negative = after"
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        for name in ["list_reminders", "search_reminders"] {
            let declared = CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? ""
            XCTAssertTrue(declared.contains(sign), "defineTools() \(name): \(declared)")
            let summary = entries.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(summary.contains(sign), "mcpb/manifest.json \(name): \(summary)")
        }
    }

    /// #247 (maintainer decision, 2026-10-07): a redo entry that writes nothing is answered once and
    /// then removed from the redo history, so both places a client reads about `redo` say so, and
    /// neither still says the entry stays.
    func testRedoDescriptionsSayAnEntryThatWritesNothingIsRemoved() throws {
        let removed = "removed from the redo history"
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let declared = CheICalMCPServer.defineTools().first { $0.name == "redo" }?.description ?? ""
        let summary = entries.first { $0["name"] as? String == "redo" }?["description"] as? String ?? ""
        for (place, text) in [("defineTools()", declared), ("mcpb/manifest.json", summary)] {
            XCTAssertTrue(text.contains(removed), "\(place) redo: \(text)")
            XCTAssertFalse(text.contains("stays on top") || text.contains("as it was") || text.contains("as they were"),
                           "\(place) redo: \(text)")
        }
    }

    /// PR #282 round 3, finding 4: the `undo` description and its manifest summary are edited by
    /// #242 (PR #277), #244 (PR #278) and #248 (PR #282), each one line, so a merge that drops one
    /// clause passes every other test. Each clause is pinned in both places a client reads it; the
    /// phrasing may differ between them, the fact may not go.
    func testUndoDescriptionsKeepEveryClause() throws {
        // `summary` is nil for a clause the manifest summary does not carry: the summary is short,
        // and the error counts are named only in the description (PR #282 round 4, findings 5, 10).
        let clauses: [(what: String, declared: String, summary: String?)] = [
            ("#242: a reminder's recorded list not found",
             "the reminder list it restores into is not found under its recorded identifier",
             "a reminder's recorded list is not found"),
            ("#242: giving up a delete_reminder undo loses the reminder",
             "giving up the undo of a delete_reminder loses the deleted reminder",
             "discarding a delete_reminder undo loses the deleted reminder"),
            ("#244: a batch holding a never-restorable delete is refused whole and its entry discarded",
             "a delete_events_batch that holds such a delete (refused before any of its events is restored)",
             "a batch holding one that did not is refused before any write and its entry discarded"),
            ("#244: a deleted occurrence comes back as a one-off event",
             "Undo of a delete of one occurrence restores it as a one-off event",
             "a deleted occurrence comes back as a one-off event"),
            ("#244 (#285): a series deleted whole comes back from its rules alone",
             "undo of a whole-series delete (delete_event span future from the first occurrence, or span all) recreates the series from its rules alone",
             "a series deleted whole comes back from its rules alone"),
            ("#236, #244: the count of refusals that discard the record",
             "Five refusals discard the record instead",
             nil),
            ("#248: a batch undo is refused before any write, its entry kept, for a missing or read-only calendar or list",
             "is refused before any write, its record kept whole, when the calendar or list of any of its items is missing or read-only",
             "a batch undo is refused before any write, its entry kept, when an item's calendar or list is missing or read-only"),
            ("#248: the refusal counts the items",
             "the error counts the items this stops and those whose calendar or list is in place",
             nil),
            ("#248: giving up a batch undo drops every item",
             "giving up that undo with discard_id drops every item of the entry",
             "discarding it drops every item of the batch"),
            ("#248: a batch undo that fails part-way keeps only the items not yet restored",
             "A batch undo that fails part-way keeps only the items not yet restored.",
             "a batch undo that fails part-way keeps only the items not yet restored;"),
        ]
        let (declared, summary) = try descriptions(of: "undo")
        // Round 5, finding 17: no batch member's write throws a permanent error today, so the
        // client-facing text does not describe a member being dropped.
        XCTAssertFalse(declared.contains("no retry can restore") || summary.contains("no retry can restore"), declared + summary)
        for clause in clauses {
            XCTAssertTrue(declared.contains(clause.declared), "defineTools() undo lost \(clause.what): \(declared)")
            if let pinned = clause.summary {
                XCTAssertTrue(summary.contains(pinned), "mcpb/manifest.json undo lost \(clause.what): \(summary)")
            }
        }
    }

    /// The same for the batch deletes whose undo is a batch record (#185, #243): what one undo
    /// restores, the #244 refusal (events), and #248's refusal and its discard cost (finding 16).
    func testBatchDeleteDescriptionsSayWhatTheirUndoRefusesAndWhatGivingUpCosts() throws {
        let clauses: [(tool: String, clause: String)] = [
            ("delete_events_batch", "comes back as a one-off event"),
            ("delete_events_batch", "holding a span 'future' delete that delete_event's undo would refuse is refused before any of its events is restored"),
            ("delete_events_batch", "when the calendar of any of its events is missing or read-only"),
            ("delete_events_batch", "giving up that undo with discard_id drops every event of the batch"),
            ("delete_reminders_batch", "one undo recreates every reminder it deleted"),
            ("delete_reminders_batch", "when the list of any of its reminders is missing or read-only"),
            ("delete_reminders_batch", "giving up that undo with discard_id drops every reminder of the call"),
            ("cleanup_completed_reminders", "One undo recreates every reminder it deleted"),
            ("cleanup_completed_reminders", "when the list of any of its reminders is missing or read-only"),
            ("cleanup_completed_reminders", "giving up that undo with discard_id drops every reminder of the call"),
        ]
        for (tool, clause) in clauses {
            let declared = try descriptions(of: tool).declared
            XCTAssertTrue(declared.contains(clause), "defineTools() \(tool) lost: \(clause)\n\(declared)")
        }
        // The manifest summaries say it too, shorter (PR #282 round 4, findings 4, 16).
        let summaries: [(tool: String, clause: String)] = [
            ("delete_events_batch", "the undo is refused before any write, and its entry kept, when an event's calendar is missing or read-only, and discarding it then drops every event"),
            ("delete_reminders_batch", "the undo is refused before any write, and its entry kept, when a reminder's list is missing or read-only, and discarding it then drops every reminder"),
            ("cleanup_completed_reminders", "the undo is refused before any write, and its entry kept, when a reminder's list is missing or read-only, and discarding it then drops every reminder"),
        ]
        for (tool, clause) in summaries {
            let summary = try descriptions(of: tool).summary
            XCTAssertTrue(summary.contains(clause), "mcpb/manifest.json \(tool) lost: \(clause)\n\(summary)")
        }
    }

    /// The `defineTools()` description and the manifest summary of `tool`.
    private func descriptions(of tool: String) throws -> (declared: String, summary: String) {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let declared = CheICalMCPServer.defineTools().first { $0.name == tool }?.description ?? ""
        let summary = entries.first { $0["name"] as? String == tool }?["description"] as? String ?? ""
        return (declared, summary)
    }

    /// #244 verify round 4: undo of a whole-series delete recreates the series from its rules
    /// alone (#285), so an occurrence deleted on its own before comes back. "Comes back from its
    /// rules, without the occurrences deleted or edited on their own before" read as the opposite.
    /// Every place a client reads about the undo before it runs states it in the same words, with
    /// what was seen on device (round 5, findings 9/12; round 6, findings 5/9/13: the manifest
    /// summary too, and seen with delete_event, not delete_events_batch). The
    /// negative check catches that one phrase only, not every backwards rewording (round 5,
    /// findings 5/15): the positive clause is the guard.
    func testUndoSurfacesSayAWholeSeriesRestoreBringsDeletedOccurrencesBack() throws {
        let restored = "an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit, and undoing the earlier delete of that occurrence as well adds it a second time"
        let evidence = restored + " (seen on iCloud only, with delete_event; the lost edit and the duplicate not yet checked with span 'all')"
        let backwards = "without the occurrences"
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let declared = CheICalMCPServer.defineTools()
        for name in ["delete_event", "delete_events_batch", "undo"] {
            let description = declared.first { $0.name == name }?.description ?? ""
            XCTAssertTrue(description.contains(evidence), "defineTools() \(name): \(description)")
        }
        let summary = entries.first { $0["name"] as? String == "undo" }?["description"] as? String ?? ""
        XCTAssertTrue(summary.contains(evidence), "mcpb/manifest.json undo: \(summary)")
        for tool in declared {
            XCTAssertFalse((tool.description ?? "").contains(backwards), "defineTools() \(tool.name)")
        }
        for entry in entries {
            XCTAssertFalse((entry["description"] as? String ?? "").contains(backwards), "mcpb/manifest.json \(entry["name"] ?? "")")
        }
    }
}
