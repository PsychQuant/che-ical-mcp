import EventKit
import XCTest
@testable import CheICalMCP

/// Coverage for `SelfDisclaim.decide` (#343) — whether CheICalMCP re-execs itself as its
/// own responsible process before any dispatch. The skip reasons are a closed set of eight
/// and the re-exec reasons a closed set of three; each has a test.
///
/// The rule after verify round 2 is status-aware, and the same for every host: a host whose
/// context already has full Calendar and Reminders access keeps that grant (a working
/// version-number grant under Claude Code included), and any other host re-execs so macOS
/// checks CheICalMCP's own grant — the one `--setup` creates. A host a policy restricts for
/// either service keeps its attribution (#367), and `CHE_ICAL_MCP_FORCE_DISCLAIM` yields to
/// that; `--setup` re-execs under any host; `CHE_ICAL_MCP_NO_DISCLAIM` wins over everything
/// except the loop guard.
final class SelfDisclaimDecisionTests: XCTestCase {

    private let binary = "/Users/u/bin/CheICalMCP"
    private let vsCode = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 3599,
        path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        isSelf: false))
    private let claudeCode = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 9664, path: "/Users/u/.local/share/claude/versions/2.1.309", isSelf: false))
    private let claudeCodeApp = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 9665, path: "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", isSelf: false))
    private let bareExecutable = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 1, path: "/sbin/launchd", isSelf: false))
    private let noPath = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 77, path: nil, isSelf: false))
    private let selfResponsible = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 42, path: "/Users/u/bin/CheICalMCP", isSelf: true))

    private var everyOtherHost: [ResponsibleProcessResult] {
        [vsCode, claudeCode, claudeCodeApp, bareExecutable, noPath]
    }

    /// Counts reads of the host's authorization status, so a test can say a path never
    /// touches EventKit.
    private final class GrantProbe {
        let status: HostAuthorization
        private(set) var reads = 0
        init(_ calendar: EKAuthorizationStatus, _ reminders: EKAuthorizationStatus) {
            status = HostAuthorization(calendar: calendar, reminders: reminders)
        }
        convenience init(usable: Bool) {
            self.init(usable ? .fullAccess : .notDetermined, usable ? .fullAccess : .notDetermined)
        }
        func read() -> HostAuthorization { reads += 1; return status }
    }

    /// Every combination with `.restricted` on at least one service (#367).
    private let restrictedCombinations: [(EKAuthorizationStatus, EKAuthorizationStatus)] = [
        (.restricted, .fullAccess), (.fullAccess, .restricted), (.restricted, .restricted),
        (.restricted, .denied), (.notDetermined, .restricted), (.writeOnly, .restricted),
    ]

    private func decide(
        _ extraArgs: [String] = [],
        env: [String: String] = [:],
        responsible: ResponsibleProcessResult? = nil,
        probe: GrantProbe = GrantProbe(usable: false)
    ) -> SelfDisclaimDecision {
        SelfDisclaim.decide(
            arguments: [binary] + extraArgs,
            environment: env,
            responsible: responsible ?? vsCode,
            hostAuthorization: probe.read)
    }

    // MARK: - The eight skip reasons

    func testAlreadyDisclaimedSentinel_skipsSoItCannotLoop() {
        // Self-responsible after the re-exec: the normal, healthy second image.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: selfResponsible),
            .skip(.alreadyDisclaimed))
        // Without a lookup there is nothing to contradict the sentinel.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: .unavailable(reason: "x")),
            .skip(.alreadyDisclaimed))
    }

    func testSentinelOnAnyOtherHost_isReportedAsIneffective() {
        // The sentinel is an unauthenticated environment variable. Set while some other
        // process is still responsible, the re-exec either never took effect or the variable
        // is stale (inherited from a shell). Round 2 reported this only under Claude Code; the
        // status-aware rule re-execs under any host, so any host can show it.
        for host in everyOtherHost {
            XCTAssertEqual(
                decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: host),
                .skip(.disclaimIneffective), "host \(host)")
        }
    }

    func testOptOut_skipsEvenWhenTheHostHasNoUsableGrant() {
        for host in everyOtherHost {
            XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"], responsible: host), .skip(.optedOut))
        }
    }

    func testOptOutWinsOverForceAndSetup() {
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1"]),
            .skip(.optedOut))
        XCTAssertEqual(decide(["--setup"], env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"]), .skip(.optedOut))
    }

    func testOptOutWithEmptyValue_isNotAnOptOut() {
        // Same convention as CHE_ICAL_MCP_NO_BANNER: an exported-but-empty variable is unset.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": ""], responsible: claudeCode),
            .reexec(.hostGrantUnusable))
    }

    func testAlreadySelfResponsible_skips() {
        // Claude Desktop's .mcpb server runs under `disclaimer` and is already its own client.
        XCTAssertEqual(decide(responsible: selfResponsible), .skip(.alreadySelfResponsible))
        XCTAssertEqual(
            decide(["--setup"], responsible: selfResponsible), .skip(.alreadySelfResponsible))
    }

    func testFlagsThatNeverTouchTCC_skipWithoutReadingTheHostGrant() {
        for flag in ["--version", "-v", "--help", "-h", "--self-update"] {
            let probe = GrantProbe(usable: false)
            XCTAssertEqual(
                decide([flag], responsible: claudeCode, probe: probe), .skip(.noTCCAccessNeeded), "flag \(flag)")
            XCTAssertEqual(probe.reads, 0, "\(flag) must not touch EventKit")
        }
    }

    func testResponsibilityUnavailable_skipsWithTheReason() {
        XCTAssertEqual(
            decide(responsible: .unavailable(reason: "responsibility SPI not found in this macOS")),
            .skip(.responsibilityUnavailable("responsibility SPI not found in this macOS")))
    }

    func testHostWithAUsableGrant_keepsIt_onEveryHost() {
        // Round 2 row 5: a working version-number grant under Claude Code was swapped for
        // CheICalMCP's own, which may be empty. Status decides now, not the kind of host.
        for host in everyOtherHost {
            for mode in [[], ["--print-tcc-path"], ["--cli", "list_calendars"]] {
                XCTAssertEqual(
                    decide(mode, responsible: host, probe: GrantProbe(usable: true)),
                    .skip(.hostGrantIsUsable), "host \(host), mode \(mode)")
            }
        }
    }

    func testHostRestrictedByPolicy_keepsTheHost_onEveryHost() {
        // #367: re-executing would trade a policy-restricted host's attribution for CheICalMCP's
        // grant, which the policy does not cover. The host keeps it, whatever the other service is.
        for host in everyOtherHost {
            for (calendar, reminders) in restrictedCombinations {
                for mode in [[], ["--print-tcc-path"], ["--cli", "list_calendars"]] {
                    XCTAssertEqual(
                        decide(mode, responsible: host, probe: GrantProbe(calendar, reminders)),
                        .skip(.hostRestrictedByPolicy),
                        "host \(host), calendar \(calendar.rawValue), reminders \(reminders.rawValue), mode \(mode)")
                }
            }
        }
    }

    // MARK: - The criteria the closure's statuses are judged by (verify round 3, row 12; #367)

    func testHostGrantIsUsable_onlyWhenBothServicesHaveFullAccess() {
        XCTAssertTrue(SelfDisclaim.hostGrantIsUsable(calendar: .fullAccess, reminders: .fullAccess))
        for other: EKAuthorizationStatus in [.notDetermined, .denied, .restricted, .writeOnly] {
            XCTAssertFalse(SelfDisclaim.hostGrantIsUsable(calendar: .fullAccess, reminders: other), "reminders \(other.rawValue)")
            XCTAssertFalse(SelfDisclaim.hostGrantIsUsable(calendar: other, reminders: .fullAccess), "calendar \(other.rawValue)")
            XCTAssertFalse(SelfDisclaim.hostGrantIsUsable(calendar: other, reminders: other), "both \(other.rawValue)")
        }
    }

    func testHostIsRestricted_whenEitherServiceIsRestricted() {
        for (calendar, reminders) in restrictedCombinations {
            XCTAssertTrue(
                SelfDisclaim.hostIsRestricted(calendar: calendar, reminders: reminders),
                "calendar \(calendar.rawValue), reminders \(reminders.rawValue)")
        }
        for other: EKAuthorizationStatus in [.notDetermined, .denied, .fullAccess, .writeOnly] {
            for second: EKAuthorizationStatus in [.notDetermined, .denied, .fullAccess, .writeOnly] {
                XCTAssertFalse(SelfDisclaim.hostIsRestricted(calendar: other, reminders: second))
            }
        }
    }

    func testHostGrantIsUsable_theIssuesOwnStateIsNotUsable() {
        // #343's resumed session: the version-number entry had Reminders and not Calendar. The
        // working service moves to CheICalMCP's grant too — the trade-off the user chose.
        XCTAssertFalse(SelfDisclaim.hostGrantIsUsable(calendar: .notDetermined, reminders: .fullAccess))
    }

    // MARK: - The three re-exec reasons

    func testHostWithoutAUsableGrant_reexecs_onEveryHost() {
        // Round 2 row 1: under VS Code, Terminal, launchd the server kept a host grant that
        // did not exist, so the CheICalMCP grant `--setup` creates was never used there.
        for host in everyOtherHost {
            for mode in [[], ["--print-tcc-path"], ["--cli", "list_calendars"]] {
                XCTAssertEqual(
                    decide(mode, responsible: host, probe: GrantProbe(usable: false)),
                    .reexec(.hostGrantUnusable), "host \(host), mode \(mode)")
            }
        }
    }

    func testSetup_reexecsUnderAnyHost_withoutReadingTheHostGrant() {
        // `--setup` creates CheICalMCP's own grant, the one every host without a usable grant
        // falls back to — so it re-execs even where the host's grant works.
        for host in everyOtherHost {
            let probe = GrantProbe(usable: true)
            XCTAssertEqual(decide(["--setup"], responsible: host, probe: probe), .reexec(.setup))
            XCTAssertEqual(probe.reads, 0)
        }
    }

    func testSetup_stillReexecsUnderARestrictedHost() {
        // #367: `--setup` only creates CheICalMCP's own grant; it does not move a restricted host's
        // server onto it, because that server never re-execs.
        let probe = GrantProbe(.restricted, .restricted)
        XCTAssertEqual(decide(["--setup"], responsible: claudeCode, probe: probe), .reexec(.setup))
        XCTAssertEqual(probe.reads, 0)
    }

    func testSetupAlongsidePrintTCCPath_followsTheDispatchOrder() {
        // main.swift runs `--print-tcc-path` before `--setup`, so that is the mode that runs.
        XCTAssertEqual(
            decide(["--print-tcc-path", "--setup"], probe: GrantProbe(usable: true)),
            .skip(.hostGrantIsUsable))
        XCTAssertEqual(
            decide(["--setup", "--print-tcc-path"], probe: GrantProbe(usable: false)),
            .reexec(.hostGrantUnusable))
    }

    func testForce_reexecsUnderAnyHostThatIsNotRestricted() {
        for host in everyOtherHost {
            for usable in [true, false] {
                let probe = GrantProbe(usable: usable)
                XCTAssertEqual(
                    decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"], responsible: host, probe: probe),
                    .reexec(.forced), "host \(host), usable \(usable)")
                // #367: FORCE reads the status now, to yield to a restricted host.
                XCTAssertEqual(probe.reads, 1)
            }
        }
        // An exported-but-empty variable is unset, like the others.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": ""], probe: GrantProbe(usable: true)),
            .skip(.hostGrantIsUsable))
    }

    func testForce_yieldsToARestrictedHost() {
        // #367: the variable is set by whoever starts the server, and a policy outranks it.
        for (calendar, reminders) in restrictedCombinations {
            XCTAssertEqual(
                decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"], responsible: claudeCode,
                       probe: GrantProbe(calendar, reminders)),
                .skip(.hostRestrictedByPolicy))
        }
    }

    func testForce_stillNeverLoopsAndStillSkipsFlagsThatNeedNoTCC() {
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1", "CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: selfResponsible),
            .skip(.alreadyDisclaimed))
        XCTAssertEqual(
            decide(["--version"], env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"]), .skip(.noTCCAccessNeeded))
    }

    func testSkipsThatPrecedeTheStatusRead_neverReadIt() {
        // The read is lazy: only a decision that actually depends on the host's grant pays it.
        let cases: [([String], [String: String], ResponsibleProcessResult)] = [
            ([], ["CHE_ICAL_MCP_DISCLAIMED": "1"], selfResponsible),
            ([], ["CHE_ICAL_MCP_NO_DISCLAIM": "1"], vsCode),
            ([], [:], selfResponsible),
            ([], [:], .unavailable(reason: "x")),
        ]
        for (args, env, host) in cases {
            let probe = GrantProbe(usable: false)
            _ = decide(args, env: env, responsible: host, probe: probe)
            XCTAssertEqual(probe.reads, 0, "args \(args), env \(env)")
        }
    }
}
