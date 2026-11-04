import EventKit
import XCTest

@testable import CheICalMCP

/// Pure-unit tests for the re-prompt section `--print-tcc-path` prints
/// (`EventKitManager.printTCCPathRepromptSection`), extracted from `main.swift` so the section
/// can be pinned without spawning the binary (#357, #368).
final class PrintTCCPathSectionTests: XCTestCase {

    private let path = "/Users/test/bin/CheICalMCP"

    private func section(_ calendar: EKAuthorizationStatus, _ reminders: EKAuthorizationStatus,
                         hasEntitlement: Bool? = true) -> String {
        EventKitManager.printTCCPathRepromptSection(
            binaryPath: path, calendarStatus: calendar, remindersStatus: reminders,
            hasEntitlement: hasEntitlement)
    }

    // Round-2 policy P4: --setup is offered only while a status is notDetermined, and the
    // section says that is the only status it prompts from.
    func testSection_offersSetupOnlyForNotDetermined() {
        for (cal, rem) in [(EKAuthorizationStatus.notDetermined, EKAuthorizationStatus.fullAccess),
                           (.fullAccess, .notDetermined)] {
            let s = section(cal, rem)
            XCTAssertTrue(s.contains("'\(path)' --setup"), s)
            XCTAssertTrue(s.contains("prompts only while a status is notDetermined"), s)
        }
        for status in [EKAuthorizationStatus.denied, .writeOnly, .restricted, .fullAccess] {
            XCTAssertFalse(section(status, status).contains("' --setup"), "\(status.rawValue)")
        }
    }

    func testSection_deniedGetsTheSwitch_writeOnlyGetsOptionsFullAccess() {
        XCTAssertTrue(section(.denied, .fullAccess).contains("Calendar is denied: switch CheICalMCP on in System Settings → Privacy & Security → Calendar"))
        XCTAssertTrue(section(.fullAccess, .writeOnly).contains("Reminders is write-only: System Settings → Privacy & Security → Reminders → CheICalMCP → Options… → Full Access"))
    }

    // Round-2 policy P2(b): a binary known to lack the entitlement gets no reset line.
    func testSection_withoutTheEntitlement_printsNoResetAndSaysUpgradeFirst() {
        let s = section(.denied, .denied, hasEntitlement: false)
        XCTAssertFalse(s.contains("tccutil"), s)
        XCTAssertTrue(s.contains("upgrade CheICalMCP to v1.11.0 or later first"), s)
    }

    // #357: no bundle-id reset; round-2 policy P2/P3: the switch step, and the bare reset as
    // the last resort with its consequence, its precondition and "run it yourself".
    func testSection_givesTheSwitchStepAndTheHumanLastResort() {
        for status in [EKAuthorizationStatus.notDetermined, .denied, .restricted, .fullAccess] {
            for entitlement: Bool? in [true, nil] {
                let s = section(status, status, hasEntitlement: entitlement)
                XCTAssertTrue(s.hasPrefix("Re-prompt"), s)
                TCCRemedyAssertions.assertSwitchStep(s)
                XCTAssertTrue(s.contains("'\(path)' --print-tcc-path after each"), s)
                XCTAssertTrue(s.contains("not yet checked on a device"), s)
                TCCRemedyAssertions.assertHumanLastResort(s, service: "Calendar")
                TCCRemedyAssertions.assertHumanLastResort(s, service: "Reminders")
            }
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
