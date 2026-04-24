import XCTest
import MCP
@testable import CheICalMCP

/// Integration tests for `handleCleanupCompletedReminders` that exercise
/// the dry-run vs execute branches, filter vs binding modes, R2-F2
/// arithmetic invariant, #28 F1 onlyCompleted semantics, and the F8
/// stable response shape — all via `FakeEventKitManager` so no real
/// EventKit access is needed.
final class CleanupHandlerTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Response was not a JSON object: \(json)")
            return [:]
        }
        return dict
    }

    private func runCleanup(
        fake: FakeEventKitManager,
        arguments: [String: Value]
    ) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(reminderCleanupSource: fake)
        let json = try await server.executeToolCall(
            name: "cleanup_completed_reminders",
            arguments: arguments
        )
        return try parse(json)
    }

    // MARK: - F1 guard ordering (integration-level)

    func testF1GuardFiresBeforeListReminders() async throws {
        let fake = FakeEventKitManager()
        let server = try await CheICalMCPServer(reminderCleanupSource: fake)

        do {
            _ = try await server.executeToolCall(
                name: "cleanup_completed_reminders",
                arguments: ["calendar_source": .string("iCloud")]
            )
            XCTFail("Expected ToolError.invalidParameter")
        } catch ToolError.invalidParameter {
            // expected
        }

        let calls = await fake.listCompletedReminderIdentifiersCalls
        XCTAssertTrue(
            calls.isEmpty,
            "F1 guard must fire before the EventKit primitive is invoked"
        )
    }

    // MARK: - Filter mode dry-run

    func testDryRunFilterModeReturnsPreviewWithoutDeleting() async throws {
        let fake = FakeEventKitManager()
        await fake.scriptCompletedReminderIdentifiers(["r1", "r2", "r3"])

        let response = try await runCleanup(
            fake: fake,
            arguments: ["dry_run": .bool(true)]
        )

        XCTAssertEqual(response["mode"] as? String, "filter")
        XCTAssertEqual(response["total"] as? Int, 3)
        let preview = response["reminders_to_delete"] as? [[String: Any]]
        XCTAssertEqual(preview?.count, 3)
        XCTAssertEqual(response["deleted_count"] as? Int, 0)

        let deleteCalls = await fake.deleteRemindersBatchCalls
        XCTAssertTrue(deleteCalls.isEmpty, "dry_run=true must not invoke deleteRemindersBatch")
    }

    func testExecuteFilterModeCallsDeleteRemindersBatch() async throws {
        let fake = FakeEventKitManager()
        await fake.scriptCompletedReminderIdentifiers(["r1", "r2"])

        let response = try await runCleanup(
            fake: fake,
            arguments: ["dry_run": .bool(false)]
        )

        XCTAssertEqual(response["mode"] as? String, "filter")
        XCTAssertEqual(response["deleted_count"] as? Int, 2)

        let calls = await fake.deleteRemindersBatchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.onlyCompleted, false)
    }

    func testDryRunBindingModeReturnsSuppliedIds() async throws {
        let fake = FakeEventKitManager()

        let response = try await runCleanup(
            fake: fake,
            arguments: [
                "reminder_ids": .array([.string("a"), .string("b"), .string("c")]),
                "dry_run": .bool(true)
            ]
        )

        XCTAssertEqual(response["mode"] as? String, "binding")
        XCTAssertEqual(response["total"] as? Int, 3)

        let listCalls = await fake.listCompletedReminderIdentifiersCalls
        XCTAssertTrue(listCalls.isEmpty, "binding mode must NOT call list primitive")
        let deleteCalls = await fake.deleteRemindersBatchCalls
        XCTAssertTrue(deleteCalls.isEmpty, "binding mode dry-run must NOT call delete primitive")
    }

    func testExecuteBindingModeUsesOnlyCompletedTrue() async throws {
        let fake = FakeEventKitManager()

        _ = try await runCleanup(
            fake: fake,
            arguments: [
                "reminder_ids": .array([.string("a")]),
                "dry_run": .bool(false)
            ]
        )

        let calls = await fake.deleteRemindersBatchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls.first?.onlyCompleted,
            true,
            "binding mode must pass onlyCompleted=true (#28 F1)"
        )
    }

    func testBindingModeRejectsUncompletedReminderViaFakeResult() async throws {
        let fake = FakeEventKitManager()
        await fake.scriptDeleteResult(
            BatchDeleteResult(
                successCount: 1,
                failedCount: 1,
                failures: [(identifier: "b", error: "Reminder is no longer completed")]
            )
        )

        let response = try await runCleanup(
            fake: fake,
            arguments: [
                "reminder_ids": .array([.string("a"), .string("b")]),
                "dry_run": .bool(false)
            ]
        )

        XCTAssertEqual(response["deleted_count"] as? Int, 1)
        let deletedIds = response["deleted_ids"] as? [String]
        XCTAssertEqual(deletedIds, ["a"])
        let failures = response["failures"] as? [[String: Any]]
        XCTAssertEqual(failures?.count, 1)
        XCTAssertEqual(failures?.first?["reminder_id"] as? String, "b")
        XCTAssertTrue(
            ((failures?.first?["error"] as? String) ?? "").contains("no longer completed"),
            "#28 F1 failure message must indicate the reminder is no longer completed"
        )
    }

    func testTotalEqualsUniqueIdentifiersCount() async throws {
        // Dry-run branch invariant: total == preview.count + remaining
        do {
            let fake = FakeEventKitManager()
            await fake.scriptCompletedReminderIdentifiers(["a", "a", "b", "c", "c"])
            let response = try await runCleanup(
                fake: fake,
                arguments: ["dry_run": .bool(true)]
            )
            let total = response["total"] as? Int ?? -1
            let preview = response["reminders_to_delete"] as? [[String: Any]] ?? []
            let remaining = response["remaining"] as? Int ?? -1
            XCTAssertEqual(total, 3, "total must be the deduped unique count (R2-F2)")
            XCTAssertEqual(
                preview.count + remaining,
                total,
                "dry-run: preview.count + remaining == total"
            )
        }

        // Execute branch invariant: total == deleted_count + failures.count + remaining
        do {
            let fake = FakeEventKitManager()
            await fake.scriptCompletedReminderIdentifiers(["a", "a", "b", "c", "c"])
            // Script a mixed result: 2 succeed, 1 fails
            await fake.scriptDeleteResult(
                BatchDeleteResult(
                    successCount: 2,
                    failedCount: 1,
                    failures: [(identifier: "c", error: "test failure")]
                )
            )
            let response = try await runCleanup(
                fake: fake,
                arguments: ["dry_run": .bool(false)]
            )
            let total = response["total"] as? Int ?? -1
            let deletedCount = response["deleted_count"] as? Int ?? -1
            let failures = response["failures"] as? [[String: Any]] ?? []
            let remaining = response["remaining"] as? Int ?? -1
            XCTAssertEqual(total, 3, "total must be the deduped unique count (R2-F2)")
            XCTAssertEqual(
                deletedCount + failures.count + remaining,
                total,
                "execute: deleted_count + failures.count + remaining == total"
            )
        }
    }

    func testDuplicateReminderIdsAreDeduped() async throws {
        let fake = FakeEventKitManager()

        _ = try await runCleanup(
            fake: fake,
            arguments: [
                "reminder_ids": .array([.string("a"), .string("a"), .string("b")]),
                "dry_run": .bool(false)
            ]
        )

        let calls = await fake.deleteRemindersBatchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls.first?.identifiers,
            ["a", "b"],
            "dedupe must preserve first-occurrence order"
        )
    }

    func testResponseShapeStableAcrossThreeBranches() async throws {
        let requiredKeys: Set<String> = [
            "dry_run", "mode", "total",
            "deleted_count", "deleted_ids", "failures", "remaining"
        ]

        // Branch 1: dry-run with results
        do {
            let fake = FakeEventKitManager()
            await fake.scriptCompletedReminderIdentifiers(["r1"])
            let r = try await runCleanup(fake: fake, arguments: ["dry_run": .bool(true)])
            let keys = Set(r.keys)
            XCTAssertTrue(requiredKeys.isSubset(of: keys))
        }

        // Branch 2: execute with empty result set
        do {
            let fake = FakeEventKitManager()
            await fake.scriptCompletedReminderIdentifiers([])
            let r = try await runCleanup(fake: fake, arguments: ["dry_run": .bool(false)])
            let keys = Set(r.keys)
            XCTAssertTrue(requiredKeys.isSubset(of: keys))
        }

        // Branch 3: execute with deletions
        do {
            let fake = FakeEventKitManager()
            await fake.scriptCompletedReminderIdentifiers(["r1", "r2"])
            let r = try await runCleanup(fake: fake, arguments: ["dry_run": .bool(false)])
            let keys = Set(r.keys)
            XCTAssertTrue(requiredKeys.isSubset(of: keys))
        }
    }

    func testLimitRespectsBlastRadiusCap() async throws {
        let fake = FakeEventKitManager()
        await fake.scriptCompletedReminderIdentifiers((1...10).map { "r\($0)" })

        let response = try await runCleanup(
            fake: fake,
            arguments: [
                "dry_run": .bool(false),
                "limit": .int(3)
            ]
        )

        XCTAssertEqual(response["deleted_count"] as? Int, 3, "limit should cap deletions to 3")
        XCTAssertEqual(response["remaining"] as? Int, 7, "remaining should reflect uncapped pool")
        XCTAssertEqual(response["total"] as? Int, 10)

        let calls = await fake.deleteRemindersBatchCalls
        XCTAssertEqual(calls.first?.identifiers.count, 3)
    }

    func testEmptyReminderIdsReturnsZero() async throws {
        let fake = FakeEventKitManager()

        let response = try await runCleanup(
            fake: fake,
            arguments: [
                "reminder_ids": .array([]),
                "dry_run": .bool(false)
            ]
        )

        XCTAssertEqual(response["mode"] as? String, "binding")
        XCTAssertEqual(response["total"] as? Int, 0)
        XCTAssertEqual(response["deleted_count"] as? Int, 0)

        let calls = await fake.deleteRemindersBatchCalls
        XCTAssertTrue(calls.isEmpty)
    }
}
