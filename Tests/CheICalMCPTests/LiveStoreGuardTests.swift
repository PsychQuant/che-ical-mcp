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

    /// PR #603 verify r1: the one store the tests build (`SharedTestStore.store`, a real
    /// `CountingEventStore`) is used only to make in-memory items. Outside its own helper and its
    /// tests, the only members a test calls on it, or on a local bound to it, are `commitCount` and
    /// one `save` of a reminder that has no list, which EventKit refuses
    /// (`CalendarEmptinessTests.testTheStoreCountsAWriteThatThrows`); it is otherwise passed only as an
    /// item's `eventStore:` or a calendar's `for:` store. A text check over the code with comments
    /// blanked: an alias other than `let x = SharedTestStore.store` is not followed.
    func testTheSharedTestStoreMakesInMemoryItemsOnly() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let skipped: Set<String> = ["SharedTestStore.swift", "SharedTestStoreTests.swift", "LiveStoreGuardTests.swift"]
        var uses: [String] = []
        for file in try SourceScan.swiftFiles(under: tests) where !skipped.contains(file.lastPathComponent) {
            // Comments blanked, strings kept (`SourcePins.code` misreads a multi-line string with line
            // continuations in CalendarEmptinessTests and blanks the rest of that file).
            let code = SourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            guard code.contains("SharedTestStore.store") else { continue }
            // Each alias is followed to the end of the function it is declared in (the next `func`).
            var scopes: [(name: String, text: Substring)] = [("SharedTestStore.store", code[...])]
            for range in SourcePins.ranges(ofPattern: #"let\s+\w+\s*(?::\s*\w+\s*)?=\s*SharedTestStore\.store"#, in: code) {
                let name = String(code[range].dropFirst(4).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                let end = code.range(of: "func ", range: range.upperBound..<code.endIndex)?.lowerBound ?? code.endIndex
                scopes.append((name, code[range.upperBound..<end]))
            }
            for (name, text) in scopes {
                let scope = String(text)
                let escaped = NSRegularExpression.escapedPattern(for: name)
                for range in SourcePins.ranges(ofPattern: #"(?<![\w.])"# + escaped + #"\s*\.\s*\w+"#, in: scope) {
                    let member = scope[range].split(separator: ".").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    uses.append("\(file.lastPathComponent): \(member)")
                }
                for range in SourcePins.ranges(ofPattern: #"[(,]\s*(?:\w+\s*:\s*)?"# + escaped + #"\s*[),]"#, in: scope) {
                    let call = scope[range]
                    if call.contains("eventStore:") || call.contains("for:") || call.contains("store:") { continue }
                    uses.append("\(file.lastPathComponent): argument \(call.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(uses.sorted(), ["CalendarEmptinessTests.swift: commitCount", "CalendarEmptinessTests.swift: commitCount",
                                       "CalendarEmptinessTests.swift: save"])
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
