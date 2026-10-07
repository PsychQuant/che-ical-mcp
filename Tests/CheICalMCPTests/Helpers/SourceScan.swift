import Foundation
import XCTest

/// Helpers for the tests that pin how `Sources/` is wired (#260, #246): finding the source
/// tree, removing comments without touching string literals, and slicing a call's arguments.
enum SourceScan {
    /// A source tree that `Package.swift` says should be there but is not: the guards built on
    /// this helper fail on it instead of skipping, so a moved tree cannot turn them off.
    struct MissingSources: Error, CustomStringConvertible {
        let description: String
    }

    /// `Sources/CheICalMCP`, found by walking up from `start` (this file's directory by default)
    /// to `Package.swift`. No `Package.swift` is a skip, as in `VersionConsistencyTests` and
    /// `ManifestParityTests` (the tests run without the checkout); a `Package.swift` without
    /// `Sources/CheICalMCP` next to it throws `MissingSources`, a failure.
    static func sourcesDirectory(from start: URL? = nil) throws -> URL {
        let fm = FileManager.default
        var dir = start ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let sources = dir.appendingPathComponent("Sources/CheICalMCP")
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: sources.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MissingSources(description: "Package.swift found in \(dir.path) but no Sources/CheICalMCP directory")
                }
                return sources
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        throw XCTSkip("Could not locate Package.swift above \(start?.path ?? #filePath)")
    }

    /// Every `.swift` file under `directory` (default `sourcesDirectory()`); none throws
    /// `MissingSources`.
    static func swiftFiles(under directory: URL? = nil) throws -> [URL] {
        let root = try directory ?? sourcesDirectory()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        if files.isEmpty { throw MissingSources(description: "No Swift sources under \(root.path)") }
        return files
    }

    /// `text` with every `//` and `/* */` comment (nested, as Swift allows) blanked out. String
    /// literals are kept, including raw and multi-line ones and the code inside `\( )`, so a `//`
    /// in a string (a URL) does not hide the rest of the line. Extended regex literals
    /// (`#/…/#`) are kept, and in code an escaped character is skipped, so the escaped slashes of
    /// a bare regex literal (`/https?:\/\//`) are not read as a comment. Not handled: a bare
    /// `/…/` literal holding a quote or an unescaped `/*` (none in `Sources/`). The text is read
    /// as Unicode scalars, as the compiler reads it, so "\r\n" ends a line comment and a quote
    /// followed by a combining mark still opens a string. Line breaks are kept, so offsets map to
    /// the same line numbers.
    static func strippingComments(_ text: String) -> String {
        var scanner = CommentStripper(text)
        scanner.code(untilClosingParen: false)
        return String(scanner.out)
    }

    /// The text between the parentheses of the first call that starts with `marker` (which ends
    /// in `(`), balanced on parentheses; nil when `marker` is absent or unbalanced.
    static func arguments(of marker: String, in code: String) -> String? {
        enclosed(after: marker, in: code, open: "(", close: ")")
    }

    /// The text between the braces of the first declaration that starts with `marker` (which ends
    /// in `{`), balanced on braces; nil when `marker` is absent or unbalanced.
    static func body(of marker: String, in code: String) -> String? {
        enclosed(after: marker, in: code, open: "{", close: "}")
    }

    private static func enclosed(after marker: String, in code: String, open: Character, close: Character) -> String? {
        guard let start = code.range(of: marker) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < code.endIndex {
            if code[index] == open {
                depth += 1
            } else if code[index] == close {
                depth -= 1
                if depth == 0 { return String(code[start.upperBound..<index]) }
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
    let chars: [Unicode.Scalar]
    var i = 0
    var out = String.UnicodeScalarView()

    init(_ text: String) { chars = Array(text.unicodeScalars) }

    private func at(_ s: String) -> Bool {
        var j = i
        for c in s.unicodeScalars {
            guard j < chars.count, chars[j] == c else { return false }
            j += 1
        }
        return true
    }

    private func isLineBreak(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }

    private mutating func copy(_ n: Int = 1) {
        for _ in 0..<n where i < chars.count { out.append(chars[i]); i += 1 }
    }

    private mutating func copy(_ s: String) { copy(s.unicodeScalars.count) }

    private mutating func blank(_ n: Int = 1) {
        for _ in 0..<n where i < chars.count { out.append(isLineBreak(chars[i]) ? chars[i] : " "); i += 1 }
    }

    /// Code until the end, or until the `)` that closes an interpolation.
    mutating func code(untilClosingParen: Bool) {
        var depth = 0
        while i < chars.count {
            if at("//") {
                while i < chars.count, !isLineBreak(chars[i]) { blank() }
            } else if at("/*") {
                var nesting = 0
                repeat {
                    if at("/*") { nesting += 1; blank(2) } else if at("*/") { nesting -= 1; blank(2) } else { blank() }
                } while nesting > 0 && i < chars.count
            } else if chars[i] == "\\" {
                copy(2)   // `\/` in a bare regex literal, `\.` in a key path
            } else if chars[i] == "#" || chars[i] == "\"" {
                if !stringLiteral() && !extendedRegexLiteral() { copy() }
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
            if at(delimiter) { copy(delimiter); return true }
            if !multiline, isLineBreak(chars[i]) { return true }   // unterminated: leave the string
            if at(escape + "(") {
                copy(escape + "(")
                code(untilClosingParen: true)
                copy()   // the closing `)`
            } else if at(escape) {
                copy(escape.unicodeScalars.count + 1)
            } else {
                copy()
            }
        }
        return true
    }

    /// An extended regex literal at `i` (`#/…/#`, with any number of `#`, single- or multi-line),
    /// copied as it is; false when `i` does not start one.
    private mutating func extendedRegexLiteral() -> Bool {
        var hashes = 0
        while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
        guard hashes > 0, i + hashes < chars.count, chars[i + hashes] == "/" else { return false }
        let closing = "/" + String(repeating: "#", count: hashes)
        copy(hashes + 1)
        while i < chars.count {
            if at(closing) { copy(closing); return true }
            copy(chars[i] == "\\" ? 2 : 1)
        }
        return true
    }
}
