import XCTest

/// #542: the change `restore-series-exceptions-on-delete-undo` (#285, #319, #321) shipped in v1.21.0
/// but was never archived, so the base spec still described the whole-series delete-undo as it was
/// before #285. Its delta replaced the whole requirement "Stale and busy protection" and had been
/// forked from an older base: archived as it stood, it would have dropped the scenarios of #265,
/// #269, #263, #273 and #287 (measured on a scratch copy). These pins keep the merged requirement:
/// every scenario of both sides once, in this order, the pre-#285 scenario gone, and the clauses
/// taken from each side.
///
/// A later change that adds, renames or reorders a scenario of "Stale and busy protection" turns
/// the title test red on purpose: copy the new `#### Scenario:` title into `scenarios`, at its place
/// in the spec. The exact list is what catches a delta forked from an older base, which drops
/// scenarios other changes added (the shape #542 found).
final class SeriesExceptionsSpecDocsTests: XCTestCase {
    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The requirement block, from its heading to the next `---` separator line.
    private func staleAndBusyRequirement() throws -> String {
        let spec = try repoFile("openspec/specs/undo-history-discard/spec.md")
        let start = try XCTUnwrap(spec.range(of: "### Requirement: Stale and busy protection\n"))
        let rest = spec[start.lowerBound...]
        let end = rest.range(of: "\n---\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private static let scenarios = [
        "Item changed after the operation",
        "Keeping later edits when undoing an update (#265, opt-in)",
        "Series occurrences could not be checked",
        "Item not found",
        "Calendar to restore into not found (#269)",
        "Recurring occurrence identity lost (#204)",
        "Recurring completion without an occurrence snapshot, successor shape",
        "Recurring completion without an occurrence snapshot, other mismatch",
        "Update of a recurring event (#236, #262)",
        "Restorable whole-series update on iCloud (#263)",
        "Update of a one-off event",
        "Update or move of a one-off event that repeats at undo time",
        "Delete of an occurrence and the following ones (#244)",
        "Calendar operation (#273)",
        "Delete of one occurrence (#244)",
        "Delete of a whole series that holds no exceptions (#244, #285)",
        "Delete of a whole series restores its exceptions (#285)",
        "Occurrences outside the checked window (#285)",
        "Series' first occurrence is an exception (#285)",
        "Edited occurrence moved across the window edge (#285)",
        "Restoring the exceptions fails part-way (#285)",
        "Recorded exceptions do not match the recreated series (#285)",
        "Cleanup fails after restoring the exceptions fails (#285)",
        "Occurrence delete whose slot the series already holds (#285, #321)",
        "Occurrence record that does not name its series (#321)",
        "Edited occurrence deleted by its own identifier beside its series (#321)",
        "Batch member cannot be restored (#248)",
        "Partial restore on request (#287)",
        "Partial restore stops part-way (#287, #248)",
        "Batch undo fails part-way (#248)",
        "Batch undo fails on its first write (#248)",
        "Batch undo restores a reminder the store holds differently (#248, #261)",
        "Batch undo of one member left fails (#248)",
        "Rule of a created series shortened",
        "Redo refused",
        "Redo of a record whose redo writes nothing (#247)",
        "Repeated discard",
        "Concurrent history execution",
    ]

    func testTheRequirementHoldsTheScenariosOfBothSidesInOrder() throws {
        let block = try staleAndBusyRequirement()
        let headings = block.split(separator: "\n").filter { $0.hasPrefix("#### Scenario: ") }
            .map { String($0.dropFirst("#### Scenario: ".count)) }
        XCTAssertEqual(headings, Self.scenarios, """
            The scenario titles of "Stale and busy protection" differ from \
            SeriesExceptionsSpecDocsTests.scenarios. If a change added or renamed a scenario on purpose, \
            copy its title into that list at its place in the spec (the order counts). If not, a delta \
            forked from an older base may have dropped scenarios other changes added (#542).
            """)
    }

    func testThePreExceptionsWholeSeriesScenarioIsGone() throws {
        let spec = try repoFile("openspec/specs/undo-history-discard/spec.md")
        XCTAssertFalse(spec.contains("#### Scenario: Delete of a whole series (#244)\n"))
        XCTAssertFalse(spec.contains("then adds it a second time, and that undo's text does not warn of it"))
    }

    /// The clauses each side brought where both had the scenario: the slot guard of the delta in
    /// "Delete of one occurrence", the #287 clause of the base in "Batch member cannot be restored",
    /// and in "Batch undo fails part-way" the delta's permanent error of a series member (the base's
    /// "no batch member's write throws such an error today" was false: `SeriesExceptionsUndo` throws
    /// `UnrecoverableUndoError` when the compensating delete of a series restore fails).
    func testTheMergedClausesAreThere() throws {
        let block = try staleAndBusyRequirement()
        for phrase in [
            "(never a second series); when the series already holds that slot it writes nothing",
            "with one exception: the duplicate guard of a deleted occurrence's record",
            "else from its occurrence date or, without one, its start",
            "says that undo with restore_available restores those and keeps the others",
            "a series member whose exceptions restore failed and whose compensating delete failed too is the one member that throws a permanent error",
            "the series member described above is the one write that does",
            "a change another process makes between the save and that read is recorded as part of that state (#424)",
            "except in the six discard scenarios below",
        ] {
            XCTAssertEqual(block.components(separatedBy: phrase).count - 1, 1, "once: \(phrase)")
        }
        XCTAssertFalse(block.contains("no batch member's write throws such an error today"))
        XCTAssertFalse(block.contains("A partial restore is #287"))
        XCTAssertFalse(block.contains("never a second series, unless"))
        // Every scenario reference names a heading as it stands, without the issue suffix.
        XCTAssertFalse(block.contains("(the scenario \"Occurrence delete whose slot the series already holds (#285)\")"))
    }

    /// The change is archived with its two open tasks recorded, not marked done.
    func testTheChangeIsArchivedWithItsOpenTasksRecorded() throws {
        let changes = repoRoot.appendingPathComponent("openspec/changes")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: changes.appendingPathComponent("restore-series-exceptions-on-delete-undo").path))
        let archived = try FileManager.default.contentsOfDirectory(atPath: changes.appendingPathComponent("archive").path)
            .filter { $0.hasSuffix("-restore-series-exceptions-on-delete-undo") }
        XCTAssertEqual(archived.count, 1)
        let tasks = try repoFile("openspec/changes/archive/\(try XCTUnwrap(archived.first))/tasks.md")
        let open = tasks.split(separator: "\n").filter { $0.hasPrefix("- [ ] ") }
        XCTAssertEqual(open.count, 2)
        XCTAssertTrue(open.contains { $0.hasPrefix("- [ ] 8.3 ") && $0.contains("封存時 #324 仍開著") })
        XCTAssertTrue(open.contains { $0.hasPrefix("- [ ] 10.4 ") && $0.contains("#579") && $0.contains("CMA") })
        XCTAssertTrue(tasks.split(separator: "\n").contains { $0.hasPrefix("- [x] 10.12 ") && $0.contains("--skip-specs") })
    }
}
