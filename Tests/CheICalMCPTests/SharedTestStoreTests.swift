import XCTest

/// #283: the test target builds one `EKEventStore`, `SharedTestStore.store`. Any other
/// `EKEventStore()` in a test file adds to EventKit's per-process store budget, and an instance
/// property adds one per test case at suite assembly; past the undocumented limit an unrelated test
/// fails with `error_ekcaderrordomain_1021`. Comments and string literals do not count.
final class SharedTestStoreTests: XCTestCase {
    private static let helper = "Helpers/SharedTestStore.swift"
    /// `EKEventStore()`, `EKEventStore.init()` and `EKEventStore(sources: …)`, with any spacing.
    private static let construction = #"\bEKEventStore\s*(\.\s*init\s*)?\("#

    private func testFiles() throws -> [(name: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no test sources under \(root.path)")
        // Only a file whose text names the type can build one; the others are not blanked, which
        // keeps the scan cheap.
        return try files.compactMap { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("EKEventStore") else { return nil }
            return (String(file.path.dropFirst(root.path.count + 1)), SourcePins.code(text))
        }
    }

    func testOnlyTheSharedHelperBuildsAStore() throws {
        var built: [String: Int] = [:]
        for (name, code) in try testFiles() {
            let count = SourcePins.ranges(ofPattern: Self.construction, in: code).count
            if count > 0 { built[name] = count }
        }
        XCTAssertEqual(built, [Self.helper: 1],
                       "#283: build in-memory EventKit items on SharedTestStore.store; every other EKEventStore() adds to EventKit's per-process store limit (error_ekcaderrordomain_1021), and an instance property adds one per test case")
    }

    /// The helper's store is a `static let`: built once, on first use, not per test case.
    func testTheSharedStoreIsAStaticLet() throws {
        let code = try XCTUnwrap(try testFiles().first { $0.name == Self.helper }?.code, Self.helper)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"static\s+let\s+store\s*=\s*EKEventStore\(\)"#, in: code).count, 1, code)
    }

    /// The pattern catches the spellings a new fixture may use and nothing in a comment or string.
    func testThePatternCatchesEverySpelling() {
        for spelling in ["let s = EKEventStore()", "let s = EKEventStore ()", "let s = EKEventStore.init()",
                         "let s = EKEventStore(sources: [])", "f(EKReminder(eventStore: EKEventStore()))"] {
            XCTAssertEqual(SourcePins.ranges(ofPattern: Self.construction, in: SourcePins.code(spelling)).count, 1, spelling)
        }
        for ignored in ["// EKEventStore()", "let s = \"EKEventStore()\"", "/* EKEventStore() */", "let s: EKEventStore = shared"] {
            XCTAssertEqual(SourcePins.ranges(ofPattern: Self.construction, in: SourcePins.code(ignored)).count, 0, ignored)
        }
    }
}
