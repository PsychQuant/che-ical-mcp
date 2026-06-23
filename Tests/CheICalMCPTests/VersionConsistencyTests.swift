import XCTest
@testable import CheICalMCP

/// Guards single-version consistency across every distribution artifact (#163
/// co-locate-plugin-marketplace, task 3.1). `AppVersion.current` is the source of
/// truth; the four shipped artifacts MUST match it, or users get a mix of versions
/// across the Claude Desktop (`.mcpb`) and Claude Code (self-hosted marketplace)
/// channels. The release `scripts/build-mcpb.sh` enforces the same invariant at build
/// time (fail-fast before notarization); this test surfaces drift in CI / `swift test`
/// without a full build.
///
/// Artifacts checked (all relative to repo root):
/// - `Sources/CheICalMCP/Info.plist` → `CFBundleVersion`
/// - `mcpb/manifest.json` → `version`
/// - `.claude-plugin/marketplace.json` → `che-ical-mcp` plugin entry `version`
/// - `plugin/.claude-plugin/plugin.json` → `version`
final class VersionConsistencyTests: XCTestCase {

    /// Walk up from this test file to the directory containing `Package.swift`.
    /// Marker-based (not a fixed `deletingLastPathComponent` count) so it survives the
    /// test moving into `Tests/CheICalMCPTests/Helpers/` (CLAUDE.md #83).
    private func repoRoot() throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        throw XCTSkip("Could not locate Package.swift above \(#filePath)")
    }

    private func infoPlistVersion(_ root: URL) throws -> String {
        let url = root.appendingPathComponent("Sources/CheICalMCP/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any],
              let v = dict["CFBundleVersion"] as? String else {
            throw XCTSkip("CFBundleVersion not found in Info.plist")
        }
        return v
    }

    private func jsonString(_ root: URL, _ relativePath: String, _ extract: ([String: Any]) -> String?) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = extract(obj) else {
            throw XCTSkip("Could not extract version from \(relativePath)")
        }
        return v
    }

    func testAllDistributionArtifactsMatchAppVersion() throws {
        let root = try repoRoot()
        let source = AppVersion.current

        let plistVersion = try infoPlistVersion(root)
        XCTAssertEqual(plistVersion, source,
            "Info.plist CFBundleVersion (\(plistVersion)) != AppVersion.current (\(source))")

        let mcpbVersion = try jsonString(root, "mcpb/manifest.json") { $0["version"] as? String }
        XCTAssertEqual(mcpbVersion, source,
            "mcpb/manifest.json version (\(mcpbVersion)) != AppVersion.current (\(source))")

        let pluginVersion = try jsonString(root, "plugin/.claude-plugin/plugin.json") { $0["version"] as? String }
        XCTAssertEqual(pluginVersion, source,
            "plugin/.claude-plugin/plugin.json version (\(pluginVersion)) != AppVersion.current (\(source))")

        let mktplVersion = try jsonString(root, ".claude-plugin/marketplace.json") { obj in
            guard let plugins = obj["plugins"] as? [[String: Any]] else { return nil }
            return plugins.first(where: { ($0["name"] as? String) == "che-ical-mcp" })?["version"] as? String
        }
        XCTAssertEqual(mktplVersion, source,
            ".claude-plugin/marketplace.json che-ical-mcp entry version (\(mktplVersion)) != AppVersion.current (\(source))")
    }
}
