import Foundation

/// Source pins for code an in-memory event store cannot run (#244 / #245, PR #278 verify round 2,
/// findings 12/16/20/25/26). A pin reads one function: from its declaration to the brace that
/// closes it, with comments and string literals blanked out, so text in a comment never satisfies
/// a pin and the next declaration, of whatever kind, is never part of the body.
///
/// Limits (verify round 3, findings 6/13/15): it reads `Character`s, so a CRLF file reads as one
/// comment after its first `//` and every pin fails (closed); raw strings (`#"…"#`) and regex
/// literals are not recognised, so a `\(` or a quote in one shifts the blanking. The scanned files
/// have none. #276's `SourceScan` handles scalars, CRLF and regex literals; the two readers are to
/// be unified after both PRs merge.
enum SourcePins {
    static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The code of the first function whose declaration contains `declaration`, from the declaration
    /// to its closing brace. Nil when the declaration is not in the code or its braces do not close.
    static func body(of declaration: String, in source: String) -> String? {
        let code = blankingCommentsAndStrings(Array(source))
        let text = String(code)
        guard let start = text.range(of: declaration) else { return nil }
        var index = text.distance(from: text.startIndex, to: start.lowerBound)
        while index < code.count, code[index] != "{" { index += 1 }
        var depth = 0
        for end in index..<code.count {
            if code[end] == "{" { depth += 1 }
            if code[end] == "}" {
                depth -= 1
                if depth == 0 { return String(code[text.distance(from: text.startIndex, to: start.lowerBound)...end]) }
            }
        }
        return nil
    }

    /// A whole source's code with comments and string literals blanked, for a pin that counts a
    /// call across files rather than reading one function.
    static func code(_ source: String) -> String {
        String(blankingCommentsAndStrings(Array(source)))
    }

    static func ranges(of literal: String, in body: String) -> [Range<String.Index>] {
        ranges(ofPattern: NSRegularExpression.escapedPattern(for: literal), in: body)
    }

    static func ranges(ofPattern pattern: String, in body: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { Range($0.range, in: body) }
    }

    /// Comments and string literals (interpolations included) become spaces; newlines stay, so
    /// positions are unchanged.
    private static func blankingCommentsAndStrings(_ chars: [Character]) -> [Character] {
        var out = chars
        func blank(_ range: Range<Int>) {
            for j in range where j < out.count && out[j] != "\n" { out[j] = " " }
        }
        func at(_ j: Int, _ literal: String) -> Bool {
            let needle = Array(literal)
            return j + needle.count <= chars.count && Array(chars[j..<j + needle.count]) == needle
        }
        func endOfInterpolation(from start: Int) -> Int {
            var depth = 1
            var j = start
            while j < chars.count {
                if chars[j] == "\"" { j = endOfString(from: j); continue }
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" {
                    depth -= 1
                    if depth == 0 { return j + 1 }
                }
                j += 1
            }
            return j
        }
        func endOfString(from start: Int) -> Int {
            let multiline = at(start, "\"\"\"")
            var j = start + (multiline ? 3 : 1)
            while j < chars.count {
                if chars[j] == "\\" {
                    if at(j + 1, "(") { j = endOfInterpolation(from: j + 2); continue }
                    j += 2
                    continue
                }
                if multiline, at(j, "\"\"\"") { return j + 3 }
                if !multiline, chars[j] == "\"" { return j + 1 }
                j += 1
            }
            return j
        }
        var i = 0
        while i < chars.count {
            if at(i, "//") {
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                blank(i..<end)
                i = end
            } else if at(i, "/*") {
                var depth = 0
                var end = i
                repeat {
                    if at(end, "/*") { depth += 1; end += 2 } else if at(end, "*/") { depth -= 1; end += 2 } else { end += 1 }
                } while depth > 0 && end < chars.count
                blank(i..<end)
                i = end
            } else if chars[i] == "\"" {
                let end = endOfString(from: i)
                blank(i..<end)
                i = end
            } else {
                i += 1
            }
        }
        return out
    }
}
