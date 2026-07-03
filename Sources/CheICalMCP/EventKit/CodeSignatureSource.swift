import Foundation
import Security

/// Test seam for the running binary's self-code-signing checks, used by TCC drift
/// detection to catch the #154 silent-denial class (#155): a TCC row pinned to a stale
/// cdhash the running binary no longer satisfies, and/or a hardened-runtime binary whose
/// missing personal-information entitlement makes tccd policy-block every re-prompt.
///
/// Per CLAUDE.md "Test Seam Convention": narrow `<Domain>Source` protocol, Live impl
/// default-wired, fake injected in tests. The seam exists because the *real* running
/// binary's signature cannot be controlled in a unit test — the fake drives the drift
/// logic deterministically while `LiveCodeSignatureSource` runs in production.
protocol CodeSignatureSource: Sendable {
    /// Does the running binary satisfy the code requirement serialized in `csreqBlob`
    /// (the raw `csreq` bytes TCC pinned at grant time)?
    ///
    /// - `.satisfies` — the running binary meets the pinned requirement (healthy row).
    /// - `.mismatch` — `errSecCSReqFailed`: the pinned requirement is NOT met. This is
    ///   the actionable drift — TCC will silently deny while status APIs report green.
    /// - `.undecidable` — the blob was unparseable or the check errored for any *other*
    ///   reason (unsigned, resource error, …). Callers MUST treat this as "no signal",
    ///   NEVER as a mismatch, so a diagnostic never cries wolf on an install it can't read.
    func evaluateRunningBinary(againstRequirementBlob csreqBlob: Data) -> RequirementEvaluation

    /// Does the running binary's signature carry a personal-information entitlement
    /// (Calendars / Reminders)? Missing entitlements are the hardened-runtime half of the
    /// #154 signature — tccd policy-blocks prompts for a hardened binary without them.
    /// `nil` when the entitlements can't be read (used only to *annotate* a mismatch,
    /// never as the sole trigger).
    func runningBinaryHasPersonalInfoEntitlement() -> Bool?
}

/// Result of checking the running binary against a pinned code requirement.
enum RequirementEvaluation: Sendable, Equatable {
    case satisfies
    case mismatch
    case undecidable(reason: String)
}

/// Production implementation over the Security framework's self-code-signing APIs.
///
/// Not unit-tested end-to-end: the checks run against whatever binary is executing, and
/// the drift state they detect (a stale ad-hoc-pinned row on an updated binary) cannot be
/// reproduced on a healthy/granted host. `TCCDriftDetectorTests` drive the drift logic
/// through a fake; this Live impl's correctness is validated only when it reaches an
/// actually-affected machine. Kept deliberately small to minimize that unverified surface.
struct LiveCodeSignatureSource: CodeSignatureSource {
    func evaluateRunningBinary(againstRequirementBlob csreqBlob: Data) -> RequirementEvaluation {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            return .undecidable(reason: "SecCodeCopySelf OSStatus \(selfStatus)")
        }
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithData(csreqBlob as CFData, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            return .undecidable(reason: "csreq blob unparseable (OSStatus \(reqStatus))")
        }
        let checkStatus = SecCodeCheckValidity(code, [], requirement)
        switch checkStatus {
        case errSecSuccess:
            return .satisfies
        case errSecCSReqFailed:
            return .mismatch
        default:
            // Any other OSStatus (errSecCSUnsigned, resource errors, …) is NOT a
            // requirement mismatch — refuse to classify it as drift.
            return .undecidable(reason: "SecCodeCheckValidity OSStatus \(checkStatus)")
        }
    }

    func runningBinaryHasPersonalInfoEntitlement() -> Bool? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        // No entitlements dict at all → empty entitlements (the ad-hoc-build half of #154).
        guard let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return false
        }
        // Must match Entitlements.plist keys (EntitlementsPlistTests pins them in CI).
        let personalInfoKeys = [
            "com.apple.security.personal-information.calendars",
            "com.apple.security.personal-information.reminders",
        ]
        return personalInfoKeys.contains { entitlements[$0] != nil }
    }
}
