import Foundation

/// Centralized version management
enum AppVersion {
    /// Current version - update this when releasing
    static let current = "1.13.0"

    /// App name — the on-disk binary / product name, shown in `--version`,
    /// `--help` usage lines, and used as the argv0 fallback. Must match the
    /// executable's actual filename (`CheICalMCP`), NOT the manifest id.
    static let name = "CheICalMCP"

    /// MCP protocol server identity (`serverInfo.name`). MUST equal
    /// `mcpb/manifest.json` `name` so Claude Desktop's tool-injection layer can
    /// reconcile the running server against its extension id — a mismatch makes
    /// Desktop 1.18286.0 silently drop the entire server from conversations
    /// (#166). Distinct from `name` above, which is the binary/product name.
    static let mcpServerName = "che-ical-mcp"

    /// Full display name
    static let displayName = "macOS Calendar & Reminders MCP Server"

    /// Version string for display
    static var versionString: String {
        "\(name) \(current)"
    }

    /// Help message
    static var helpMessage: String {
        """
        \(displayName)

        Usage: \(name) [options]
               \(name) --cli <tool> [--key value ...]
               echo '{"tool":"...","arguments":{}}' | \(name) --cli

        Options:
          --version, -v    Show version information
          --help, -h       Show this help message
          --setup          Request Calendar & Reminders permissions and exit.
                           Run this once from Terminal before using with launchd
                           or other non-interactive environments.
          --print-tcc-path Print binary's runtime path, bundle ID, current TCC
                           authorization status, and ready-to-paste tccutil/sqlite3
                           commands. Diagnostic helper for .mcpb-installed users
                           who need to locate the extracted binary for --setup.
          --self-update    Check GitHub Releases for a newer binary, download
                           and install it at the current binary's path. Use
                           when an existing install needs to upgrade — wrapper
                           auto-download covers fresh-install only (#49).
          --cli <tool>     Run a tool directly without MCP server.
                           Pass arguments as --key value pairs, or pipe JSON via stdin.

        Version: \(current)
        Repository: https://github.com/PsychQuant/che-ical-mcp
        """
    }
}
