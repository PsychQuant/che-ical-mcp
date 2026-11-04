import EventKit
import XCTest

@testable import CheICalMCP

/// Pure-unit tests for the re-prompt section `--print-tcc-path` prints
/// (`EventKitManager.printTCCPathRepromptSection`), extracted from `main.swift` so the section
/// can be pinned without spawning the binary (#357, #368).
final class PrintTCCPathSectionTests: XCTestCase {

    private let path = "/Users/test/bin/CheICalMCP"
    private let bundleID = "com.checheng.CheICalMCP"

    private func section(_ calendar: EKAuthorizationStatus, _ reminders: EKAuthorizationStatus) -> String {
        EventKitManager.printTCCPathRepromptSection(
            bundleID: bundleID, binaryPath: path, calendarStatus: calendar, remindersStatus: reminders)
    }

    func testSection_carriesTheSetupCommandForThisBinary() {
        XCTAssertTrue(section(.denied, .denied).contains("'\(path)' --setup"))
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
