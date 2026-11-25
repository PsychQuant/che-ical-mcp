// MARK: - Dispatch round-trip tests (#131 — re-enabled in CI)
//
// Until #575 the two `executeToolCall(...)` tests drove a default `CheICalMCPServer()`, whose
// handlers call `EventKitManager.shared` (real EventKit). Historically these hung on
// GHA macos sandboxed runners: with no TCC grants, `AuthorizationGate.ensureAccess`
// called `requestFullAccess` for `.notDetermined` even in a non-interactive session,
// blocking forever on a TCC dialog that can never appear (local macOS returns `.denied`
// synchronously, which masked the bug). The whole class — including the structural
// `testDefinedToolsHaveUniqueNames` — was compile-excluded under `-DCI_BUILD`.
//
// #131 RESOLVED: the gate now fast-fails in non-interactive sessions, so these
// real-server dispatch tests return promptly (handler throws `accessDenied`) instead
// of hanging. The `-DCI_BUILD` guard is removed and the class runs in CI again.
//
// #575: they no longer build the server with its default sources. Where the test process has
// Calendar and Reminders access, `list_calendars`, `cleanup_completed_reminders` and the other
// tools that need no argument read the developer's real stores. The server is now built with
// `DispatchProbe` for every source and a fresh undo history, so no dispatch with these arguments
// reaches a live store whatever access the process has (`delete_reminder` with a `reminder_id`
// would: it calls the live manager directly, and no test dispatches it so), and a handler that is
// reached shows up in the probe's calls.

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
/// intact. Any other error (missing required parameter, the probe's
/// `Reached`, …) is fine and expected — those errors prove the dispatch
/// reached a handler.
final class DispatchRoundTripTests: XCTestCase {

