import Foundation

/// Stored trailing hashtag lines, shared by selection and response formatting.
enum ReminderTags {
    static func extract(from notes: String?) -> (cleanNotes: String?, tags: [String]) {
        guard let notes, !notes.isEmpty else { return (nil, []) }
        var lines = notes.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return (notes, [])
        }
        // A linear scan: unlike nested regex quantifiers, a failing suffix cannot
        // cause exponentially many alternative partitions of the same text (#216).
        let tokens = lines[index].split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty, tokens.allSatisfy({ $0.first == "#" && $0.dropFirst().first != nil }) else {
            return (notes, [])
        }
        let tags = tokens.map { String($0.dropFirst()) }
        lines.remove(at: index)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return (lines.isEmpty ? nil : lines.joined(separator: "\n"), tags)
    }
}
