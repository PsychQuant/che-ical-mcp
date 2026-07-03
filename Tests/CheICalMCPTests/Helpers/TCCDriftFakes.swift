import Foundation
@testable import CheICalMCP

// Shared test fakes for `TCCDriftDetector` unit tests. Lives under `Helpers/` per the
// CLAUDE.md "Helpers/ subdirectory" convention: shared test infrastructure exempt from
// the `*Tests.swift` naming rule.
//
// Both fakes are pure stubs — they return whatever you initialize them with, plus
// optional failure-reason injection so tests can reproduce the "sqlite3 unavailable"
// and "ps fails" code paths.

struct FakeTCCDatabaseSource: TCCDatabaseSource {
    let result: TCCQueryResult

    init(entries: [TCCEntry] = [], failureReason: String? = nil) {
        self.result = TCCQueryResult(entries: entries, failureReason: failureReason)
    }

    func readCheICalMCPEntries() -> TCCQueryResult { result }
}

struct FakeProcessInventorySource: ProcessInventorySource {
    let result: ProcessInventoryResult

    init(processes: [RunningProcess] = [], failureReason: String? = nil) {
        self.result = ProcessInventoryResult(processes: processes, failureReason: failureReason)
    }

    func enumerateCheICalMCPProcesses() -> ProcessInventoryResult { result }
}

/// Fake self-code-signing source for the #155 csreq-mismatch signal. Returns a fixed
/// evaluation for every blob and a fixed entitlement answer — enough to drive the drift
/// logic deterministically (the real running-binary signature can't be controlled here).
struct FakeCodeSignatureSource: CodeSignatureSource {
    let evaluation: RequirementEvaluation
    let hasEntitlement: Bool?

    init(evaluation: RequirementEvaluation = .satisfies, hasEntitlement: Bool? = true) {
        self.evaluation = evaluation
        self.hasEntitlement = hasEntitlement
    }

    func evaluateRunningBinary(againstRequirementBlob csreqBlob: Data) -> RequirementEvaluation { evaluation }
    func runningBinaryHasPersonalInfoEntitlement() -> Bool? { hasEntitlement }
}

// MARK: - Factory helpers (terse fixtures so the test names carry the meaning, not setup boilerplate)

enum TCCDriftFixtures {
    /// Build a `TCCEntry` with `auth_value=2` (granted) defaults.
    static func entry(
        service: String = "kTCCServiceCalendar",
        client: String,
        authValue: Int = 2,
        lastModifiedUnix: Int64 = 1_748_774_595,
        csreqHex: String? = nil
    ) -> TCCEntry {
        TCCEntry(
            service: service, client: client, authValue: authValue,
            lastModifiedUnix: lastModifiedUnix, csreqHex: csreqHex
        )
    }

    /// Build a `RunningProcess` from a date string in `LiveProcessInventorySource`'s
    /// expected lstart format. Falls back to `Date.distantPast` if parsing fails.
    static func process(
        pid: Int32,
        executablePath: String = "/Users/test/bin/CheICalMCP",
        startedAt: Date
    ) -> RunningProcess {
        RunningProcess(pid: pid, executablePath: executablePath, startedAt: startedAt)
    }

    /// Convenience: parse a lstart-format string into a Date so test cases can spell
    /// `"Mon May 11 22:36:52 2026"` instead of building DateComponents.
    static func lstartDate(_ formatted: String) -> Date {
        LiveProcessInventorySource.lstartFormatter.date(from: formatted) ?? Date.distantPast
    }
}
