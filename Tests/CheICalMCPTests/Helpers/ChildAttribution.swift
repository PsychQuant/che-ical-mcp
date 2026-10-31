import Darwin
import Foundation
import XCTest
@testable import CheICalMCP

// Shared probe for the binary-spawn tests of #343. Lives under `Helpers/` per the CLAUDE.md
// "Helpers/ subdirectory" convention: shared test infrastructure exempt from the
// `*Tests.swift` naming rule.
//
// Under some launchers every process is its own responsible process (2026-10-29, a Claude
// Code 2.1.312 background session: the shell, its children and an opted-out CheICalMCP were
// all self-responsible), and then there is no host attribution to observe, keep or re-exec
// away from. Tests that need a host skip there.
//
// The probe is `/bin/sleep`, not CheICalMCP: asking an opted-out CheICalMCP made the guard
// depend on the opt-out it was guarding, so an opt-out regression made those tests skip
// instead of fail (verify round 3b row 3). The runner asks the kernel about the child's pid
// itself, and every wait is bounded (row 1): the child is killed right after the lookup.
enum ChildAttribution {
    /// Whether a child of this runner is its own responsible process; `nil` when the
    /// responsibility SPI is missing or the probe could not be spawned or looked up.
    static func childIsSelfResponsible() -> Bool? {
        guard LiveResponsibleProcessSource.isAvailable else { return nil }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return nil }
        let pid = child.processIdentifier
        defer {
            kill(pid, SIGKILL)   // cannot be caught, so the wait below ends
            child.waitUntilExit()
        }
        guard case .resolved(let responsible) = LiveResponsibleProcessSource().responsibleProcess(for: pid) else {
            return nil
        }
        return responsible.isSelf
    }

    /// Skips unless a child of this runner inherits a host to be responsible for it.
    static func requireHostAttributedChild() throws {
        switch childIsSelfResponsible() {
        case nil:
            throw XCTSkip("responsibility SPI unavailable, or the /bin/sleep probe could not be looked up")
        case true?:
            throw XCTSkip("a child of this runner is already its own responsible process, so host attribution cannot be observed")
        case false?:
            return
        }
    }
}
