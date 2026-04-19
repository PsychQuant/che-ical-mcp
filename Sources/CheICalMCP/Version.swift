import Foundation

/// Centralized version management
enum AppVersion {
    /// Current version - update this when releasing
    static let current = "1.7.0"

    /// App name
    static let name = "CheICalMCP"

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
          --cli <tool>     Run a tool directly without MCP server.
                           Pass arguments as --key value pairs, or pipe JSON via stdin.

        Version: \(current)
        Repository: https://github.com/PsychQuant/che-ical-mcp
        """
    }
}
