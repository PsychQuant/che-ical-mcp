import EventKit
import Foundation
import MCP

// Handle command line arguments
if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print(AppVersion.versionString)
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(AppVersion.helpMessage)
    exit(0)
}

if CommandLine.arguments.contains("--self-update") {
    do {
        try await SelfUpdate.run()
        exit(0)
    } catch {
        // SelfUpdateError conforms to TrustedErrorMessage — its
        // localizedDescription is hand-written and safe to print.
        let message = (error as? LocalizedError)?.errorDescription
                      ?? error.localizedDescription
        FileHandle.standardError.write(Data("Self-update failed: \(message)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--setup") {
    // Warn if running in a non-interactive environment where TCC dialogs cannot appear
    if ProcessInfo.processInfo.environment["TERM"] == nil || getppid() == 1 {
        print("WARNING: --setup appears to be running in a non-interactive session.")
        print("Permission dialogs cannot appear here. Run this command from Terminal.app instead.\n")
    }

    print("CheICalMCP Setup — Requesting Calendar & Reminders permissions...")
    print("(This triggers macOS TCC permission dialogs for this binary)\n")

    let store = EKEventStore()

    // Request Calendar access
    do {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            print("Calendar access: \(granted ? "✓ granted" : "✗ denied")")
        } else {
            let granted = try await store.requestAccess(to: .event)
            print("Calendar access: \(granted ? "✓ granted" : "✗ denied")")
        }
    } catch {
        print("Calendar access: ✗ error — \(error.localizedDescription)")
    }

    // Request Reminders access
    do {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToReminders()
            print("Reminders access: \(granted ? "✓ granted" : "✗ denied")")
        } else {
            let granted = try await store.requestAccess(to: .reminder)
            print("Reminders access: \(granted ? "✓ granted" : "✗ denied")")
        }
    } catch {
        print("Reminders access: ✗ error — \(error.localizedDescription)")
    }

    print("\nIf permissions were denied, grant them manually:")
    print("  System Settings → Privacy & Security → Calendar → enable CheICalMCP")
    print("  System Settings → Privacy & Security → Reminders → enable CheICalMCP")
    exit(0)
}

// CLI mode: invoke tools directly without MCP server
if CommandLine.arguments.contains("--cli") {
    let server = try await CheICalMCPServer()
    await CLIRunner.run(server: server, args: CommandLine.arguments)
    exit(0)
}

// MCP server mode (default)
let server = try await CheICalMCPServer()
try await server.run()
