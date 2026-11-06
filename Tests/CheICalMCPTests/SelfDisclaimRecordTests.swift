import EventKit
import XCTest
@testable import CheICalMCP

/// #361: the record carried across the re-exec. The variable is unauthenticated and its content is
/// printed, so `decode` takes only what `encoded` writes.
final class SelfDisclaimRecordTests: XCTestCase {
    /// The line must not say a re-exec happened: an inherited variable reaches it with none.
    func testTheLineReportsTheVariableNotAReexec() {
        let record = SelfDisclaimRecord(reason: .forced, calendar: .denied, reminders: .denied, host: .appBundle)
        XCTAssertEqual(record.attributionLine,
                       "CHE_ICAL_MCP_DISCLAIMED says this process re-executed at start (forced): an app had Calendar denied, Reminders denied. Not verified.")
        XCTAssertTrue(CarriedReexec.unreadable.attributionLine.contains("whether and why"))
    }

    func testEveryPossibleRecordRoundTrips() {
        var possible = 0
        for reason in SelfDisclaimRecord.Reason.allCases {
            for calendar in SelfDisclaimRecord.Status.allCases {
                for reminders in SelfDisclaimRecord.Status.allCases {
                    for host in SelfDisclaimRecord.Host.allCases {
                        let record = SelfDisclaimRecord(reason: reason, calendar: calendar, reminders: reminders, host: host)
                        XCTAssertLessThanOrEqual(record.encoded.utf8.count, 128, record.encoded)
                        XCTAssertEqual(SelfDisclaimRecord.decode(record.encoded), record.isPossible ? record : nil, record.encoded)
                        if record.isPossible { possible += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(possible, 0)
    }

    /// `decide` cannot produce these, so a value holding one was not written by this binary.
    func testImpossibleCombinationsAreRejected() {
        for bad in ["v1;reason=hostGrantUnusable;cal=fullAccess;rem=fullAccess;host=appBundle",
                    "v1;reason=hostGrantUnusable;cal=restricted;rem=denied;host=appBundle",
                    "v1;reason=forced;cal=restricted;rem=fullAccess;host=appBundle",
                    "v1;reason=forced;cal=notRead;rem=notRead;host=appBundle",
                    "v1;reason=setup;cal=denied;rem=denied;host=appBundle",
                    "v1;reason=setup;cal=notRead;rem=denied;host=appBundle"] {
            XCTAssertNil(SelfDisclaimRecord.decode(bad), bad)
        }
        XCTAssertNotNil(SelfDisclaimRecord.decode("v1;reason=forced;cal=fullAccess;rem=fullAccess;host=appBundle"))
    }

    /// U+037E is canonically equivalent to `;`, so Swift's `==` and `components(separatedBy:)` take it.
    func testACanonicallyEquivalentSeparatorIsRejected() {
        let good = "v1;reason=forced;cal=denied;rem=denied;host=appBundle"
        XCTAssertNotNil(SelfDisclaimRecord.decode(good))
        XCTAssertNil(SelfDisclaimRecord.decode(good.replacingOccurrences(of: ";", with: "\u{037E}")))
        XCTAssertNil(SelfDisclaimRecord.decode(String(good.prefix(2)) + "\u{037E}" + good.dropFirst(3)))
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
        XCTAssertTrue(setup.attributionLine.contains("an unknown host (its status was not read)"), setup.attributionLine)
    }

    func testTheHostNameComesFromTheKind() {
        XCTAssertEqual(SelfDisclaimRecord.hostName(.claudeCode(version: "2.1")), "Claude Code 2.1")
        XCTAssertEqual(SelfDisclaimRecord.hostName(.claudeCode(version: nil)), "Claude Code")
        XCTAssertEqual(SelfDisclaimRecord.hostName(.appBundle(name: "Ghostty")), "Ghostty")
        XCTAssertEqual(SelfDisclaimRecord.hostName(.otherExecutable(path: "/opt/x")), "/opt/x")
        XCTAssertEqual(SelfDisclaimRecord.hostName(nil), "an unknown host")
    }
}
