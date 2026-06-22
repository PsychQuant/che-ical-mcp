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
        // `isNonInteractiveSession` = getppid()==1 || TERM==nil || CI!=nil (#131).
        // A `TERM`-set guard alone is NOT sufficient to expect `false` — if `CI` is
        // also set (`CI=1 swift test` locally, or a CI runner that sets TERM), the
        // session is still non-interactive. Mirror the full production contract so
        // the assertion is robust to env (#147 — previously only passed on GHA because
        // GHA leaves TERM unset, which silently skipped the assertion).
        let env = ProcessInfo.processInfo.environment
        let expectedNonInteractive =
            getppid() == 1 || env["TERM"] == nil || env["CI"] != nil
        XCTAssertEqual(
            EventKitManager.isNonInteractive,
            expectedNonInteractive,
            "isNonInteractive must reflect getppid()==1 || TERM==nil || CI!=nil — robust to CI env")
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
        // #144 regression guard (Codex finding): the combined SSH + non-interactive
        // branch must NOT use launchd-only remediation wording — it fires for any
        // non-interactive context (CI runner / no TTY), not just launchd. The
        // generalized copy names the non-interactive job explicitly.
        XCTAssertTrue(
            message.contains("non-interactive job"),
            "Combined error remediation must be generalized (not launchd-specific) — see #144")
    }

    func testAccessDeniedNormalMessage() {
        let error = EventKitError.accessDenied(type: "Calendar", isSSH: false, isNonInteractive: false)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("System Settings"), "Normal error should mention System Settings")
        XCTAssertFalse(message.contains("non-interactive"), "Normal error should not mention non-interactive")
        XCTAssertFalse(message.contains("SSH"), "Normal error should not mention SSH")
    }

    // MARK: - #163 — binary-specific `--setup` remediation hint

    /// The pure hint formatter wraps the injected path in quotes and appends `--setup`.
    func testSetupCommandHint_formatsQuotedPathWithFlag() {
        let hint = EventKitManager.setupCommandHint(binaryPath: "/Users/x/bin/CheICalMCP")
        XCTAssertEqual(hint, "\"/Users/x/bin/CheICalMCP\" --setup")
    }

    /// Control chars in the path must be escaped (the hint can land in a terminal / response).
    func testSetupCommandHint_escapesControlChars() {
        let hint = EventKitManager.setupCommandHint(binaryPath: "/bin/ev\u{07}il")
        XCTAssertFalse(hint.contains("\u{07}"), "BEL must be escaped, not passed raw")
        XCTAssertTrue(hint.contains("--setup"))
    }

    /// The resolved hint reads argv[0] (the xctest runner here) and still ends in `--setup`.
    func testResolvedSetupCommandHint_containsSetupFlag() {
        let hint = EventKitManager.resolvedSetupCommandHint()
        XCTAssertTrue(hint.contains("--setup"), "resolved hint must contain the --setup flag")
        XCTAssertTrue(hint.hasPrefix("\""), "resolved hint must quote the binary path")
    }

    /// The generic (no-context) denial message now includes the resolved `--setup` command,
    /// in addition to the System Settings instructions.
    func testAccessDeniedNormalMessage_includesResolvedSetupCommand() {
        let error = EventKitError.accessDenied(type: "Calendar", isSSH: false, isNonInteractive: false)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("--setup"),
            "generic denial must surface the --setup remediation command (#163)")
        XCTAssertTrue(message.contains(EventKitManager.resolvedSetupCommandHint()),
            "generic denial must embed the resolved binary-specific setup hint")
    }

    // MARK: - #163 — SetupRunner.evaluateEntity (injectable branch logic)

    func testEvaluateEntity_fullAccess_isAlreadyGranted() async {
        let outcome = await SetupRunner.evaluateEntity(status: .fullAccess, nonInteractive: false) {
            XCTFail("request must NOT be called when already granted"); return false
        }
        XCTAssertEqual(outcome, .alreadyGranted)
        XCTAssertFalse(outcome.isBad)
    }

    func testEvaluateEntity_notDetermined_interactive_requestGranted() async {
        let outcome = await SetupRunner.evaluateEntity(status: .notDetermined, nonInteractive: false) { true }
        XCTAssertEqual(outcome, .granted)
        XCTAssertFalse(outcome.isBad)
    }

    func testEvaluateEntity_notDetermined_interactive_requestDenied() async {
        let outcome = await SetupRunner.evaluateEntity(status: .notDetermined, nonInteractive: false) { false }
        XCTAssertEqual(outcome, .denied)
        XCTAssertTrue(outcome.isBad)
    }

    func testEvaluateEntity_notDetermined_nonInteractive_skipsWouldBlock() async {
        let outcome = await SetupRunner.evaluateEntity(status: .notDetermined, nonInteractive: true) {
            XCTFail("request must NOT be called in non-interactive skip path"); return false
        }
        XCTAssertEqual(outcome, .skippedWouldBlock)
        XCTAssertTrue(outcome.isBad)
    }

    func testEvaluateEntity_denied_reportsDenied() async {
        let outcome = await SetupRunner.evaluateEntity(status: .denied, nonInteractive: false) {
            XCTFail("request must NOT be called when already denied"); return false
        }
        XCTAssertEqual(outcome, .denied)
        XCTAssertTrue(outcome.isBad)
    }

    func testEvaluateEntity_writeOnly_isPartial() async {
        let outcome = await SetupRunner.evaluateEntity(status: .writeOnly, nonInteractive: false) {
            XCTFail("request must NOT be called for write-only"); return false
        }
        XCTAssertEqual(outcome, .writeOnly)
        XCTAssertTrue(outcome.isBad)
    }

    func testEvaluateEntity_requestThrows_errorIsSanitized() async {
        struct ControlCharError: LocalizedError {
            var errorDescription: String? { "bad\u{07}desc" }
        }
        let outcome = await SetupRunner.evaluateEntity(status: .notDetermined, nonInteractive: false) {
            throw ControlCharError()
        }
        guard case .error(let safe) = outcome else {
            return XCTFail("throwing request must map to .error, got \(outcome)")
        }
        XCTAssertFalse(safe.contains("\u{07}"), "framework error text must be control-char sanitized")
        XCTAssertTrue(safe.contains("bad") && safe.contains("desc"), "sanitized text keeps printable content")
        XCTAssertTrue(outcome.isBad)
    }

    /// `message(label:)` formats the per-entity status line the setup output prints.
    func testSetupEntityOutcome_messageFormatting() {
        XCTAssertEqual(SetupEntityOutcome.granted.message(label: "Calendar"), "Calendar access: ✓ granted")
        XCTAssertEqual(SetupEntityOutcome.alreadyGranted.message(label: "Reminders"), "Reminders access: ✓ already granted")
        XCTAssertTrue(SetupEntityOutcome.skippedWouldBlock.message(label: "Calendar").contains("⤼ skipped"))
        XCTAssertTrue(SetupEntityOutcome.writeOnly.message(label: "Calendar").contains("write-only"))
    }
}