    func testEveryDeclaredToolIsDispatched() async throws {
        let tools = CheICalMCPServer.defineTools()
        XCTAssertFalse(tools.isEmpty, "defineTools() returned an empty list")

        let probe = DispatchProbe()
        let server = try await DispatchProbe.server(probe)
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
                // Non-ToolError failures (the probe's `Reached`, NSError from
                // Foundation, etc.) also prove dispatch reached the handler.
            }
        }

        XCTAssertTrue(
            undispatched.isEmpty,
            "Tools declared in defineTools() but not dispatched in executeToolCall: \(undispatched)"
        )
        // #575: the tools that need no argument reached the probe, not a live store.
        let calls = await probe.calls
        XCTAssertTrue(calls.contains("listCalendarValues"), "list_calendars reached its source: \(calls)")
        XCTAssertTrue(calls.contains("listCompletedReminderIdentifiers"), "cleanup_completed_reminders reached its source: \(calls)")
    }

    /// Specific pin: #21 introduced `cleanup_completed_reminders`. Without
    /// this test, a rename at either site that broke the link would pass
    /// all other tests.
    func testCleanupCompletedRemindersIsDispatched() async throws {
        let probe = DispatchProbe()
        let server = try await DispatchProbe.server(probe)
        do {
            _ = try await server.executeToolCall(name: "cleanup_completed_reminders", arguments: [:])
        } catch ToolError.unknownTool(let name) {
            XCTFail("cleanup_completed_reminders is not dispatched; executeToolCall returned unknownTool(\(name))")
        } catch {
            // Expected — the handler runs and the probe throws `Reached`.
        }
        // #575: its default dry run asked the probe for the completed reminders, not the live store.
        let calls = await probe.calls
        XCTAssertEqual(calls, ["listCompletedReminderIdentifiers"])
    }

    /// #575: the server's one store call that does not go through an injected source is
    /// `deleteReminder`, behind the `reminder_id` guard, so a dispatch with empty arguments cannot
    /// reach it. Pinned on the source; a new direct call would make the dispatch tests reach a live
    /// store again.
    func testTheServerHasNoOtherDirectStoreCall() throws {
        let server = SourcePins.code(try SourcePins.source("Server.swift"))
        // PR #601 verify r1: the bare identifier, so a pass-on, an alias or a call across a line break
        // counts too, in code read with the code inside string interpolation kept (`SourceScan.codeOnly`).
        let serverCode = SourceScan.codeOnly(try SourcePins.source("Server.swift"))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\beventKitManager\b"#, in: serverCode).count, 2,
                       "its declaration and the delete_reminder call")
        XCTAssertEqual(SourcePins.ranges(of: "private let eventKitManager = EventKitManager.shared", in: serverCode).count, 1)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"EKEventStore\(|CountingEventStore\("#, in: serverCode).count, 0, "no store of its own")
        let handler = try XCTUnwrap(SourcePins.body(of: "private func handleDeleteReminder(arguments: [String: Value]) async throws -> String {", in: server))
        let guardRange = try XCTUnwrap(handler.range(of: "guard let reminderId = arguments["), "string literals are blanked by SourcePins.code")
        let call = try XCTUnwrap(handler.range(of: "try await eventKitManager.deleteReminder(identifier: reminderId)"))
        XCTAssertLessThan(guardRange.lowerBound, call.lowerBound)
    }

    /// PR #601 verify r1: every source the init defaults to `EventKitManager.shared` is one
    /// `DispatchProbe.server` replaces, and `EventKitManager.shared` appears in `Server.swift` only
    /// as those defaults and the `eventKitManager` property: a new source left at its default, or the
    /// manager passed on or bound to a local, makes this fail. The undo history is passed too.
    func testTheProbeServerReplacesEverySourceTheInitDefaultsToTheLiveManager() throws {
        let serverCode = SourceScan.codeOnly(try SourcePins.source("Server.swift"))
        let initSignature = try XCTUnwrap(SourceScan.arguments(of: "init(reminderCleanupSource:", in: serverCode).map { "reminderCleanupSource:" + $0 })
        let defaulted = Set(SourcePins.ranges(ofPattern: #"([A-Za-z]+): any [A-Za-z]+ = EventKitManager\.shared"#, in: initSignature)
            .map { String(initSignature[$0].prefix { $0 != ":" }) })
        XCTAssertEqual(defaulted.count, 14, "\(defaulted.sorted())")
        let shared = SourcePins.ranges(of: "EventKitManager.shared", in: serverCode).count
        XCTAssertEqual(shared, defaulted.count + 1, "the defaults and the eventKitManager property only")
        XCTAssertTrue(initSignature.contains("undoManager: CalendarUndoManager = .shared"))

        let probe = SourceScan.codeOnly(try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Helpers/DispatchProbe.swift"), encoding: .utf8))
        let call = try XCTUnwrap(SourceScan.arguments(of: "try await CheICalMCPServer(", in: probe))
        let passed = Set(SourcePins.ranges(ofPattern: #"([A-Za-z]+): probe\b"#, in: call).map { String(call[$0].prefix { $0 != ":" }) })
        XCTAssertEqual(passed, defaulted, "every defaulted source is replaced by the probe")
        XCTAssertTrue(call.contains("undoManager: CalendarUndoManager()"), "a fresh undo history, not the shared one")
    }

    /// PR #601 verify r1: outside `EventKitManager.swift` and `Server.swift` (counted above), no Sources
    /// file reaches the live manager or makes a store in its code, apart from these, which a dispatch
    /// does not run: the setup flow, the authorization status source, and `NewObjectSave`'s fresh store,
    /// made only inside the manager after one of its own saves (each an `EKEventStore()`).
    func testNoOtherSourcesFileReachesTheLiveManagerOrMakesAStore() throws {
        var found: [String: Int] = [:]
        for file in try SourceScan.swiftFiles() {
            let name = file.lastPathComponent
            guard name != "EventKitManager.swift", name != "Server.swift" else { continue }
            let code = SourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            let count = SourcePins.ranges(ofPattern: #"EventKitManager\.shared|EKEventStore\(|CountingEventStore\("#, in: code).count
            if count > 0 { found[name] = count }
        }
        XCTAssertEqual(found, ["SetupRunner.swift": 1, "AuthorizationStatusSource.swift": 1, "NewObjectSave.swift": 1])
    }

    /// PR #601 verify r1: the one dispatch of `delete_reminder` in the tests is the empty one above, so
    /// no test reaches its direct live call (`eventKitManager.deleteReminder`).
    func testNoTestDispatchesDeleteReminderWithAnIdentifier() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let tool = "delete_" + "reminder"
        var dispatches: [String] = []
        for file in try SourceScan.swiftFiles(under: tests) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("name: \"" + tool + "\"") {
                dispatches.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(dispatches, ["DispatchRoundTripTests.swift: _ = try await server.executeToolCall(name: \"" + tool + "\", arguments: [:])"])
    }

    /// The same, at run time: `delete_reminder` with no `reminder_id` is refused before the call.
    func testDeleteReminderWithoutAnIdentifierIsRefusedBeforeTheStore() async throws {
        let server = try await DispatchProbe.server(DispatchProbe())
        do {
            _ = try await server.executeToolCall(name: "delete_reminder", arguments: [:])
            XCTFail("delete_reminder took no reminder_id")
        } catch ToolError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("reminder_id"), message)
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
