import XCTest
import EventKit
@testable import CheICalMCP

#if canImport(AppKit) && canImport(SwiftUI)

/// Unit tests for `SetupModel` — the testable seam behind the `--setup` SwiftUI
/// SetupWindow (#164). Exercises status mapping, per-entity init, grant success /
/// sanitized-error, live refresh, and start() timer idempotency, all without an
/// `EKEventStore` or rendering SwiftUI.
@MainActor
final class SetupModelTests: XCTestCase {

    /// Per-entity, mutable fake so tests can vary Calendar vs Reminders independently and
    /// simulate a status change after a grant request (user clicking Allow).
    final class FakeProbe: AuthorizationStatusSource {
        var statuses: [EKEntityType: EKAuthorizationStatus]
        var requestResult: Result<Bool, Error>
        var onRequest: ((EKEntityType) -> Void)?
        private(set) var requestCount = 0

        init(event: EKAuthorizationStatus = .notDetermined,
             reminder: EKAuthorizationStatus = .notDetermined,
             requestResult: Result<Bool, Error> = .success(true)) {
            self.statuses = [.event: event, .reminder: reminder]
            self.requestResult = requestResult
        }

        func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus {
            statuses[entityType] ?? .notDetermined
        }

        func requestFullAccess(for entityType: EKEntityType) async throws -> Bool {
            requestCount += 1
            onRequest?(entityType)
            return try requestResult.get()
        }
    }

    private struct ControlCharError: LocalizedError {
        var errorDescription: String? { "bad\u{07}grant" }
    }

    // MARK: - Status mapping

    func testStateMapping() {
        XCTAssertEqual(SetupEntityState.from(.fullAccess), .granted)
        XCTAssertEqual(SetupEntityState.from(.writeOnly), .writeOnly)
        XCTAssertEqual(SetupEntityState.from(.denied), .denied)
        XCTAssertEqual(SetupEntityState.from(.restricted), .denied)
        XCTAssertEqual(SetupEntityState.from(.notDetermined), .notDetermined)
    }

    // MARK: - Init reads per-entity status

    func testInitReadsPerEntityStatus() {
        let probe = FakeProbe(event: .fullAccess, reminder: .denied)
        let model = SetupModel(probe: probe, binaryPath: "/x/CheICalMCP")
        XCTAssertEqual(model.calendar, .granted)
        XCTAssertEqual(model.reminders, .denied)
        XCTAssertEqual(model.binaryPath, "/x/CheICalMCP")
    }

    func testIsReady() {
        XCTAssertTrue(SetupModel(probe: FakeProbe(event: .fullAccess, reminder: .fullAccess), binaryPath: "/x").isReady)
        XCTAssertFalse(SetupModel(probe: FakeProbe(event: .fullAccess, reminder: .denied), binaryPath: "/x").isReady)
    }

    // MARK: - Grant

    func testGrantSuccessFlipsToGranted() async {
        let probe = FakeProbe(event: .notDetermined)
        probe.onRequest = { entity in probe.statuses[entity] = .fullAccess }  // simulate user Allow
        let model = SetupModel(probe: probe, binaryPath: "/x")
        XCTAssertEqual(model.calendar, .notDetermined)
        await model.grant(.event)
        XCTAssertEqual(model.calendar, .granted)
        XCTAssertEqual(probe.requestCount, 1)
    }

    func testGrantErrorSetsSanitizedErrorState() async {
        let probe = FakeProbe(event: .notDetermined, requestResult: .failure(ControlCharError()))
        let model = SetupModel(probe: probe, binaryPath: "/x")
        await model.grant(.event)
        guard case .error(let msg) = model.calendar else {
            return XCTFail("expected .error, got \(model.calendar)")
        }
        XCTAssertFalse(msg.contains("\u{07}"), "grant error text must be control-char sanitized")
        XCTAssertTrue(msg.contains("bad") && msg.contains("grant"), "sanitized text keeps printable content")
    }

    // MARK: - Live refresh

    func testRefreshRereadsStatus() {
        let probe = FakeProbe(event: .notDetermined)
        let model = SetupModel(probe: probe, binaryPath: "/x")
        XCTAssertEqual(model.calendar, .notDetermined)
        probe.statuses[.event] = .fullAccess
        model.refresh()
        XCTAssertEqual(model.calendar, .granted)
    }

    // MARK: - start() idempotency (no leaked second timer)

    func testStartStopIdempotent() {
        let model = SetupModel(probe: FakeProbe(), binaryPath: "/x")
        XCTAssertFalse(model.isPolling)
        model.start()
        XCTAssertTrue(model.isPolling)
        model.start()  // must not crash or leak a second timer
        XCTAssertTrue(model.isPolling)
        model.stop()
        XCTAssertFalse(model.isPolling)
    }
}
#endif
