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
}
