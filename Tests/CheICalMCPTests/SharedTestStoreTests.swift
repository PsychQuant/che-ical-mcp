import XCTest

/// #283: the test target builds one `EKEventStore`, `SharedTestStore.store`. Any other
/// `EKEventStore()` in a test file adds to EventKit's per-process store budget, and an instance
/// property adds one per test case at suite assembly; past the undocumented limit an unrelated test
/// fails with `error_ekcaderrordomain_1021`. Comments and string literals do not count.
final class SharedTestStoreTests: XCTestCase {
    private static let helper = "Helpers/SharedTestStore.swift"
    /// `EKEventStore()`, `EKEventStore.init()` and `EKEventStore(sources: …)`, and a typed
    /// `: EKEventStore = .init()` (also `!` / `?`, PR #390 round 2), with any spacing; the same for
    /// the server's subclass `CountingEventStore` (#328, PR #413 round 2), which is a store too.
    static let construction = #"\b(?:EKEventStore|CountingEventStore)\s*(\.\s*init\s*)?\(|\b(?:EKEventStore|CountingEventStore)\s*[!?]?\s*=\s*\.\s*init\s*\("#

    private func testFiles() throws -> [(name: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no test sources under \(root.path)")
        // Only a file whose text names the type can build one; the others are not blanked, which
        // keeps the scan cheap.
        return try files.compactMap { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("EventStore") else { return nil }
            return (String(file.path.dropFirst(root.path.count + 1)), SourceScan.codeOnly(text))
        }
    }

    /// The constructions in `text`, comments and string literals (raw and multi-line ones too)
    /// left out, the code of interpolations kept.
    private static func constructions(in text: String) -> Int {
        SourcePins.ranges(ofPattern: construction, in: SourceScan.codeOnly(text)).count
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
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"static\s+let\s+store\s*=\s*CountingEventStore\(\)"#, in: code).count, 1, code)
    }

    /// The pattern catches the spellings a new fixture may use and nothing in a comment or string.
    func testThePatternCatchesEverySpelling() {
        for spelling in ["let s = EKEventStore()", "let s = EKEventStore ()", "let s = EKEventStore.init()",
                         "let s = EKEventStore(sources: [])", "f(EKReminder(eventStore: EKEventStore()))",
                         "private let s: EKEventStore = .init()", "var s: EKEventStore! = .init()",
                         "var s: EKEventStore? = .init(sources: [])", "let s : EKEventStore=.init ()",
                         "let s = CountingEventStore()", "let s = CountingEventStore.init()", "let s: CountingEventStore = .init()"] {
            XCTAssertEqual(Self.constructions(in: spelling), 1, spelling)
        }
        for ignored in ["// EKEventStore()", "let s = \"EKEventStore()\"", "/* EKEventStore() */", "let s: EKEventStore = shared",
                        "let s = #\"EKEventStore()\"#", "let s = \"\"\"\nEKEventStore()\n\"\"\""] {
            XCTAssertEqual(Self.constructions(in: ignored), 0, ignored)
        }
    }

    /// PR #390 round 1: a raw string holding `\(` or a quote must not hide the code after it (the
    /// guard used `SourcePins.code`, which does not know raw strings, and failed open there). The
    /// code of an interpolation still counts.
    func testACodeAfterARawStringStillCounts() {
        for spelling in [##"let r = #"\("#; let s = EKEventStore()"##, ##"let r = #"a"b"#; let s = EKEventStore()"##,
                         ##"let u = "https://x"; let s = EKEventStore()"##, ##"let t = "\(EKEventStore())""##] {
            XCTAssertEqual(Self.constructions(in: spelling), 1, spelling)
        }
    }
}
