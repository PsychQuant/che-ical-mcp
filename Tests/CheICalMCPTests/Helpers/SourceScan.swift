import Foundation
import XCTest

/// Helpers for the tests that pin how `Sources/` is wired (#260, #246): finding the source
/// tree, removing comments without touching string literals, and slicing a call's arguments.
enum SourceScan {
    /// `Sources/CheICalMCP`, found by walking up to `Package.swift`; a skip when the checkout is
    /// not next to the tests (the `VersionConsistencyTests` / `ManifestParityTests` convention).
    static func sourcesDirectory() throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent("Sources/CheICalMCP")
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        throw XCTSkip("Could not locate Package.swift above \(#filePath)")
    }

    /// Every `.swift` file under `Sources/CheICalMCP`.
    static func swiftFiles() throws -> [URL] {
        let root = try sourcesDirectory()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        if files.isEmpty { throw XCTSkip("No Swift sources under \(root.path)") }
        return files
    }

    /// `text` with every `//` and `/* */` comment (nested, as Swift allows) blanked out. String
    /// literals are kept, including raw and multi-line ones and the code inside `\( )`, so a `//`
    /// in a string (a URL) does not hide the rest of the line. Newlines are kept, so offsets map
    /// to the same line numbers.
    static func strippingComments(_ text: String) -> String {
        var scanner = CommentStripper(Array(text))
        scanner.code(untilClosingParen: false)
        return String(scanner.out)
    }

    /// The text between the parentheses of the first call that starts with `marker` (which ends
    /// in `(`), balanced on parentheses; nil when `marker` is absent or unbalanced.
    static func arguments(of marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(code[start.upperBound..<index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// `text` with every run of whitespace (newlines included) collapsed to one space.
    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private struct CommentStripper {
    let chars: [Character]
    var i = 0
    var out: [Character] = []

    init(_ chars: [Character]) { self.chars = chars }

    private func at(_ s: String) -> Bool {
        var j = i
        for c in s {
            guard j < chars.count, chars[j] == c else { return false }
            j += 1
        }
        return true
    }

    private mutating func copy(_ n: Int = 1) {
        for _ in 0..<n where i < chars.count { out.append(chars[i]); i += 1 }
    }

    private mutating func blank(_ n: Int = 1) {
        for _ in 0..<n where i < chars.count { out.append(chars[i] == "\n" ? "\n" : " "); i += 1 }
    }

    /// Code until the end, or until the `)` that closes an interpolation.
    mutating func code(untilClosingParen: Bool) {
        var depth = 0
        while i < chars.count {
            if at("//") {
                while i < chars.count, chars[i] != "\n" { blank() }
            } else if at("/*") {
                var nesting = 0
                repeat {
                    if at("/*") { nesting += 1; blank(2) } else if at("*/") { nesting -= 1; blank(2) } else { blank() }
                } while nesting > 0 && i < chars.count
            } else if chars[i] == "#" || chars[i] == "\"" {
                if !stringLiteral() { copy() }
            } else if untilClosingParen, chars[i] == "(" {
                depth += 1; copy()
            } else if untilClosingParen, chars[i] == ")" {
                if depth == 0 { return }
                depth -= 1; copy()
            } else {
                copy()
            }
        }
    }

    /// A string literal at `i` (`"…"`, `"""…"""`, with any number of `#`), copied with the code
    /// of its interpolations scanned as code; false when `i` does not start one.
    private mutating func stringLiteral() -> Bool {
        var hashes = 0
        while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
        guard i + hashes < chars.count, chars[i + hashes] == "\"" else { return false }
        let pounds = String(repeating: "#", count: hashes)
        copy(hashes)
        let multiline = at("\"\"\"")
        let delimiter = (multiline ? "\"\"\"" : "\"") + pounds
        copy(multiline ? 3 : 1)
        let escape = "\\" + pounds
        while i < chars.count {
            if at(delimiter) { copy(delimiter.count); return true }
            if !multiline, chars[i] == "\n" { return true }   // unterminated: leave the string
            if at(escape + "(") {
                copy(escape.count + 1)
                code(untilClosingParen: true)
                copy()   // the closing `)`
            } else if at(escape) {
                copy(escape.count + 1)
            } else {
                copy()
            }
        }
        return true
    }
}
