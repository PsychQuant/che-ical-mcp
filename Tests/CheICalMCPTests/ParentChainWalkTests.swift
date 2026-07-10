import XCTest
@testable import CheICalMCP

/// Pure-unit coverage for `ParentChainWalker` (#169) — the `ps` table parser + parent-chain
/// walk behind the `--print-tcc-path` "Execution context" section. The walk must terminate
/// on every adversarial table shape (cycle, orphan ppid, oversized chain) because it runs
/// inside a diagnostic command users reach for precisely when their system is misbehaving.
final class ParentChainWalkTests: XCTestCase {

    // MARK: - parseProcessTable

    func testParse_normalLines_buildsTable() {
        let output = """
              1     0 /sbin/launchd
            500   400 /bin/zsh
            400     1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
            """
        let table = ParentChainWalker.parseProcessTable(output)
        XCTAssertEqual(table.count, 3)
        XCTAssertEqual(table[500], ParentChainWalker.ProcessEntry(ppid: 400, command: "/bin/zsh"))
        XCTAssertEqual(table[1]?.ppid, 0)
        XCTAssertEqual(table[400]?.command, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    }

    func testParse_pathWithSpaces_keepsFullCommand() {
        let output = "  400     1 /Applications/My Helper.app/Contents/MacOS/My Helper"
        let table = ParentChainWalker.parseProcessTable(output)
        XCTAssertEqual(table[400]?.command, "/Applications/My Helper.app/Contents/MacOS/My Helper")
    }

    func testParse_malformedLines_areSkipped() {
        let output = """
            garbage line without numbers
            500   400 /bin/zsh
            abc   def /not/numeric
            42
            """
        let table = ParentChainWalker.parseProcessTable(output)
        XCTAssertEqual(table.count, 1)
        XCTAssertNotNil(table[500])
    }

    func testParse_emptyOutput_yieldsEmptyTable() {
        XCTAssertTrue(ParentChainWalker.parseProcessTable("").isEmpty)
    }

    // MARK: - walk

    func testWalk_normalChain_reachesLaunchdAndStops() {
        let table: [Int32: ParentChainWalker.ProcessEntry] = [
            500: .init(ppid: 400, command: "/bin/zsh"),
            400: .init(ppid: 1, command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            1: .init(ppid: 0, command: "/sbin/launchd"),
        ]
        let chain = ParentChainWalker.walk(table: table, from: 500)
        XCTAssertEqual(chain, [
            ParentChainWalker.ChainHop(pid: 500, command: "/bin/zsh"),
            ParentChainWalker.ChainHop(pid: 400, command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            ParentChainWalker.ChainHop(pid: 1, command: "/sbin/launchd"),
        ])
    }

    func testWalk_cycle_terminatesWithVisibleMarker() {
        // #173: cycles must stop AND say so — a silently-ended chain reads as complete,
        // which for a diagnostic that exists to show the real context is misinformation.
        let table: [Int32: ParentChainWalker.ProcessEntry] = [
            500: .init(ppid: 400, command: "/a"),
            400: .init(ppid: 500, command: "/b"),
        ]
        let chain = ParentChainWalker.walk(table: table, from: 500)
        XCTAssertEqual(chain.map(\.pid), [500, 400, 500])
        XCTAssertEqual(chain.last?.command, "(cycle detected)")
    }

    func testWalk_orphanPpid_emitsUnknownHopAndStops() {
        let table: [Int32: ParentChainWalker.ProcessEntry] = [
            500: .init(ppid: 999, command: "/bin/zsh")
        ]
        let chain = ParentChainWalker.walk(table: table, from: 500)
        XCTAssertEqual(chain, [
            ParentChainWalker.ChainHop(pid: 500, command: "/bin/zsh"),
            ParentChainWalker.ChainHop(pid: 999, command: "(unknown)"),
        ])
    }

    func testWalk_startPidMissingFromTable_emitsSingleUnknownHop() {
        let chain = ParentChainWalker.walk(table: [:], from: 500)
        XCTAssertEqual(chain, [ParentChainWalker.ChainHop(pid: 500, command: "(unknown)")])
    }

    func testWalk_hopCap_boundsOversizedChainWithVisibleMarker() {
        // 20-deep linear chain 500 → 501 → … ; cap at default 15 hops. The default must
        // exceed a real Claude Code session's depth — an observed chain (swift → zsh →
        // claude bg×2 → claude → login shell → login → Ghostty → launchd) already spends
        // exactly 10 hops, so 10 would truncate the host on any deeper nesting (tmux etc.).
        // #173: truncation must be visible — 15 real hops + 1 marker entry at the cut point.
        var table: [Int32: ParentChainWalker.ProcessEntry] = [:]
        for i in Int32(500)..<Int32(520) {
            table[i] = .init(ppid: i + 1, command: "/p\(i)")
        }
        let chain = ParentChainWalker.walk(table: table, from: 500)
        XCTAssertEqual(chain.count, 16)
        XCTAssertEqual(chain.first?.pid, 500)
        XCTAssertEqual(chain.last?.pid, 515, "marker carries the pid the walk stopped at")
        XCTAssertEqual(chain.last?.command, "(chain truncated after 15 hops)")
    }

    func testWalk_chainEndingWithinCap_hasNoTruncationMarker() {
        // Complete chains stay marker-free — the marker only appears when information
        // was actually cut, otherwise it would train users to ignore it.
        let table: [Int32: ParentChainWalker.ProcessEntry] = [
            500: .init(ppid: 1, command: "/bin/zsh"),
            1: .init(ppid: 0, command: "/sbin/launchd"),
        ]
        let chain = ParentChainWalker.walk(table: table, from: 500)
        XCTAssertEqual(chain.count, 2)
        XCTAssertFalse(chain.contains { $0.command.hasPrefix("(chain truncated") || $0.command == "(cycle detected)" })
    }

    func testWalk_nonPositiveStartPid_returnsEmpty() {
        XCTAssertTrue(ParentChainWalker.walk(table: [:], from: 0).isEmpty)
        XCTAssertTrue(ParentChainWalker.walk(table: [:], from: -1).isEmpty)
    }

    func testWalk_ppidZeroBeforeLaunchd_stopsCleanly() {
        // #173 (logic F5 gap): a chain whose entry points at ppid 0 without passing
        // through pid 1 must stop without marker (pid 0 is the legitimate root sentinel).
        let table: [Int32: ParentChainWalker.ProcessEntry] = [
            500: .init(ppid: 0, command: "/odd/root")
        ]
        let chain = ParentChainWalker.walk(table: table, from: 500)
        XCTAssertEqual(chain, [ParentChainWalker.ChainHop(pid: 500, command: "/odd/root")])
    }

    func testWalk_startAtLaunchd_returnsSingleHop() {
        // #173 (logic F5 gap): degenerate but legal start point.
        let table: [Int32: ParentChainWalker.ProcessEntry] = [
            1: .init(ppid: 0, command: "/sbin/launchd")
        ]
        let chain = ParentChainWalker.walk(table: table, from: 1)
        XCTAssertEqual(chain, [ParentChainWalker.ChainHop(pid: 1, command: "/sbin/launchd")])
    }

    // MARK: - empty-comm rows (#173, logic F2)

    func testParse_emptyCommRow_isKeptWithUnknownCommand() {
        // A pid/ppid pair whose comm column is empty must keep its ppid linkage —
        // dropping the whole row severs the chain one hop early at "(unknown)".
        let output = """
            500   400
            400     1 /bin/zsh
            """
        let table = ParentChainWalker.parseProcessTable(output)
        XCTAssertEqual(table[500], ParentChainWalker.ProcessEntry(ppid: 400, command: "(unknown)"))
        XCTAssertEqual(table[400]?.command, "/bin/zsh")
    }
}
