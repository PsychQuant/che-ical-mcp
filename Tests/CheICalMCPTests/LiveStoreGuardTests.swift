import XCTest
@testable import CheICalMCP

/// #600: no test reaches the live EventKit store or the process-wide undo history unless it opts in.
/// `LiveStoreGuard` enforces that at run time: under XCTest, `EventKitManager.shared`,
/// `CalendarUndoManager.shared`, every manager's `eventStore` (`forTesting` ones too), the write
/// stores, `NewObjectSave`'s fresh store, `LiveAuthorizationStatusSource` and `SetupRunner.requestBoth`
/// stop the process with the call stack. A trap cannot be shown from inside the process it stops, so these
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

        // PR #603 verify r1: every manager's store, `forTesting` ones too, is checked on each use, and
        // so is making a write store or the fresh store `NewObjectSave` reads after a save. A data
        // call through a `forTesting` manager whose probe grants access stops here before it touches
        // a store (seen on a run with such a test added locally; a trap cannot be shown in-process).
        XCTAssertEqual(SourcePins.ranges(of: "nonisolated var eventStore: CountingEventStore {\n        LiveStoreGuard.check(", in: manager).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "private let liveEventStore: CountingEventStore", in: manager).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "self.liveEventStore = store", in: manager).count, 1, "the init's own store, set once")
        XCTAssertEqual(SourcePins.ranges(of: "liveEventStore", in: manager).count, 3, "declared, set, and returned by the checked accessor only")
        XCTAssertEqual(SourcePins.ranges(of: "WriteStorePool<EKEventStore>(make: { LiveStoreGuard.check(", in: manager).count, 1)
        let fresh = SourcePins.code(try SourcePins.source("EventKit/NewObjectSave.swift"))
        let finds = try XCTUnwrap(SourcePins.body(of: "static func freshStoreFinds(_ check: (EKEventStore) -> Found) -> Found? {", in: fresh))
        let freshCheck = try XCTUnwrap(finds.range(of: "LiveStoreGuard.check("))
        let freshStore = try XCTUnwrap(finds.range(of: "let store = EKEventStore()"))
        XCTAssertLessThan(freshCheck.lowerBound, freshStore.lowerBound)

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

    /// PR #603 verify r2 (was `testTheSharedTestStoreMakesInMemoryItemsOnly`, a text check that
    /// missed aliases): the store the tests build items on (`SharedTestStore.store`) is a
    /// `GuardedTestStore`, whose every member that reads, writes, commits or refreshes the store
    /// checks `LiveStoreGuard` before calling EventKit, so a test that uses it for anything but
    /// building items stops, whatever it calls it. The commit-count store is checked on use too.
    func testTheSharedTestStoreChecksEveryStoreMember() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Helpers/SharedTestStore.swift")
        let code = SourcePins.code(try String(contentsOf: helper, encoding: .utf8))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"static\s+let\s+store\s*=\s*GuardedTestStore\(\)"#, in: code).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "static var counting: CountingEventStore {\n        LiveStoreGuard.check(", in: code).count, 1)
        let members = ["override var sources:", "override func source(withIdentifier", "override func calendars(for",
                       "override func calendar(withIdentifier", "override var defaultCalendarForNewEvents:",
                       "override func defaultCalendarForNewReminders(", "override func saveCalendar(", "override func removeCalendar(",
                       "override func calendarItem(withIdentifier", "override func calendarItems(withExternalIdentifier",
                       "override func save(_ event: EKEvent, span: EKSpan)", "override func save(_ event: EKEvent, span: EKSpan, commit: Bool)",
                       "override func remove(_ event: EKEvent, span: EKSpan)", "override func remove(_ event: EKEvent, span: EKSpan, commit: Bool)",
                       "override func event(withIdentifier", "override func events(matching", "override func enumerateEvents(matching",
                       "override func save(_ reminder: EKReminder", "override func remove(_ reminder: EKReminder",
                       "override func fetchReminders(matching", "override func commit()", "override func reset()",
                       "override func refreshSourcesIfNecessary()"]
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\boverride\s+(func|var)\b"#, in: code).count, members.count)
        for member in members {
            let start = try XCTUnwrap(code.range(of: member), member)
            let brace = try XCTUnwrap(code.range(of: "{", range: start.upperBound..<code.endIndex), member)
            let rest = code[brace.upperBound...].drop { $0.isWhitespace }
            XCTAssertTrue(rest.hasPrefix("LiveStoreGuard.check("), "\(member) checks first")
        }
    }

    /// A forTesting manager's store is reached only through the checked `eventStore`: the init sets
    /// it once, and hands it to the live authorization source only when no probe is given (`shared`).
    func testTheManagersOwnStoreIsReachedOnlyThroughTheCheckedAccessor() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bstore\b"#, in: try XCTUnwrap(SourcePins.body(of: "fileprivate init(authorizationSource: AuthorizationStatusSource? = nil,", in: manager))).count, 4,
                       "made, set as liveEventStore, and `store: store` to LiveAuthorizationStatusSource only when no probe is passed")
        XCTAssertEqual(SourcePins.ranges(of: "self.authorizationSource = authorizationSource ?? LiveAuthorizationStatusSource(store: store)", in: manager).count, 1)
    }

    /// The opt-in is greppable, and one test uses it: `CalendarEmptinessTests.testTheStoreCountsAWriteThatThrows`,
    /// which must call the real `save` to see the commit count move; it saves a reminder with no list,
    /// which EventKit refuses before writing anything.
    func testOnlyTheCommitCountTestOptsIntoTheLiveStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var users: [String] = []
        for file in try SourceScan.swiftFiles(under: tests) where file.lastPathComponent != "LiveStoreGuardTests.swift" {
            if SourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8)).contains("allowingLiveStore") {
                users.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(users, ["CalendarEmptinessTests.swift"])
    }
}
