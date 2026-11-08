import EventKit
import XCTest
@testable import CheICalMCP

/// #482, the sister of #476: `AuthorizationGate.ensureAccess` and `UndoBatchExecution.run` were
/// nonisolated async functions (Swift 5 mode, SE-0338), so they ran on the generic executor even
/// when an actor called them. The gate read the status and asked for access through a source that
/// holds the `EventKitManager` actor's own `EKEventStore`, off that actor; the batch runner called
/// its synchronous `describe` closure, formed on the actor, off it too. Both now run on the caller's
/// actor (`#isolation`), and the probes trap (`preconditionIsolated`, which also checks in -O
/// builds) if anything runs anywhere else, as `UndoRestoreSeamIsolationTests` does for #476.
final class CallerIsolationSeamTests: XCTestCase {
    func testTheAuthorizationGateReadsAndRequestsOnTheCallersActor() async throws {
        let probe = AuthorizationGateIsolationProbe()
        try await probe.ensureAccess(status: .notDetermined)
        let steps = await probe.steps
        XCTAssertEqual(steps, ["status (isolated)", "request (isolated)"])
    }

    /// The production callers (`ensureCalendarAccess`, `ensureReminderAccess`) pass no isolation, so
    /// `#isolation` gives them the `EventKitManager` actor.
    func testTheManagersAccessChecksReadTheStatusOnTheManagersActor() async throws {
        let source = ManagerIsolationCheckingSource()
        let manager = EventKitManager.forTesting(probe: source)
        source.owner = manager
        try await manager.ensureCalendarAccess()
        try await manager.ensureReminderAccess()
        XCTAssertEqual(source.isolatedReads, 2)
    }

    func testABatchUndoDescribesTheFailedMemberOnTheCallersActor() async throws {
        let probe = BatchDescribeIsolationProbe()
        do {
            try await probe.runAFailingUndo()
            XCTFail("the failing member must surface as an error")
        } catch is UndoBatchPartiallyUndoneError {}
        let steps = await probe.steps
        XCTAssertEqual(steps, ["check (isolated)", "check (isolated)", "describe (isolated)"])
    }

    /// The gate's declaration takes the caller's isolation, the access request is handed it, and no
    /// caller in the manager passes nil by hand (which would bring the old behavior back).
    func testTheGateAndTheBatchRunTakeTheCallersIsolation() throws {
        let param = "isolation: isolated (any Actor)? = #isolation"
        let gate = SourcePins.code(try SourcePins.source("EventKit/AuthorizationStatusSource.swift"))
        let gateDeclaration = try XCTUnwrap(gate.range(of: "static func ensureAccess(")
            .flatMap { start in gate.range(of: ") async throws {", range: start.upperBound..<gate.endIndex).map { gate[start.lowerBound..<$0.upperBound] } })
        XCTAssertTrue(gateDeclaration.contains(param))
        XCTAssertTrue(gate.contains("probe.requestFullAccess(for: entityType, isolation: isolation)"))
        let batch = SourcePins.code(try SourcePins.source("EventKit/UndoBatchRestore.swift"))
        let execution = try XCTUnwrap(batch.range(of: "enum UndoBatchExecution").map { String(batch[$0.lowerBound...]) })
        XCTAssertEqual(SourcePins.ranges(of: param, in: execution).count, 2, "both UndoBatchExecution.run overloads")
        let callers = try SourcePins.source("EventKit/EventKitManager.swift")
        XCTAssertFalse(callers.contains("isolation: nil"))
    }
}

private actor AuthorizationGateIsolationProbe {
    private(set) var steps: [String] = []

    fileprivate func note(_ step: String) {
        preconditionIsolated("\(step) must run on the actor that called the gate")
        steps.append("\(step) (isolated)")
    }

    func ensureAccess(status: EKAuthorizationStatus) async throws {
        try await AuthorizationGate.ensureAccess(
            for: .event, typeName: "Calendar", isSSH: false, isNonInteractive: false,
            probe: GateIsolationCheckingSource(status: status, probe: self))
    }
}

/// Each method traps unless it runs on `probe`'s actor, then records the step there.
private struct GateIsolationCheckingSource: AuthorizationStatusSource {
    let status: EKAuthorizationStatus
    let probe: AuthorizationGateIsolationProbe

    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus {
        probe.preconditionIsolated("the status read must run on the caller's actor")
        probe.assumeIsolated { $0.note("status") }
        return status
    }

    func requestFullAccess(for entityType: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool {
        probe.preconditionIsolated("the access request must run on the caller's actor")
        await probe.note("request")
        return true
    }
}

/// Single-test instance (see `AuthorizationGateTests.MockAuthorizationStatusSource`, #120).
private final class ManagerIsolationCheckingSource: AuthorizationStatusSource {
    var owner: EventKitManager?
    private(set) var isolatedReads = 0

    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus {
        guard let owner else { preconditionFailure("set owner before the first access check") }
        owner.preconditionIsolated("the manager's status read must run on the manager's actor")
        isolatedReads += 1
        return .fullAccess
    }

    func requestFullAccess(for entityType: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool {
        preconditionFailure("a .fullAccess status never requests access")
    }
}

private actor BatchDescribeIsolationProbe {
    private(set) var steps: [String] = []

    private func note(_ step: String) {
        preconditionIsolated("\(step) must run on the actor that formed it")
        steps.append("\(step) (isolated)")
    }

    func runAFailingUndo() async throws {
        let members: [UndoOperation] = [.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "One")),
                                        .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Two"))]
        _ = try await UndoBatchExecution.run(
            members, verb: .undo,
            check: { _ in
                self.note("check")
                await Task.yield()
            },
            execute: { _ in
                await Task.yield()
                throw WriteFailed()
            },
            describe: { _ in
                self.note("describe")
                return "write failed"
            })
    }

    struct WriteFailed: Error {}
}
