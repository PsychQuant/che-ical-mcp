import CheMCPKit
import Foundation

/// The values this server passes to che-mcp-kit-swift (#223). Kept out of `main.swift` so
/// `KitConfigurationTests` can pin them.
enum KitConfiguration {
    /// Executable name shown in `--cli` usage errors.
    static let usageName = AppVersion.name

    /// Developer ID team every released binary is signed by.
    static let teamID = "6W377FS7BS"

    static func selfUpdate(currentVersion: String = AppVersion.current) -> SelfUpdate.Configuration {
        SelfUpdate.Configuration(
            owner: "PsychQuant", repository: "che-ical-mcp", assetName: AppVersion.name,
            displayName: AppVersion.name, currentVersion: currentVersion,
            verifier: SystemSignatureVerifier(expectedTeamID: teamID))
    }

    /// This server's `--cli` error line, `{"error":true,"message":"<code>"}` (#37 verify), which
    /// predates the package's `{"error":{"code","message"}}` envelope and is kept so scripts that
    /// parse `--cli` output keep working. The code is `EventKitErrorSanitizer`'s, so EventKit
    /// errors still read `eventkit_error_<N>`. Returns `(jsonMessage, rawLog)`.
    static func formatCLIError(_ error: Error) -> (jsonMessage: String, rawLog: String) {
        let sanitized = EventKitErrorSanitizer.sanitizeForResponse(error)
        let errorJSON: [String: Any] = [
            "error": true,
            "message": sanitized.code,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: errorJSON, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8)
        {
            return (str, sanitized.rawLog)
        }
        let escaped = sanitized.code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return ("{\"error\":true,\"message\":\"\(escaped)\"}", sanitized.rawLog)
    }
}
