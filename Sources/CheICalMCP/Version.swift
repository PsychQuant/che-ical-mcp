import Foundation

/// Centralized version management
enum AppVersion {
    /// Current version - update this when releasing
    static let current = "1.2.0"

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

        Options:
          --version, -v    Show version information
          --help, -h       Show this help message

        Version: \(current)
        Repository: https://github.com/kiki830621/che-ical-mcp
        """
    }
}
