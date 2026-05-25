import EventKit
import XCTest
@testable import CheICalMCP

/// Coverage for `TCCStatusFormatter.describe` extracted from the inline `--print-tcc-path`
/// formatter (#117). Each `EKAuthorizationStatus` case has a distinct, user-facing gloss;
/// regression on the gloss would silently mislead users during TCC troubleshooting.
final class TCCStatusFormatterTests: XCTestCase {

    func testNotDetermined_describesNeverAsked() {
        let s = TCCStatusFormatter.describe(.notDetermined)
        XCTAssertTrue(s.hasPrefix("notDetermined"))
        XCTAssertTrue(s.contains("never asked"), "gloss should help user see this is the pre-prompt state, not a denial — got: \(s)")
    }

    func testRestricted_describesSystemPolicy() {
        let s = TCCStatusFormatter.describe(.restricted)
        XCTAssertTrue(s.hasPrefix("restricted"))
        XCTAssertTrue(s.contains("system policy"), "user must know to look at MDM / Screen Time, not their own choice — got: \(s)")
    }

    func testDenied_describesExplicitDenial() {
        let s = TCCStatusFormatter.describe(.denied)
        XCTAssertTrue(s.hasPrefix("denied"))
        XCTAssertTrue(s.contains("explicitly"), "must distinguish user-denied from policy-restricted — got: \(s)")
    }

    func testFullAccess_describesGranted() {
        let s = TCCStatusFormatter.describe(.fullAccess)
        XCTAssertTrue(s.hasPrefix("fullAccess"))
        XCTAssertTrue(s.contains("granted"))
    }

    func testWriteOnly_describesPartial() {
        let s = TCCStatusFormatter.describe(.writeOnly)
        XCTAssertTrue(s.hasPrefix("writeOnly"))
        XCTAssertTrue(s.contains("partial"), "writeOnly is the macOS 14+ partial-grant — user should know reads will fail — got: \(s)")
    }

    /// `@unknown default` arm must surface raw value rather than crashing or returning
    /// empty string. We cannot construct an `@unknown` case at compile time, so this
    /// test exists as a documentation contract — any new Apple enum case added in a
    /// future macOS release must keep the formatter falsifiable (returns non-empty
    /// string containing the raw value).
    func testAllPresentCases_returnNonEmptyDistinctStrings() {
        let cases: [EKAuthorizationStatus] = [.notDetermined, .restricted, .denied, .fullAccess, .writeOnly]
        let descriptions = cases.map { TCCStatusFormatter.describe($0) }
        XCTAssertEqual(Set(descriptions).count, cases.count, "every recognized case must produce a unique gloss; collisions would conflate states during diagnosis — got: \(descriptions)")
        for d in descriptions {
            XCTAssertFalse(d.isEmpty, "formatter must never return empty string")
        }
    }
}
