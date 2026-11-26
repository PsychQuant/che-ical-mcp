import XCTest
@testable import CheICalMCP

/// #600: no test reaches the live EventKit store or the process-wide undo history unless it opts in.
/// `LiveStoreGuard` enforces that at run time: under XCTest, `EventKitManager.shared`,
/// `CalendarUndoManager.shared`, `LiveAuthorizationStatusSource` and `SetupRunner.requestBoth` stop
/// the process with the call stack. A trap cannot be shown from inside the process it stops, so these
/// tests show the guard is on here and lifts only inside `allowingLiveStore`, and pin where it is
/// called. Every other test shows the rest: a server built with any source or the undo history left
/// at its default stops the suite.
final class LiveStoreGuardTests: XCTestCase {
    func testTheGuardIsOnUnderXCTest() {
        XCTAssertTrue(LiveStoreGuard.isUnderXCTest)
        XCTAssertFalse(LiveStoreGuard.liveStoreAllowed)
        let message = try? XCTUnwrap(LiveStoreGuard.violation("EventKitManager.shared"))
        XCTAssertEqual(message?.hasPrefix("#600 LiveStoreGuard: EventKitManager.shared was used under XCTest."), true)
    }

    func testAllowingLiveStoreLiftsItForItsScopeOnly() async {
        let inside = await LiveStoreGuard.allowingLiveStore { LiveStoreGuard.violation("CalendarUndoManager.shared") }
        XCTAssertNil(inside)
        XCTAssertNotNil(LiveStoreGuard.violation("CalendarUndoManager.shared"))
    }

    /// Each entry to the live store checks on each use: the two `shared` accessors, the live
    /// authorization source (main.swift and the setup window build one) and the setup request.
    func testEveryLiveEntryIsChecked() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        XCTAssertEqual(SourcePins.ranges(of: "static var shared: EventKitManager {\n        LiveStoreGuard.check(", in: manager).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "private static let liveShared = EventKitManager()", in: manager).count, 1)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"static\s+let\s+shared\b"#, in: manager).count, 0)

        let undo = SourcePins.code(try SourcePins.source("EventKit/UndoManager.swift"))
        XCTAssertEqual(SourcePins.ranges(of: "static var shared: CalendarUndoManager {\n        LiveStoreGuard.check(", in: undo).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "private static let processWide = CalendarUndoManager()", in: undo).count, 1)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"static\s+let\s+shared\b"#, in: undo).count, 0)

        let authorization = SourcePins.code(try SourcePins.source("EventKit/AuthorizationStatusSource.swift"))
        let liveInit = try XCTUnwrap(SourcePins.body(of: "init(store: EKEventStore = EKEventStore()) {", in: authorization))
        XCTAssertTrue(liveInit.contains("LiveStoreGuard.check("))
        let setup = SourcePins.code(try SourcePins.source("SetupRunner.swift"))
        let request = try XCTUnwrap(SourcePins.body(of: "static func requestBoth(nonInteractive: Bool) async -> Bool {", in: setup))
        let check = try XCTUnwrap(request.range(of: "LiveStoreGuard.check("))
        let store = try XCTUnwrap(request.range(of: "let store = EKEventStore()"))
        XCTAssertLessThan(check.lowerBound, store.lowerBound, "checked before its EKEventStore is made")
    }

    /// Only DEBUG builds carry the check, and it keys on XCTest being loaded, not on the environment a
    /// spawned binary would inherit.
    func testReleaseBuildsCarryNoCheckAndTheDetectionIsXCTestLoaded() throws {
        let raw = try SourcePins.source("EventKit/LiveStoreGuard.swift")
        let code = SourcePins.code(raw)
        let debug = try XCTUnwrap(code.range(of: "#if DEBUG"))
        let release = try XCTUnwrap(code.range(of: "#else"))
        let end = try XCTUnwrap(code.range(of: "#endif"))
        XCTAssertLessThan(debug.lowerBound, release.lowerBound)
        XCTAssertEqual(code[release.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
                       "@inline(__always) static func check(_ what: StaticString) {}")
        XCTAssertTrue(raw.contains(#"static let isUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil"#))
        XCTAssertFalse(code.contains("environment"), "the guard reads no environment variable")
    }

    /// The opt-in is greppable, and no test uses it.
    func testNoTestOptsIntoTheLiveStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var users: [String] = []
        for file in try SourceScan.swiftFiles(under: tests) where file.lastPathComponent != "LiveStoreGuardTests.swift" {
            if SourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8)).contains("allowingLiveStore") {
                users.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(users, [])
    }
}
