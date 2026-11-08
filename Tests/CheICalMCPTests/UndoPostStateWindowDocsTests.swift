import XCTest

/// #424: the #236 guard records the state a write left by reading the item back after the save,
/// so a change another process makes in that moment is folded in. That is a known limit, chosen
/// over comparing with what was written (option (b) on #424, not chosen: it needs a measured list
/// of the store's normalizations, and a missed one refuses an undo for good). These pins keep the
/// limit written where a reader of the guard looks: the user-facing undo history document, both
/// `postWriteSnapshot` doc comments, and the spec.
final class UndoPostStateWindowDocsTests: XCTestCase {
    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheUndoHistoryDocumentStatesTheWindow() throws {
        let doc = try repoFile("docs/UNDO_HISTORY.md")
        let start = try XCTUnwrap(doc.range(of: "**A known limit of this check (#424).**"))
        let paragraph = String(doc[start.lowerBound...].prefix(while: { $0 != "\n" }))
        for phrase in ["in the same synchronous stretch as the save",
                       "only another process",
                       "only in the fields the undo writes back",
                       "is read back by its identifier",
                       "normalizes on save"] {
            XCTAssertTrue(paragraph.contains(phrase), "missing: \(phrase)\n\(paragraph)")
        }
    }

    func testBothSnapshotFunctionsCarryTheLimitInTheirDocComments() throws {
        let source = try repoFile("Sources/CheICalMCP/EventKit/EventKitManager+UndoGuard.swift")
        for declaration in ["func postWriteSnapshot(eventID: String, saved: EKEvent)",
                            "func postWriteSnapshot(reminderID: String, saved: EKReminder)"] {
            let end = try XCTUnwrap(source.range(of: declaration), declaration)
            // The doc comment is the run of `///` lines right above the declaration.
            let lines = source[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            let comment = lines.reversed().prefix(while: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///") })
                .reversed().joined(separator: " ")
            XCTAssertTrue(comment.contains("#424"), "\(declaration): \(comment)")
            XCTAssertTrue(comment.contains("another process"), "\(declaration): \(comment)")
        }
    }

    func testTheSpecStatesTheLimit() throws {
        let spec = try repoFile("openspec/specs/undo-history-discard/spec.md")
        XCTAssertTrue(spec.contains("a change another process makes between the save and that read is recorded as part of that state (#424)"))
    }
}
