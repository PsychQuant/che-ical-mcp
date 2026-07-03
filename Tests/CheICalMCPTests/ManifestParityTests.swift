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
}
