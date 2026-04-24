import XCTest
import MCP
@testable import CheICalMCP

/// Guards against tool-name drift between `Server.defineTools()` and the
/// `executeToolCall` dispatch switch. Previously a one-character typo in
/// either site (e.g. renaming `cleanup_completed_reminders` in the tool
/// declaration but forgetting the switch case) would compile cleanly and
/// pass `swift test`, because no existing test exercised the dispatch
/// round-trip.
///
/// Strategy: call `executeToolCall` with empty arguments for every
/// declared tool. The only failure we care about is
/// `ToolError.unknownTool`, which proves the name→handler routing is
/// intact. Any other error (missing required parameter, permission
/// denied, EventKit access revoked in CI, …) is fine and expected —
/// those errors prove the dispatch reached a handler.
final class DispatchRoundTripTests: XCTestCase {

    func testEveryDeclaredToolIsDispatched() async throws {
        let tools = CheICalMCPServer.defineTools()
        XCTAssertFalse(tools.isEmpty, "defineTools() returned an empty list")

        let server = try await CheICalMCPServer()
        var undispatched: [String] = []

        for tool in tools {
            do {
                _ = try await server.executeToolCall(name: tool.name, arguments: [:])
            } catch let error as ToolError {
                if case .unknownTool(let name) = error {
                    undispatched.append(name)
                }
                // Any other ToolError is expected — missing required args,
                // invalid params, etc. Those prove the handler was reached.
            } catch {
                // Non-ToolError failures (EventKit permission denied in CI,
                // NSError from Foundation, etc.) also prove dispatch reached
                // the handler. Not our concern.
            }
        }

        XCTAssertTrue(
            undispatched.isEmpty,
            "Tools declared in defineTools() but not dispatched in executeToolCall: \(undispatched)"
        )
    }

    /// Specific pin: #21 introduced `cleanup_completed_reminders`. Without
    /// this test, a rename at either site that broke the link would pass
    /// all other tests.
    func testCleanupCompletedRemindersIsDispatched() async throws {
        let server = try await CheICalMCPServer()
        do {
            _ = try await server.executeToolCall(name: "cleanup_completed_reminders", arguments: [:])
        } catch ToolError.unknownTool(let name) {
            XCTFail("cleanup_completed_reminders is not dispatched; executeToolCall returned unknownTool(\(name))")
        } catch {
            // Expected — handler runs and throws (permission denied, etc.).
        }
    }

    func testDefinedToolsHaveUniqueNames() {
        let names = CheICalMCPServer.defineTools().map { $0.name }
        let uniqued = Set(names)
        XCTAssertEqual(
            names.count,
            uniqued.count,
            "Duplicate tool names detected — every Tool.name must be unique"
        )
    }
}
