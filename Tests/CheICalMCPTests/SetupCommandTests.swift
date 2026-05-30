import XCTest

@testable import CheICalMCP

final class SetupCommandTests: XCTestCase {

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
