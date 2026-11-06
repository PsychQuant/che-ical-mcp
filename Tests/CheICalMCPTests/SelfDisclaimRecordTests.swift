import EventKit
import XCTest
@testable import CheICalMCP

/// #361: the record carried across the re-exec. The variable is unauthenticated and its content is
/// printed, so `decode` takes only what `encoded` writes.
final class SelfDisclaimRecordTests: XCTestCase {
    func testEveryRecordRoundTrips() {
        for reason in SelfDisclaimRecord.Reason.allCases {
            for status in SelfDisclaimRecord.Status.allCases {
                for host in SelfDisclaimRecord.Host.allCases {
                    let record = SelfDisclaimRecord(reason: reason, calendar: status, reminders: .fullAccess, host: host)
                    XCTAssertEqual(SelfDisclaimRecord.decode(record.encoded), record, record.encoded)
                    XCTAssertLessThanOrEqual(record.encoded.utf8.count, 128, record.encoded)
                }
            }
        }
    }

    func testTheEncodingIsStable() {
        let record = SelfDisclaimRecord(reason: .hostGrantUnusable, calendar: .notDetermined, reminders: .fullAccess, host: .claudeCode)
        XCTAssertEqual(record.encoded, "v1;reason=hostGrantUnusable;cal=notDetermined;rem=fullAccess;host=claudeCode")
    }

    func testAnythingElseIsRejected() {
        let good = "v1;reason=forced;cal=denied;rem=denied;host=appBundle"
        XCTAssertNotNil(SelfDisclaimRecord.decode(good))
        for bad in ["", "1", "v2;reason=forced;cal=denied;rem=denied;host=appBundle", good + ";", good + ";x=y", ";" + good,
                    "v1;reason=nonsense;cal=denied;rem=denied;host=appBundle", "v1;reason=forced;cal=nonsense;rem=denied;host=appBundle",
                    "v1;reason=forced;cal=denied;rem=nonsense;host=appBundle", "v1;reason=forced;cal=denied;rem=denied;host=/tmp/x",
                    "v1;cal=denied;reason=forced;rem=denied;host=appBundle", "V1;reason=forced;cal=denied;rem=denied;host=appBundle",
                    "v1;reason=forced ;cal=denied;rem=denied;host=appBundle", "v1;reason=forced;cal=denied;rem=denied;host=appBundle\n",
                    good + String(repeating: "x", count: 200)] {
            XCTAssertNil(SelfDisclaimRecord.decode(bad), bad)
            XCTAssertEqual(CarriedReexec(sentinel: bad), .unreadable, bad)
        }
    }

    func testTheRecordIsBuiltFromTheDecisionAndTheStatuses() {
        let read = HostAuthorization(calendar: .notDetermined, reminders: .denied)
        XCTAssertEqual(SelfDisclaimRecord(reason: .forced, host: read, kind: .appBundle(name: "Secret")),
                       SelfDisclaimRecord(reason: .forced, calendar: .notDetermined, reminders: .denied, host: .appBundle))
        XCTAssertEqual(SelfDisclaimRecord(reason: .setup, host: nil, kind: nil),
                       SelfDisclaimRecord(reason: .setup, calendar: .notRead, reminders: .notRead, host: .unknown))
        XCTAssertEqual(SelfDisclaimRecord(reason: .hostGrantUnusable, host: read, kind: .claudeCode(version: "1")).reason, .hostGrantUnusable)
    }

    /// No host name or path crosses the exec, whatever the kind carried.
    func testNoNameOrPathIsCarried() {
        let read = HostAuthorization(calendar: .denied, reminders: .denied)
        for kind: ResponsibleHostKind in [.appBundle(name: "Secret"), .otherExecutable(path: "/tmp/Secret"), .claudeCode(version: "Secret")] {
            XCTAssertFalse(SelfDisclaimRecord(reason: .forced, host: read, kind: kind).encoded.contains("Secret"))
        }
    }

    func testTheStatusesFollowEventKit() {
        XCTAssertEqual(SelfDisclaimRecord.Status(.notDetermined), .notDetermined)
        XCTAssertEqual(SelfDisclaimRecord.Status(.restricted), .restricted)
        XCTAssertEqual(SelfDisclaimRecord.Status(.denied), .denied)
        XCTAssertEqual(SelfDisclaimRecord.Status(.fullAccess), .fullAccess)
        XCTAssertEqual(SelfDisclaimRecord.Status(.writeOnly), .writeOnly)
    }

    func testTheStartLineIsOneEscapedLine() {
        let record = SelfDisclaimRecord(reason: .hostGrantUnusable, calendar: .denied, reminders: .fullAccess, host: .appBundle)
        let line = record.startLine(hostName: "Evil\n[che-ical-mcp] forged")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, line)
        XCTAssertTrue(line.hasSuffix("\n"), line)
        XCTAssertTrue(line.contains("had Calendar denied, Reminders fullAccess"), line)
    }

    func testEachReasonHasItsLine() {
        let forced = SelfDisclaimRecord(reason: .forced, calendar: .fullAccess, reminders: .fullAccess, host: .appBundle)
        XCTAssertTrue(forced.startLine(hostName: "Terminal").contains("CHE_ICAL_MCP_FORCE_DISCLAIM is set"))
        XCTAssertTrue(forced.startLine(hostName: "Terminal").contains("Terminal had Calendar fullAccess"))
        let setup = SelfDisclaimRecord(reason: .setup, calendar: .notRead, reminders: .notRead, host: .unknown)
        XCTAssertTrue(setup.startLine(hostName: "Terminal").hasPrefix("[che-ical-mcp] --setup:"))
        XCTAssertTrue(setup.attributionLine.contains("the host's status was not read"), setup.attributionLine)
    }

    func testTheHostNameComesFromTheKind() {
        XCTAssertEqual(SelfDisclaimRecord.hostName(.claudeCode(version: "2.1")), "Claude Code 2.1")
        XCTAssertEqual(SelfDisclaimRecord.hostName(.claudeCode(version: nil)), "Claude Code")
        XCTAssertEqual(SelfDisclaimRecord.hostName(.appBundle(name: "Ghostty")), "Ghostty")
        XCTAssertEqual(SelfDisclaimRecord.hostName(.otherExecutable(path: "/opt/x")), "/opt/x")
        XCTAssertEqual(SelfDisclaimRecord.hostName(nil), "an unknown host")
    }
}
