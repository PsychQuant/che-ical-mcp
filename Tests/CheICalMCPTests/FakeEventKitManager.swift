import Foundation
@testable import CheICalMCP

/// Scriptable test double for `EventKitManaging`.
///
/// Each test instantiates its own fake, scripts the return values it cares
/// about, and (after the handler runs) inspects recorded invocations. The
/// fake is an `actor` to mirror `EventKitManager` and satisfy `Sendable`.
///
/// Usage:
/// ```swift
/// let fake = FakeEventKitManager()
/// await fake.scriptCompletedReminderIdentifiers(["r1", "r2"])
/// let server = try await CheICalMCPServer(reminderCleanupSource: fake)
/// _ = try await server.executeToolCall(name: "cleanup_completed_reminders",
///                                      arguments: ["dry_run": .bool(true)])
/// let calls = await fake.listCompletedReminderIdentifiersCalls
/// XCTAssertEqual(calls.count, 1)
/// ```
actor FakeEventKitManager: EventKitManaging {

    // MARK: - Scripted returns

    private var scriptedIdentifiers: [String] = []
    private var scriptedListError: Error?
    private var scriptedDeleteResult: BatchDeleteResult?
    private var scriptedDeleteError: Error?
    private var scriptedAccessError: Error?

    // MARK: - Recorded invocations

    struct ListCall: Sendable, Equatable {
        let calendarName: String?
        let calendarSource: String?
    }

    struct DeleteCall: Sendable, Equatable {
        let identifiers: [String]
        let onlyCompleted: Bool
    }

    private(set) var listCompletedReminderIdentifiersCalls: [ListCall] = []
    private(set) var deleteRemindersBatchCalls: [DeleteCall] = []
    private(set) var requestReminderAccessCallCount: Int = 0

    // MARK: - Scripting API

    func scriptCompletedReminderIdentifiers(_ identifiers: [String]) {
        scriptedIdentifiers = identifiers
    }

    func scriptListError(_ error: Error) {
        scriptedListError = error
    }

    func scriptDeleteResult(_ result: BatchDeleteResult) {
        scriptedDeleteResult = result
    }

    func scriptDeleteError(_ error: Error) {
        scriptedDeleteError = error
    }

    func scriptAccessError(_ error: Error) {
        scriptedAccessError = error
    }

    // MARK: - EventKitManaging conformance

    func listCompletedReminderIdentifiers(
        calendarName: String?,
        calendarSource: String?
    ) async throws -> [String] {
        listCompletedReminderIdentifiersCalls.append(
            ListCall(calendarName: calendarName, calendarSource: calendarSource)
        )
        if let scriptedListError { throw scriptedListError }
        return scriptedIdentifiers
    }

    func deleteRemindersBatch(
        identifiers: [String],
        onlyCompleted: Bool
    ) async throws -> BatchDeleteResult {
        deleteRemindersBatchCalls.append(
            DeleteCall(identifiers: identifiers, onlyCompleted: onlyCompleted)
        )
        if let scriptedDeleteError { throw scriptedDeleteError }
        if let scriptedDeleteResult { return scriptedDeleteResult }
        // Default: everything succeeds
        return BatchDeleteResult(
            successCount: identifiers.count,
            failedCount: 0,
            failures: []
        )
    }

    func requestReminderAccess() async throws {
        requestReminderAccessCallCount += 1
        if let scriptedAccessError { throw scriptedAccessError }
    }
}
