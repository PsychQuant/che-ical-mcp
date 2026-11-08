import MCP
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

    /// PR #387 verify round 2 (#166 class): no served tool text carries an XML/HTML metacharacter.
    /// #166's Desktop silent drop was a literal `&` in `display_name`; tool text had none of `<`
    /// and `>` until a description quoted an id shape in brackets. Every tool description, every
    /// string in every input schema (property descriptions, enum values) and every manifest tool
    /// description is checked.
    func testServedToolTextHasNoXMLMetacharacters() throws {
        func strings(_ value: Value) -> [String] {
            switch value {
            case .string(let text): return [text]
            case .array(let items): return items.flatMap(strings)
            case .object(let fields): return fields.keys.map { $0 } + fields.values.flatMap(strings)
            default: return []
            }
        }
        var offending: [String] = []
        for tool in CheICalMCPServer.defineTools() {
            for text in [tool.description ?? ""] + strings(tool.inputSchema) where text.contains(where: { "&<>".contains($0) }) {
                offending.append("\(tool.name): \(text.prefix(80))")
            }
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: try locateManifest())) as? [String: Any]
        for entry in manifest?["tools"] as? [[String: Any]] ?? [] {
            let text = entry["description"] as? String ?? ""
            if text.contains(where: { "&<>".contains($0) }) { offending.append("manifest \(entry["name"] ?? ""): \(text.prefix(80))") }
        }
        XCTAssertEqual(offending, [], "served tool text must not contain & < > (#166)")
    }

    /// #261: the create tools say that a save reported as an error but found saved succeeds, and
    /// that `store_differs` names the differing fields with the exact keys `NewObjectSave.Fields`
    /// compares; undo says its message names them. Both in defineTools() and in the manifest.
    /// #291 item 6: the keys are read from the list in the store_differs sentence and compared
    /// with the constants both ways, so a key missing from the list and a key the list adds both fail.
    func testCreateAndUndoDescriptionsNameTheStoreDiffersKeys() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        func declared(_ name: String) -> String { CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? "" }
        func summary(_ name: String) -> String { entries.first { $0["name"] as? String == name }?["description"] as? String ?? "" }
        for (name, keys) in [("create_reminder", NewObjectSave.reminderFieldNames), ("create_calendar", NewObjectSave.listFieldNames)] {
            for (place, text) in [("defineTools()", declared(name)), ("mcpb/manifest.json", summary(name))] {
                XCTAssertEqual(Self.storeDiffersKeys(in: text), keys, "\(place) \(name): \(text)")
            }
        }
        // #291 item 5: a retried create's duplicate check may not match an item the store holds
        // differently, so every create that can answer store_differs warns of a second copy.
        let warning = "again with the same parameters may make a second copy"
        for name in ["create_reminder", "create_reminders_batch", "create_calendar"] {
            XCTAssertTrue(declared(name).contains("store_differs") && declared(name).contains("note"), "defineTools() \(name)")
            XCTAssertTrue(summary(name).contains("store_differs"), "mcpb/manifest.json \(name): \(summary(name))")
            for (place, text) in [("defineTools()", declared(name)), ("mcpb/manifest.json", summary(name))] {
                XCTAssertTrue(text.contains(warning), "\(place) \(name): \(text)")
            }
        }
        XCTAssertTrue(declared("undo").contains("names those fields"), declared("undo"))
        XCTAssertTrue(summary("undo").contains("names the fields"), summary("undo"))
    }

    /// The keys listed after "store_differs lists their keys, from ": backticked names joined by
    /// ", " or " and ", up to the first other text. Nil without that sentence.
    static func storeDiffersKeys(in text: String) -> [String]? {
        guard let start = text.range(of: "store_differs lists their keys, from ") else { return nil }
        var rest = text[start.upperBound...]
        var keys: [String] = []
        while rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
            keys.append(String(rest[rest.index(after: rest.startIndex)..<close]))
            rest = rest[rest.index(after: close)...]
            guard let separator = [", ", " and "].first(where: { rest.hasPrefix($0) && rest.dropFirst($0.count).hasPrefix("`") }) else { break }
            rest = rest.dropFirst(separator.count)
        }
        return keys
    }

    func testTheKeyListReaderStopsAtTheEndOfTheList() {
        XCTAssertEqual(Self.storeDiffersKeys(in: "x store_differs lists their keys, from `a`, `b c` and `d`, and note says `e`."), ["a", "b c", "d"])
        XCTAssertEqual(Self.storeDiffersKeys(in: "store_differs lists their keys, from `a` and `b`, and `c`"), ["a", "b"])
        XCTAssertNil(Self.storeDiffersKeys(in: "store_differs names `a`"))
    }

    /// #377 verify: the undo of a series created here whose first occurrence was deleted later is
    /// refused for good, so both places a client reads about undo list it where discard_id is the
    /// only choice.
    func testUndoDescriptionsNameTheSeriesWhoseFirstOccurrenceWasDeleted() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let declared = CheICalMCPServer.defineTools().first { $0.name == "undo" }?.description ?? ""
        let summary = entries.first { $0["name"] as? String == "undo" }?["description"] as? String ?? ""
        XCTAssertTrue(declared.contains("or a series whose rule was shortened or whose first occurrence was deleted later)"), declared)
        XCTAssertTrue(summary.contains("a series created here whose first occurrence was deleted later is refused until the user discards it"), summary)
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

    /// #332: the five range reads state the read bound, when it applies and its rate, in
    /// defineTools() and in the manifest; the two with an output default state that too, each with
    /// its own rows and where `default_limit` sits; the numbers are the constants.
    func testRangeReadToolsStateTheReadBound() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        func declared(_ name: String) -> String { CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? "" }
        func summary(_ name: String) -> String { entries.first { $0["name"] as? String == name }?["description"] as? String ?? "" }
        XCTAssertEqual(EventRangeQuery.maxEventsRead, 200_000)
        XCTAssertEqual(EventRangeQuery.defaultWideOutput, 500)
        XCTAssertEqual(EventRangeQuery.wideRangeDays, 1462)
        for name in ["list_events", "search_events", "check_conflicts", "find_duplicate_events", "delete_events_batch"] {
            XCTAssertTrue(declared(name).contains("1462 days"), "defineTools() \(name)")
            XCTAssertFalse(declared(name).contains("1461 days"), "defineTools() \(name)")
            XCTAssertTrue(declared(name).contains("about 200,000 event occurrences (about 2,000 a year over 100 years"), "defineTools() \(name): \(declared(name))")
            XCTAssertTrue(summary(name).contains("about 200,000 occurrences (about 2,000 a year over 100 years)"), "mcpb/manifest.json \(name): \(summary(name))")
            XCTAssertTrue(summary(name).contains("1462 days"), "mcpb/manifest.json \(name): \(summary(name))")
            XCTAssertFalse(summary(name).contains("1461 days"), "mcpb/manifest.json \(name): \(summary(name))")
            XCTAssertFalse(declared(name).contains("20,000 "), name)
        }
        for name in ["list_events", "search_events"] {
            XCTAssertTrue(declared(name).contains("limit does not lift it"), "defineTools() \(name)")
            XCTAssertTrue(declared(name).contains("truncated: true whenever fewer events are returned than event_count, a limit's cut included; event_count is still the total"), "defineTools() \(name): \(declared(name))")
            XCTAssertFalse(declared(name).contains("replaces the 500"), name)
            XCTAssertTrue(summary(name).contains("without limit at most 500 events are returned"), "mcpb/manifest.json \(name): \(summary(name))")
            XCTAssertTrue(summary(name).contains("truncated: true when fewer events are returned than event_count"), "mcpb/manifest.json \(name): \(summary(name))")
            let schema = "\(String(describing: CheICalMCPServer.defineTools().first { $0.name == name }?.inputSchema))"
            XCTAssertTrue(schema.contains("except over a range longer than 1462 days: at most 500"), "limit of \(name)")
            XCTAssertTrue(schema.contains("A limit does not lift the read bound"), "limit of \(name)")
        }
        XCTAssertTrue(declared("list_events").contains("the first in the requested sort, with metadata.default_limit"), declared("list_events"))
        XCTAssertTrue(declared("search_events").contains("Any such cut, on any range, keeps the events closest to today, sorted by start, and says so in truncation_note"), declared("search_events"))
        let searchSchema = "\(String(describing: CheICalMCPServer.defineTools().first { $0.name == "search_events" }?.inputSchema))"
        XCTAssertTrue(searchSchema.contains("Maximum number of events to return, at most 10000: those closest to today, sorted by start"), searchSchema)
        XCTAssertTrue(declared("search_events").contains("With only start_date or only end_date the other side stays two years from today, so such a range can be longer than 1462 days"), declared("search_events"))
        XCTAssertTrue(summary("search_events").contains("those closest to today"), summary("search_events"))
        // Only different calendars are compared, so one calendar is not a way out.
        XCTAssertTrue(declared("find_duplicate_events").contains("naming fewer calendars in calendar_names, at least two"), declared("find_duplicate_events"))
        XCTAssertFalse(declared("find_duplicate_events").contains("not reported"), "#437: such a name is refused now")
        XCTAssertTrue(declared("delete_events_batch").contains("give both after_date and before_date, at most 1460 days apart"), declared("delete_events_batch"))
    }

    /// #434: the five tools that take `recurrence` say that any other key is refused.
    func testRecurrenceToolsStateThatUnknownKeysAreRefused() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        for name in ["create_event", "create_events_batch", "update_event", "create_reminder", "update_reminder"] {
            let schema = "\(String(describing: CheICalMCPServer.defineTools().first { $0.name == name }?.inputSchema))"
            XCTAssertTrue(schema.contains("so a misspelled bound cannot leave the series open-ended"), "defineTools() \(name)")
            let summary = entries.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(summary.contains("unknown recurrence keys"), "mcpb/manifest.json \(name): \(summary)")
        }
    }

    /// #437: find_duplicate_events says what it does with calendar_names and what calendars_checked is.
    func testFindDuplicateEventsDescribesItsCalendars() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let tool = CheICalMCPServer.defineTools().first { $0.name == "find_duplicate_events" }
        let declared = tool?.description ?? ""
        XCTAssertTrue(declared.contains("A name that matches no calendar, or fewer than two calendars, is refused and nothing is returned"), declared)
        XCTAssertTrue(declared.contains("calendars_checked lists the calendars read"), declared)
        XCTAssertTrue(declared.contains("Each side of a pair gives calendar and calendar_source"), declared)
        let schema = "\(String(describing: tool?.inputSchema))"
        XCTAssertTrue(schema.contains("matched as the other tools match them"), schema)
        XCTAssertTrue(schema.contains("A name two accounts share reads both"), schema)
        XCTAssertTrue(schema.contains("not a label from calendars_checked"), schema)
        let summary = entries.first { $0["name"] as? String == "find_duplicate_events" }?["description"] as? String ?? ""
        XCTAssertTrue(summary.contains("calendar_names that match nothing, or fewer than two calendars, are refused"), summary)
    }

    /// #240: the three event read tools name `alarms` and its sign, in defineTools() and in the
    /// manifest, as the reminder read tools do (#231).
    func testEventReadToolsDescribeAlarms() throws {
        let sign = "positive = before the start, negative = after"
        // PR #410 verify round 1: an occurrence edited on its own reports its own alarms.
        let occurrence = "An occurrence reports the series' alarms unless it was edited on its own."
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        // check_conflicts formats its events with formatEventDict too (verify round 1).
        for name in ["list_events", "list_events_quick", "search_events", "check_conflicts"] {
            let declared = CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? ""
            XCTAssertTrue(declared.contains(sign), "defineTools() \(name): \(declared)")
            XCTAssertTrue(declared.contains("event lists its time-based alarms as alarms"), "defineTools() \(name)")
            XCTAssertTrue(declared.contains("location alarms are not listed"), "defineTools() \(name)")
            XCTAssertTrue(declared.contains(occurrence), "defineTools() \(name)")
            XCTAssertFalse(declared.contains("occurrences all report the series' alarms"), "defineTools() \(name)")
            let summary = entries.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(summary.contains(sign), "mcpb/manifest.json \(name): \(summary)")
        }
        for name in ["list_events", "list_events_quick", "search_events"] {
            let declared = CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? ""
            XCTAssertTrue(declared.contains("Outside detail_level summary each event lists its time-based alarms as alarms"), name)
        }
    }

    /// PR #410 verify round 1: the `fields` description of each event listing tool lists every
    /// field `fields` accepts (`InputValidation.validEventFields`, `id` always included), so a new
    /// field cannot be left out of it.
    func testEventFieldsDescriptionsListEveryValidField() throws {
        for name in ["list_events", "search_events", "list_events_quick"] {
            let schema = try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == name }?.inputSchema.objectValue)
            let fields = try XCTUnwrap(schema["properties"]?.objectValue?["fields"]?.objectValue?["description"]?.stringValue, name)
            let listed = try XCTUnwrap(fields.components(separatedBy: "Available: ").last, name)
            let names = Set(listed.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).components(separatedBy: ", "))
            XCTAssertEqual(names, InputValidation.validEventFields.subtracting(["id"]), "\(name): \(fields)")
        }
    }

    /// #241: both reminder read tools name `item_timezone` (the reminder's own zone, null when
    /// floating) and say what `timezone` names, in defineTools() and in the manifest.
    func testReminderReadToolsDescribeItemTimezone() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        for name in ["list_reminders", "search_reminders"] {
            let declared = CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? ""
            XCTAssertTrue(declared.contains("item_timezone (the reminder's own time zone; null when floating)"), "defineTools() \(name): \(declared)")
            XCTAssertTrue(declared.contains("timezone is the host time zone, the zone of the *_local strings"), "defineTools() \(name): \(declared)")
            let summary = entries.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(summary.contains("item_timezone (the reminder's own time zone, null when floating)"), "mcpb/manifest.json \(name): \(summary)")
        }
    }

    /// #386: the four event read tools name `item_timezone` (the event's own zone, null when
    /// floating) and say what `timezone` is, in defineTools() and in the manifest; the
    /// `detail_level` summary list and the `fields` list name the field too.
    func testEventReadToolsDescribeItemTimezone() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let tools = CheICalMCPServer.defineTools()
        for name in ["list_events", "search_events", "list_events_quick", "check_conflicts"] {
            let tool = tools.first { $0.name == name }
            let declared = tool?.description ?? ""
            XCTAssertTrue(declared.contains("item_timezone (the event's own time zone; null when floating, all-day events included)"), "defineTools() \(name): \(declared)")
            XCTAssertTrue(declared.contains("timezone is the event's time zone, or the host time zone when the event is floating"), "defineTools() \(name): \(declared)")
            let summary = entries.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(summary.contains("item_timezone (the event's own time zone, null when floating)"), "mcpb/manifest.json \(name): \(summary)")
            guard name != "check_conflicts" else { continue }
            let schema = "\(String(describing: tool?.inputSchema))"
            XCTAssertTrue(schema.contains("end_date_local, timezone, item_timezone, is_all_day, calendar — plus location when set"), "detail_level of \(name)")
            XCTAssertTrue(schema.contains("Available: title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day,"), "fields of \(name)")
        }
    }

    /// #383 verify: update_event's occurrence_date says which zone it is read in, for both forms,
    /// and the floating case; the description of the tool names occurrence_start; the manifest too.
    func testUpdateEventDescribesTheOccurrenceDateZone() throws {
        let tool = CheICalMCPServer.defineTools().first { $0.name == "update_event" }
        let schema = "\(String(describing: tool?.inputSchema))"
        XCTAssertTrue(schema.contains("Without an offset it is read in the event's current time zone, not in timezone (the zone the event gets); with an offset it is used as given, and its day is taken in the event's current time zone too. A floating or all-day series uses this Mac's time zone."), schema)
        XCTAssertTrue((tool?.description ?? "").contains("adds occurrence_start, the start of the occurrence occurrence_date matched"), tool?.description ?? "")
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let summary = entries.first { $0["name"] as? String == "update_event" }?["description"] as? String ?? ""
        XCTAssertTrue(summary.contains("occurrence_start for the occurrence occurrence_date matched"), summary)
    }

    /// #416: the writes refused through the identifier of an occurrence edited on its own say when,
    /// in both places a client reads about them, and update_event lists the cases that change the
    /// id as they were measured.
    func testTheWritesRefusedThroughAnOccurrenceIdentifierSaySo() throws {
        let update = try descriptions(of: "update_event")
        XCTAssertTrue(update.declared.contains("in four cases only"), update.declared)
        // #428 verify r1: the series' id reaching its first edited occurrence is the fourth case.
        XCTAssertTrue(update.declared.contains("span 'all' through the series' identifier, when the series' first occurrence was edited on its own and still starts at its original time, or was deleted with the first occurrence left edited on its own, goes through that occurrence's identifier and answers it after the save as occurrence_id"), update.declared)
        XCTAssertFalse(update.declared.contains("a known behavior"), update.declared)
        XCTAssertTrue(update.declared.contains("span 'all' with the identifier of an occurrence edited on its own would split the series while an earlier occurrence remains, so it is then refused and writes nothing (#416)"), update.declared)
        XCTAssertTrue(update.declared.contains("the first occurrence left, after the first was deleted"), update.declared)
        XCTAssertFalse(update.declared.contains("Use occurrence_id only with span 'this'"), update.declared)
        XCTAssertTrue(update.declared.contains("A series whose first occurrence was deleted has no whole-series update unless its first occurrence left was edited on its own (#326)."), update.declared)
        XCTAssertTrue(update.declared.contains("With span 'all' or 'future' through such an identifier, and with span 'all' through the series' identifier in the shape just named, title, notes, location and recurrence can be written (not recurrence with span 'all' after the series' first occurrence was deleted, through either identifier); start_time, end_time, all_day true, alarms, timezone, url and structured_location only in the shapes that were measured, which the refusal lists"), update.declared)
        XCTAssertTrue(update.declared.contains("all_day true there cannot be turned back through that identifier."), update.declared)
        XCTAssertTrue(update.declared.contains("On a series that has started, these routes take the started-series rules below (#451), as the series' identifier goes through that occurrence's own; timezone among them (#478)."), "after #471: \(update.declared)")
        XCTAssertFalse(update.declared.contains("refused once the series has started"), "the #428 refusal gave way to #451's rules: \(update.declared)")
        XCTAssertTrue(update.declared.contains("one field per call, or start_time with end_time, as a new time of day on the same date;"), "verify r2: \(update.declared)")
        XCTAssertFalse(update.declared.contains("while it has the series' time, length and day"), "verify r1: wider than what was measured: \(update.declared)")
        XCTAssertTrue(update.declared.contains("A title, notes or location the occurrence already holds is refused too, as it would reach no other occurrence, and so is a write that would start a new series from an occurrence holding its own location or alarms."), update.declared)
        XCTAssertFalse(update.declared.contains("recurrence, clear_recurrence"), update.declared)
        XCTAssertTrue(update.declared.contains("With span 'this' or 'future' occurrence_date must be that occurrence's day."), update.declared)
        XCTAssertFalse(update.declared.contains("with any span"), update.declared)
        XCTAssertTrue(update.summary.contains("with span all or future through it title, notes, location and recurrence can be written, dates and a few others only in the measured shapes the refusal lists"), update.summary)
        XCTAssertTrue(update.summary.contains("span all through the series' id goes through its first occurrence when that one was edited on its own, with occurrence_id"), update.summary)
        XCTAssertFalse(update.declared.contains("the series' earliest occurrence"), update.declared)
        XCTAssertTrue(update.summary.contains("span all through an occurrence edited on its own is refused while an earlier occurrence remains"), update.summary)
        let single = try descriptions(of: "delete_event")
        XCTAssertTrue(single.declared.contains("With span 'this' or 'future' through such an identifier occurrence_date must be that occurrence's day."), single.declared)
        // #428 verify r1: that delete cannot be undone, and the description no longer promises it.
        XCTAssertTrue(single.declared.contains("the response adds occurrence_id and undo_note, as that delete cannot be undone."), single.declared)
        XCTAssertTrue(single.declared.contains("(that case, or span 'all' outside the shape named above) recreates the series"), single.declared)
        XCTAssertTrue(single.summary.contains("span all through the series' id deletes from its first occurrence when that one was edited on its own, which cannot be undone"), single.summary)
        XCTAssertTrue(single.declared.contains("Span 'all' through the identifier of an occurrence edited on its own would delete that occurrence only, so it is refused and deletes nothing while another occurrence remains (#416)"), single.declared)
        XCTAssertTrue(single.summary.contains("span all through an occurrence edited on its own is refused while another occurrence remains"), single.summary)
        let batch = try descriptions(of: "delete_events_batch")
        XCTAssertTrue(batch.declared.contains("By event_ids, span all through the identifier of an occurrence edited on its own would delete that occurrence only, so while another occurrence the call does not name remains that row is refused, in the dry run too, and the other rows go on (#416)"), batch.declared)
        XCTAssertTrue(batch.summary.contains("span all through an occurrence edited on its own is refused for that row while another occurrence remains"), batch.summary)
        // By date range the same row is refused (#427).
        XCTAssertTrue(batch.declared.contains("By date range, with span all, an occurrence edited on its own is refused the same way, in the dry run too, while another occurrence of its series is not listed (#427)."), batch.declared)
        // #427 cluster verify: a listed series takes its edited occurrence.
        XCTAssertTrue(batch.declared.contains("When the series' own identifier is listed too and its row deletes on its own, an occurrence whose id has a /RID= part is left to that row, which deletes the series with it; otherwise the occurrence's row runs first, as by event_ids."), batch.declared)
    }

    /// #267: a bare `YYYY-MM-DD` due_date writes a date-only reminder, and a date-only update also
    /// removes absolute-date alarms; both places a client reads about the three writers say so.
    func testReminderWritersDescribeTheBareDateForm() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        func declared(_ name: String) -> String { CheICalMCPServer.defineTools().first { $0.name == name }?.description ?? "" }
        func summary(_ name: String) -> String { entries.first { $0["name"] as? String == name }?["description"] as? String ?? "" }
        for name in ["create_reminder", "create_reminders_batch", "update_reminder"] {
            for (place, text) in [("defineTools()", declared(name)), ("mcpb/manifest.json", summary(name))] {
                XCTAssertTrue(text.contains("YYYY-MM-DD") && text.contains("date-only"), "\(place) \(name): \(text)")
            }
        }
        XCTAssertTrue(declared("update_reminder").contains("absolute-date alarms are removed"), declared("update_reminder"))
        XCTAssertTrue(summary("update_reminder").contains("removes absolute-date alarms"), summary("update_reminder"))
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

    /// #295 (coordinator applied the diagnosis default A, 2026-11-05): redo staying
    /// instruction-only for creates, deletes, updates and moves is the design, not a gap, and both
    /// places a client reads about `redo` say so. Choosing to replay writes later is a contract
    /// change (Spectra), which this pin makes visible.
    func testRedoDescriptionsSayInstructionOnlyIsTheDesign() throws {
        let design = "does not replay a create, delete, update or move"
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let declared = CheICalMCPServer.defineTools().first { $0.name == "redo" }?.description ?? ""
        let summary = entries.first { $0["name"] as? String == "redo" }?["description"] as? String ?? ""
        for (place, text) in [("defineTools()", declared), ("mcpb/manifest.json", summary)] {
            XCTAssertTrue(text.contains(design) && text.contains("by design"), "\(place) redo: \(text)")
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
            ("#244 (#285): a series deleted whole comes back from its rules with its exceptions restored",
             "undo of a whole-series delete (delete_event span future from the first occurrence, or span all) recreates the series from its rules and then restores its exceptions inside the scan window",
             "a series deleted whole comes back from its rules with its exceptions inside the scan window restored"),
            ("#261: a single delete_reminder undo names the fields the store holds differently (the batch clause follows)",
             "the message names those fields and asks to check the reminder.",
             "when a delete_reminder undo recreates a reminder the store then holds differently, the message names the fields"),
            ("#248 (#261): a batch undo names the first five restored reminders whose store differs, then counts, finished or part-way",
             "A batch undo, whether it finishes or stops part-way, names the first five restored reminders whose store holds fields differently, with their fields, then says how many more.",
             "a batch undo names the first five restored reminders whose store holds fields differently, then how many more, also when it stops part-way;"),
            ("#236, #244, #273: the count of refusals that discard the record",
             "Six refusals discard the record instead",
             nil),
            ("#273: undo reverts the most recent recorded operation",
             "Undo the most recent recorded calendar or reminder operation",
             "Undo the most recent recorded operation"),
            ("#273: a calendar operation is recorded, refused and discarded, so the next undo reverts the operation before it",
             "a create_calendar, update_calendar or delete_calendar, which undo never reverts (its entry is recorded so that undo does not revert an older operation in its place; once it is discarded, the next undo reverts the operation recorded before it)",
             "create_calendar, update_calendar and delete_calendar are recorded but never undone: their undo is refused and the entry discarded, so the next undo reverts the operation recorded before it"),
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
            ("#269: an event's recorded calendar not found, the record kept",
             "The undo of a delete_event, an update_event or a move of an event is refused the same way, its record kept, when the calendar it restores into is not found under its recorded identifier (judged after a Calendar access check and one re-read of the calendars, which can still show an older view); the error names the event, not the calendar or its account",
             "likewise when an event's recorded calendar is not found"),
            ("#269: a missing calendar is refused before the repeats-now discard, the record kept",
             "an update_event or a move of a one-off event that repeats or is an edited occurrence by the time of the undo (revert either in Calendar if wanted; the calendar it restores into is read first, so when that calendar is missing the missing-calendar refusal comes first and the record is kept)",
             nil),
            ("#269: giving up a delete_event undo loses the event",
             "giving up the undo of a delete_event loses the deleted event",
             "discarding a delete_event undo loses the deleted event"),
        ]
        let (declared, summary) = try descriptions(of: "undo")
        // Round 7, findings 4, 8, 12, 13: after the five-entry cap no text may say a batch undo names
        // "each" such reminder.
        XCTAssertFalse(declared.contains("names each") || summary.contains("names each"), declared + summary)
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

    /// #273: the calendar tools say their undo is refused and what the next undo then reverts, and
    /// a plain copy says its undo deletes the copy; in both places a client reads them.
    func testCalendarToolsAndCopyEventSayWhatTheirUndoDoes() throws {
        let clauses: [(tool: String, declared: String, summary: String)] = [
            ("create_calendar", "undo of it is refused and its entry discarded", "undo is refused"),
            ("update_calendar", "undo of it is refused and its entry discarded", "undo is refused"),
            ("delete_calendar", "not undoable: it deletes every event or reminder in the calendar", "cannot be undone"),
            ("delete_calendar", "undo of it is refused and its entry discarded", "undo is refused"),
            ("copy_event", "undo of a copy deletes the copy", "undo deletes the copy"),
        ]
        for clause in clauses {
            let (declared, summary) = try descriptions(of: clause.tool)
            XCTAssertTrue(declared.contains(clause.declared), "defineTools() \(clause.tool) lost: \(clause.declared)\n\(declared)")
            XCTAssertTrue(summary.contains(clause.summary), "mcpb/manifest.json \(clause.tool) lost: \(clause.summary)\n\(summary)")
        }
        for tool in ["create_calendar", "update_calendar", "delete_calendar"] {
            let (declared, summary) = try descriptions(of: tool)
            for (place, text) in [("defineTools()", declared), ("mcpb/manifest.json", summary)] {
                XCTAssertTrue(text.contains("next undo reverts the operation recorded before it"), "\(place) \(tool): \(text)")
            }
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

    /// #285: undo of a whole-series delete recreates the series from its rules and restores its
    /// exceptions inside the scan window: an occurrence deleted on its own earlier stays deleted,
    /// one edited on its own comes back as a separate one-off event, and exceptions outside the
    /// window come back from the rules alone. Every place a client reads about the undo before it
    /// runs states it in the same words (#244 verify rounds 4-6: the manifest summary too), and
    /// none keeps the earlier claim that an occurrence deleted on its own comes back and an edit is
    /// lost, or the "not yet checked" hedge that went with it. The negative checks catch those
    /// phrases only, not every rewording: the positive clauses are the guard.
    func testUndoSurfacesSayAWholeSeriesRestoreKeepsItsExceptions() throws {
        let restored = "an occurrence deleted on its own earlier stays deleted, one edited on its own comes back as a separate one-off event"
        let window = "exceptions outside that window"
        // PR #318 verify round 3: the limits clients cannot see otherwise are stated before the undo.
        let limits = ["first occurrence", "more than a year outside the window", "does not match the recreated series"]
        let retired = ["adds it a second time", "not yet checked with span", "comes back without its edit"]
        let backwards = "without the occurrences"
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        let declared = CheICalMCPServer.defineTools()
        for name in ["delete_event", "delete_events_batch", "undo"] {
            let description = declared.first { $0.name == name }?.description ?? ""
            XCTAssertTrue(description.contains(restored), "defineTools() \(name): \(description)")
            XCTAssertTrue(description.lowercased().contains(window), "defineTools() \(name) lost the window limit: \(description)")
            for limit in limits { XCTAssertTrue(description.contains(limit), "defineTools() \(name) lost the limit: \(limit)") }
            for phrase in retired { XCTAssertFalse(description.contains(phrase), "defineTools() \(name) still says: \(phrase)") }
        }
        let summary = entries.first { $0["name"] as? String == "undo" }?["description"] as? String ?? ""
        XCTAssertTrue(summary.contains(restored), "mcpb/manifest.json undo: \(summary)")
        XCTAssertTrue(summary.lowercased().contains(window), "mcpb/manifest.json undo lost the window limit: \(summary)")
        for limit in limits { XCTAssertTrue(summary.contains(limit), "mcpb/manifest.json undo lost the limit: \(limit)") }
        for phrase in retired { XCTAssertFalse(summary.contains(phrase), "mcpb/manifest.json undo still says: \(phrase)") }
        for tool in declared {
            XCTAssertFalse((tool.description ?? "").contains(backwards), "defineTools() \(tool.name)")
        }
        for entry in entries {
            XCTAssertFalse((entry["description"] as? String ?? "").contains(backwards), "mcpb/manifest.json \(entry["name"] ?? "")")
        }
    }

    /// #391 (PR #394 verify round 1): every parameter that names an occurrence by date says that it
    /// is the day the occurrence starts on, and what a date or time inside an overnight occurrence
    /// does. `update_event`'s keeps #392's zone wording too (`testUpdateEventDescribesTheOccurrenceDateZone`).
    func testOccurrenceDateParametersNameTheStartDay() throws {
        func descriptions(of key: String, in value: Value) -> [String] {
            guard let object = value.objectValue else {
                return value.arrayValue?.flatMap { descriptions(of: key, in: $0) } ?? []
            }
            var found: [String] = []
            if let property = object["properties"]?.objectValue?[key]?.objectValue?["description"]?.stringValue { found.append(property) }
            for (_, child) in object { found += descriptions(of: key, in: child) }
            return found
        }
        let tools = CheICalMCPServer.defineTools()
        let cases: [(tool: String, key: String, count: Int)] = [
            ("update_event", "occurrence_date", 1),
            ("delete_event", "occurrence_date", 1),
            ("move_events_batch", "occurrence_dates", 1),
            ("create_event", "excluded_occurrence_dates", 1),
            ("create_events_batch", "excluded_occurrence_dates", 1),
        ]
        for (name, key, count) in cases {
            let schema = try XCTUnwrap(tools.first { $0.name == name }?.inputSchema, name)
            let found = Array(Set(descriptions(of: key, in: schema)))
            XCTAssertEqual(found.count, count, "\(name).\(key): \(found)")
            for text in found {
                XCTAssertTrue(text.contains("the day the occurrence starts on"), "\(name).\(key): \(text)")
                XCTAssertTrue(text.contains("runs past midnight"), "\(name).\(key): \(text)")
            }
        }
        for key in ["occurrence_date", "occurrence_dates"] {
            for text in [("update_event", key), ("delete_event", key), ("move_events_batch", key)].flatMap({ pair in
                descriptions(of: pair.1, in: tools.first { $0.name == pair.0 }!.inputSchema) }) {
                XCTAssertTrue(text.contains("selects the occurrence starting on that following day"), text)
            }
        }
        for name in ["create_event", "create_events_batch"] {
            for text in descriptions(of: "excluded_occurrence_dates", in: tools.first { $0.name == name }!.inputSchema) {
                XCTAssertTrue(text.contains("rolled back"), "\(name): \(text)")
            }
        }
    }

    /// PR #415 verify round 2: update_reminder says when `alarms_note` appears, in its description,
    /// in its `alarms_minutes_offsets` parameter and in the manifest summary.
    func testUpdateReminderDescribesTheLeftoverAlarmsNote() throws {
        let tool = try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == "update_reminder" })
        let declared = tool.description ?? ""
        XCTAssertTrue(declared.contains("alarms_note"), declared)
        XCTAssertTrue(declared.contains("keeps relative alarms"), declared)
        let parameter = tool.inputSchema.objectValue?["properties"]?.objectValue?["alarms_minutes_offsets"]?.objectValue?["description"]?.stringValue ?? ""
        XCTAssertTrue(parameter.contains("alarms_note"), parameter)
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let summary = (manifest?["tools"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "update_reminder" }?["description"] as? String ?? ""
        XCTAssertTrue(summary.contains("alarms_note"), summary)
    }

    /// #433: the manifest says what Reminders.app's list shows for each tool that writes the offsets.
    func testTheManifestDescribesTheAlarmDisplay() throws {
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = manifest?["tools"] as? [[String: Any]] ?? []
        for name in ["create_reminder", "update_reminder", "create_reminders_batch"] {
            let summary = tools.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(summary.contains("earliest alarm time"), "\(name): \(summary)")
            XCTAssertTrue(summary.contains("not the due time"), "\(name): \(summary)")
            XCTAssertTrue(summary.contains("the one notification checked showed it too"), "\(name): \(summary)")
            XCTAssertTrue(summary.contains("when the earliest alarm is off the due time"), "\(name): \(summary)")
            XCTAssertTrue(summary.contains("alarms_note"), "\(name): \(summary)")
        }
    }

    /// PR #420 verify round 1: update_reminder names recurrence and clear_recurrence, and that a
    /// rule change does not move the due date, in its description and its manifest summary.
    func testUpdateReminderDescribesTheRecurrenceChange() throws {
        let declared = CheICalMCPServer.defineTools().first { $0.name == "update_reminder" }?.description ?? ""
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let summary = (manifest?["tools"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "update_reminder" }?["description"] as? String ?? ""
        for (place, text) in [("defineTools()", declared), ("mcpb/manifest.json", summary)] {
            XCTAssertTrue(text.contains("clear_recurrence"), "\(place): \(text)")
            XCTAssertTrue(text.contains("does not move the due date"), "\(place): \(text)")
            XCTAssertTrue(text.contains("recurrence_note"), "\(place): \(text)")
        }
    }

    /// PR #425 verify (#423): complete_reminder says what it reports after a rollover, in both places.
    func testCompleteReminderDescribesTheRolloverAlarms() throws {
        let declared = CheICalMCPServer.defineTools().first { $0.name == "complete_reminder" }?.description ?? ""
        let data = try Data(contentsOf: try locateManifest())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let summary = (manifest?["tools"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "complete_reminder" }?["description"] as? String ?? ""
        for (place, text) in [("defineTools()", declared), ("mcpb/manifest.json", summary)] {
            XCTAssertTrue(text.contains("alarms_minutes_offsets"), "\(place): \(text)")
            XCTAssertTrue(text.contains("alarms_note"), "\(place): \(text)")
        }
    }
}
