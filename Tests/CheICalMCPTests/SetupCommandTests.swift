import EventKit
import XCTest

@testable import CheICalMCP

final class SetupCommandTests: XCTestCase {

    // MARK: - Setup Access Decision (#143)

    /// The `--setup` path must check `authorizationStatus` BEFORE calling the
    /// blocking `requestFullAccess`. In a non-interactive session a `.notDetermined`
    /// status would hang forever on a TCC dialog that can never appear, so the
    /// decision must be `.skipWouldBlock` there — while an already-granted
    /// (`.fullAccess`) status must still report success WITHOUT skipping (the
    /// already-granted re-run case the diagnosis flagged).
    func testSetupDecision_notDetermined_nonInteractive_skipsToAvoidBlock() {
        XCTAssertEqual(
            setupAccessDecision(status: .notDetermined, isNonInteractive: true),
            .skipWouldBlock,
            ".notDetermined + non-interactive must skip requestFullAccess (would hang, #143)")
    }

    func testSetupDecision_notDetermined_interactive_requestsAccess() {
        XCTAssertEqual(
            setupAccessDecision(status: .notDetermined, isNonInteractive: false),
            .requestAccess,
            ".notDetermined + interactive must request access (TCC dialog can appear)")
    }

    func testSetupDecision_fullAccess_alreadyGranted_regardlessOfInteractivity() {
        // The already-granted re-run case: must NOT be lumped into the skip path.
        XCTAssertEqual(setupAccessDecision(status: .fullAccess, isNonInteractive: true), .alreadyGranted)
        XCTAssertEqual(setupAccessDecision(status: .fullAccess, isNonInteractive: false), .alreadyGranted)
    }

    func testSetupDecision_deniedAndRestricted_reportDenied() {
        XCTAssertEqual(setupAccessDecision(status: .denied, isNonInteractive: true), .denied)
        XCTAssertEqual(setupAccessDecision(status: .restricted, isNonInteractive: false), .denied)
    }

    func testSetupDecision_writeOnly_isPartial() {
        XCTAssertEqual(setupAccessDecision(status: .writeOnly, isNonInteractive: false), .writeOnly)
    }

    // MARK: - Help Message

    func testHelpMessageIncludesSetupFlag() {
        let help = AppVersion.helpMessage
        XCTAssertTrue(help.contains("--setup"), "Help message should document the --setup flag")
    }

    // MARK: - Non-Interactive Detection

    func testIsNonInteractiveDetection() {
        // Test runner runs from Xcode/Terminal with TERM set, so should not be non-interactive.
        // Note: CI environments may differ — this test validates the local dev experience.
        let hasTerm = ProcessInfo.processInfo.environment["TERM"] != nil
        if hasTerm {
            XCTAssertFalse(
                EventKitManager.isNonInteractive,
                "Test runner with TERM set should not be detected as non-interactive")
        }
    }

    // MARK: - Error Messages

    func testAccessDeniedLaunchdMessage() {
        let error = EventKitError.accessDenied(type: "Calendar", isSSH: false, isNonInteractive: true)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("non-interactive"), "Error should mention non-interactive session")
        XCTAssertTrue(message.contains("--setup"), "Error should mention --setup workaround")
    }

    func testAccessDeniedSSHOnlyMessage() {
        let error = EventKitError.accessDenied(type: "Calendar", isSSH: true, isNonInteractive: false)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("SSH"), "SSH error should mention SSH")
        XCTAssertFalse(message.contains("--setup"), "SSH-only error should not mention --setup")
    }

    func testAccessDeniedSSHAndLaunchdMessage() {
        // When both SSH and non-interactive are true, message should cover both
        let error = EventKitError.accessDenied(type: "Calendar", isSSH: true, isNonInteractive: true)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("SSH"), "Combined error should mention SSH")
        XCTAssertTrue(message.contains("non-interactive"), "Combined error should mention non-interactive")
        XCTAssertTrue(message.contains("--setup"), "Combined error should mention --setup")
        XCTAssertTrue(message.contains("sshd"), "Combined error should mention sshd workaround")
    }

    func testAccessDeniedNormalMessage() {
        let error = EventKitError.accessDenied(type: "Calendar", isSSH: false, isNonInteractive: false)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("System Settings"), "Normal error should mention System Settings")
        XCTAssertFalse(message.contains("non-interactive"), "Normal error should not mention non-interactive")
        XCTAssertFalse(message.contains("SSH"), "Normal error should not mention SSH")
    }
}
