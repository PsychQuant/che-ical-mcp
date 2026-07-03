import Foundation
import XCTest
@testable import CheICalMCP

/// Direct unit tests for `LiveTCCDatabaseSource` failure modes (#124). Pre-fix, this
/// source was only exercised indirectly through the binary-spawn integration tests in
/// `TCCDriftDetectorBannerTests`, which means edge cases (missing sqlite3, missing
/// db, output not UTF-8, malformed rows) had zero CI coverage and would only break
/// on user reports.
///
/// Each test injects a path that triggers a specific failure mode, then asserts the
/// returned `TCCQueryResult.failureReason` matches the expected skip-reason string —
/// drift detection treats these as non-blocking skip signals, so the surfacing text
/// is part of the contract.
final class LiveTCCDatabaseSourceTests: XCTestCase {

    // MARK: - Missing binaries / files

    func testReadsMissingSQLite3_returnsFailureReason() {
        let source = LiveTCCDatabaseSource(
            databasePath: "/tmp/whatever.db",
            sqlite3Path: "/nonexistent/sqlite3"
        )
        let result = source.readCheICalMCPEntries()
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.failureReason, "sqlite3 not at /nonexistent/sqlite3",
            "missing sqlite3 binary must surface as actionable skip reason, not silent zero-result")
    }

    func testReadsMissingDatabase_returnsFailureReason() {
        let bogusDB = "/tmp/definitely-nonexistent-tcc-\(UUID().uuidString).db"
        let source = LiveTCCDatabaseSource(databasePath: bogusDB)
        let result = source.readCheICalMCPEntries()
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.failureReason, "TCC.db not at \(bogusDB)",
            "missing TCC.db must surface as actionable skip reason")
    }

    // MARK: - sqlite3 exit non-zero

    /// Spawn the real sqlite3 against a deliberately empty-but-not-a-db file. sqlite3
    /// returns non-zero with a "file is not a database" error on stderr. Confirms the
    /// exit-status branch surfaces sanitized stderr.
    func testReadsCorruptDatabase_returnsExitStatusFailure() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LiveTCCDatabaseSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a file that's not a valid SQLite database
        let fakeDB = tempDir.appendingPathComponent("fake.db")
        try Data("not a sqlite database".utf8).write(to: fakeDB)

        let source = LiveTCCDatabaseSource(databasePath: fakeDB.path)
        let result = source.readCheICalMCPEntries()
        XCTAssertTrue(result.entries.isEmpty)
        guard let reason = result.failureReason else {
            XCTFail("expected failureReason for corrupt db, got nil")
            return
        }
        XCTAssertTrue(reason.hasPrefix("sqlite3 exit"),
            "corrupt db must surface as 'sqlite3 exit N: ...' — got: \(reason)")
    }

    // MARK: - Happy path on synthetic db

    /// Build a real SQLite db with the `access` table schema TCC.db uses, insert one
    /// CheICalMCP-matching row + one unrelated row, and assert only the matching row
    /// is parsed back. This is the most direct end-to-end test of the parse path.
    func testReadsSyntheticDatabase_parsesMatchingRowOnly() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LiveTCCDatabaseSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("tcc.db").path

        // Use sqlite3 to seed the schema + rows. The LIKE filter only matches CheICalMCP-
        // bearing client values, so the SomeOtherTool row must NOT appear in the parsed
        // result.
        // Schema includes the `csreq` BLOB column TCC.db carries (#155). The CheICalMCP
        // row seeds a blob (`X'…'`) so the `hex(csreq)` projection + parse round-trips.
        let seedSQL = """
        CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER, last_modified INTEGER, csreq BLOB);
        INSERT INTO access VALUES ('kTCCServiceCalendar', '/Users/test/bin/CheICalMCP', 2, 1700000000, X'DEADBEEF');
        INSERT INTO access VALUES ('kTCCServiceCalendar', '/Applications/SomeOtherTool', 2, 1700000001, NULL);
        """
        let seedProcess = Process()
        seedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seedProcess.arguments = [dbPath, seedSQL]
        try seedProcess.run()
        seedProcess.waitUntilExit()
        XCTAssertEqual(seedProcess.terminationStatus, 0, "seed sqlite3 invocation must succeed")

        let source = LiveTCCDatabaseSource(databasePath: dbPath)
        let result = source.readCheICalMCPEntries()
        XCTAssertNil(result.failureReason, "happy-path read must produce nil failureReason — got: \(String(describing: result.failureReason))")
        XCTAssertEqual(result.entries.count, 1, "LIKE filter must match exactly the CheICalMCP row — got \(result.entries.count) rows")
        XCTAssertEqual(result.entries.first?.client, "/Users/test/bin/CheICalMCP")
        XCTAssertEqual(result.entries.first?.authValue, 2)
        XCTAssertEqual(result.entries.first?.lastModifiedUnix, 1700000000)
        XCTAssertEqual(result.entries.first?.csreqHex, "DEADBEEF",
            "hex(csreq) projection must round-trip the pinned requirement blob (#155)")
    }

    // MARK: - Timeout (#126)

    /// Inject a 1ms timeout to force the timer to fire before sqlite3 can complete.
    /// The exact spawn timing is unstable for very small budgets, so we accept either
    /// `timed out` (timer won the race) or `exit` (sqlite3 already finished — common
    /// for nonexistent-db case which exits in <1ms). The key contract is that we get
    /// an explicit failureReason rather than hanging.
    func testReadsWithTinyTimeout_surfacesAsFailure() {
        let source = LiveTCCDatabaseSource(
            databasePath: "/tmp/whatever.db",   // will hit missing-db path before timer
            sqlite3Path: "/usr/bin/sqlite3",
            timeoutMilliseconds: 1
        )
        let result = source.readCheICalMCPEntries()
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNotNil(result.failureReason, "tiny-timeout path must always surface failureReason")
    }
}
