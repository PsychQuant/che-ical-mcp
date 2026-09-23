import Foundation
import XCTest

/// #223 — `import CheMCPKit` makes the package's generic `ErrorSanitizer` callable from any file
/// that imports it, and a direct call silently turns `eventkit_error_<N>` into
/// `error_ekerrordomain_<N>` for EventKit errors. Every sanitizer call in `Sources/` must go
/// through `EventKitErrorSanitizer`; only that wrapper may call the package's type.
final class SanitizerEntryPointTests: XCTestCase {

    /// Returns `file:line` for each direct use of the package sanitizer in `text`.
    static func directUses(in text: String, file: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])ErrorSanitizer\s*\."#)
        var out: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.components(separatedBy: "//").first ?? line   // comments may name it
            let ns = code as NSString
            if regex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) != nil {
                out.append("\(file):\(i + 1)")
            }
        }
        return out
    }

    func testClassifierCatchesDirectCallsAndIgnoresTheWrapperAndComments() {
        XCTAssertEqual(Self.directUses(in: "let c = ErrorSanitizer.sanitize(e)", file: "x").count, 1)
        XCTAssertEqual(Self.directUses(in: "let c = CheMCPKit.ErrorSanitizer .sanitize(e)", file: "x").count, 1)
        XCTAssertTrue(Self.directUses(in: "let c = EventKitErrorSanitizer.sanitize(e)", file: "x").isEmpty)
        XCTAssertTrue(Self.directUses(in: "// see ErrorSanitizer.sanitize", file: "x").isEmpty)
    }

    func testOnlyTheWrapperCallsThePackageSanitizer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "EventKitErrorSanitizer.swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var found: [String] = []
        for file in files {
            found += Self.directUses(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        XCTAssertEqual(found, [], "call EventKitErrorSanitizer instead, or EventKit errors lose the eventkit_error_<N> code")
    }
}
