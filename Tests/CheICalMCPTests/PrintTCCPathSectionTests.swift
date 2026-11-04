import EventKit
import XCTest

@testable import CheICalMCP

/// Pure-unit tests for the re-prompt section `--print-tcc-path` prints
/// (`EventKitManager.printTCCPathRepromptSection`), extracted from `main.swift` so the section
/// can be pinned without spawning the binary (#357, #368).
final class PrintTCCPathSectionTests: XCTestCase {

    private let path = "/Users/test/bin/CheICalMCP"

    private func section(_ calendar: EKAuthorizationStatus, _ reminders: EKAuthorizationStatus) -> String {
        EventKitManager.printTCCPathRepromptSection(
            binaryPath: path, calendarStatus: calendar, remindersStatus: reminders)
    }

    func testSection_carriesTheSetupCommandForThisBinary() {
        XCTAssertTrue(section(.denied, .denied).contains("'\(path)' --setup"))
    }

    // #357: `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare
    // binary, so the section is "Re-prompt" and points at System Settings instead.
    func testSection_offersNoTccutil_andPointsAtSystemSettings() {
        for status in [EKAuthorizationStatus.notDetermined, .denied, .restricted, .fullAccess] {
            let s = section(status, status)
            XCTAssertFalse(s.contains("tccutil"), s)
            XCTAssertTrue(s.hasPrefix("Re-prompt"), s)
            XCTAssertTrue(s.contains("System Settings → Privacy & Security"), s)
            XCTAssertTrue(s.contains("− button"), s)
        }
    }

    // #368: a `restricted` status is a policy; the re-prompt section cannot reach it.
    func testRestrictedStatus_addsANoteThatTheSectionCannotChangeIt() {
        for (cal, rem) in [(EKAuthorizationStatus.restricted, EKAuthorizationStatus.fullAccess),
                           (.fullAccess, .restricted), (.restricted, .restricted)] {
            let s = section(cal, rem)
            XCTAssertTrue(s.contains("restricted"), s)
            XCTAssertTrue(s.contains("configuration profile"), s)
        }
    }

    func testUnrestrictedStatus_addsNoPolicyNote() {
        for status in [EKAuthorizationStatus.notDetermined, .denied, .fullAccess, .writeOnly] {
            XCTAssertFalse(section(status, status).contains("configuration profile"))
        }
    }
}
