import Foundation
import XCTest

/// Regression guard for #154: the signed binary MUST carry the two
/// personal-information entitlements, or macOS 26.5's prompting policy
/// refuses the TCC healing re-prompt after a csreq mismatch — a silent,
/// permanent denial that every status-API-based diagnostic reports as green.
///
/// #58 tried to guard the opposite invariant ("keep this file empty") with an
/// XML comment; #154 proved a comment cannot survive an Apple policy change.
/// This test pins the new invariant mechanically: removing either key goes
/// RED in CI before it can ship.
final class EntitlementsPlistTests: XCTestCase {

    private static let calendarsKey = "com.apple.security.personal-information.calendars"
    private static let remindersKey = "com.apple.security.personal-information.reminders"

    /// Resolve Sources/CheICalMCP/Entitlements.plist relative to this test file,
    /// so the test reads the same artifact `codesign --entitlements` consumes.
    private func loadEntitlements() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // CheICalMCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let plistURL = repoRoot
            .appendingPathComponent("Sources/CheICalMCP/Entitlements.plist")
        let data = try Data(contentsOf: plistURL)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "Entitlements.plist root must be a dictionary")
    }

    func testPlistParseable() throws {
        _ = try loadEntitlements()
    }

    func testCalendarsEntitlementPresent() throws {
        let entitlements = try loadEntitlements()
        let value = try XCTUnwrap(
            entitlements[Self.calendarsKey] as? Bool,
            "\(Self.calendarsKey) missing — without it macOS 26.5 blocks the TCC healing re-prompt (#154)")
        XCTAssertTrue(value, "\(Self.calendarsKey) must be true")
    }

    func testRemindersEntitlementPresent() throws {
        let entitlements = try loadEntitlements()
        let value = try XCTUnwrap(
            entitlements[Self.remindersKey] as? Bool,
            "\(Self.remindersKey) missing — symmetric defense: a future csreq mismatch would trap Reminders the same way Calendar was trapped (#154)")
        XCTAssertTrue(value, "\(Self.remindersKey) must be true")
    }
}
