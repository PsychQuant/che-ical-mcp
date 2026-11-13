import XCTest
@testable import CheICalMCP

/// #527: the undo paths reach their slot comparisons through `InstantSet`, `InstantIndex` and
/// `DistinctInstants`. A scan written beside one of them would still answer correctly and would not
/// pass through the counter the scaling tests read (their exact lookup counts catch a scan that
/// replaces a set, not one added next to it), so these pins read the source.
final class UndoSlotComparisonWiringTests: XCTestCase {
    private func count(_ literal: String, in body: String) -> Int { SourcePins.ranges(of: literal, in: body).count }

    /// The store-level restore takes each listed occurrence through the growing set, declared before
    /// the windows are listed so it spans all of them, and scans nothing it has taken.
    func testTheStoreLevelRestoreTakesOccurrencesThroughTheGrowingSet() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/SeriesExceptionsUndo.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "static func restore<Store: SeriesExceptionsStoreSource>(_ exceptions: SeriesExceptions", in: file))
        XCTAssertEqual(count("var taken = DistinctInstants()", in: body), 1)
        XCTAssertEqual(count("if taken.insert(slot) { generated.append((slot, occurrence)) }", in: body), 1)
        XCTAssertEqual(count("generated.append(", in: body), 1, "nothing else adds to what was taken")
        XCTAssertFalse(body.contains("sameInstant"))
        XCTAssertFalse(body.contains("generated.contains"))
        let declared = try XCTUnwrap(body.range(of: "var taken = DistinctInstants()"))
        let loop = try XCTUnwrap(body.range(of: "for window in exceptions.windows {"))
        let slot = try XCTUnwrap(body.range(of: "let slot = store.slot(of: occurrence)"))
        let insert = try XCTUnwrap(body.range(of: "if taken.insert(slot)"))
        let restorer = try XCTUnwrap(body.range(of: "SeriesExceptionsRestorer.restore("))
        XCTAssertLessThan(declared.lowerBound, loop.lowerBound)
        XCTAssertLessThan(loop.lowerBound, slot.lowerBound)
        XCTAssertLessThan(slot.lowerBound, insert.lowerBound)
        XCTAssertLessThan(insert.lowerBound, restorer.lowerBound)
        // The whole file compares instants nowhere else.
        XCTAssertEqual(count("sameInstant", in: file), 0)
    }

    /// The restorer asks one set per list, resolves a removal through the index over the generated
    /// slots, and keeps one direct comparison: the anchor.
    func testTheRestorerComparesThroughTheSetsAndTheIndex() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/SeriesExceptions.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "static func restore<Occurrence, OneOff>(", in: file))
        XCTAssertEqual(count("let generatedSet = InstantSet(generatedSlots)", in: body), 1)
        XCTAssertEqual(count("func isGenerated(_ slot: Date) -> Bool { generatedSet.contains(slot) }", in: body), 1)
        XCTAssertEqual(count("let generatedIndex = InstantIndex(generatedSlots)", in: body), 1)
        XCTAssertEqual(count("resolve: { slot in generatedIndex.firstPosition(sameInstantAs: slot).map { generated[$0].occurrence } },", in: body), 1)
        XCTAssertEqual(count("let detachedSet = InstantSet(exceptions.detached.map(\\.slot))", in: body), 1)
        XCTAssertEqual(count("let stayedDeleted = surplus.filter { !detachedSet.contains($0) }.count", in: body), 1)
        XCTAssertEqual(count("InstantSet(", in: body), 2)
        XCTAssertEqual(count("InstantIndex(", in: body), 1)
        XCTAssertEqual(count("sameInstant", in: body), 2, "the anchor's one comparison, and the lookup's argument label")
        XCTAssertEqual(count("func isAnchor(_ slot: Date) -> Bool { UndoPostState.sameInstant(seriesStart, slot) }", in: body), 1)
        XCTAssertFalse(body.contains("generated.first"))
        XCTAssertFalse(body.contains("generatedSlots.contains"))
        XCTAssertFalse(body.contains("exceptions.detached.contains { UndoPostState"))
        // The index is over the same slots, in the same order, as the list it gives positions into.
        XCTAssertEqual(count("let generatedSlots = generated.map(\\.slot)", in: body), 1)

        let surplus = try XCTUnwrap(SourcePins.body(of: "static func surplusSlots(generated: [Date], exceptions: SeriesExceptions) -> [Date]", in: file))
        XCTAssertEqual(count("let kept = InstantSet(exceptions.keptSlots)", in: surplus), 1)
        XCTAssertEqual(count("SeriesExceptionsPlanner.inWindows(slot, exceptions.windows) && !kept.contains(slot)", in: surplus), 1)
        XCTAssertEqual(count("generated.filter {", in: surplus), 1, "the generated slots in their own order")
        XCTAssertFalse(surplus.contains("sameInstant"))
        XCTAssertFalse(surplus.contains("keptSlots.contains"))
    }

    /// The update record: `sameSlots` and `diff` ask a set per list, and the edited occurrence at a
    /// slot is found through an index over its list's slots.
    func testTheUpdateRecordComparesThroughTheSetsAndTheIndex() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/SeriesUpdateUndo.swift"))
        let same = try XCTUnwrap(SourcePins.body(of: "static func sameSlots(_ a: [Date], _ b: [Date]) -> Bool", in: file))
        XCTAssertEqual(count("let held = InstantSet(b)", in: same), 1)
        XCTAssertEqual(count("return a.allSatisfy { held.contains($0) }", in: same), 1)
        XCTAssertEqual(count("guard a.count == b.count else { return false }", in: same), 1)
        XCTAssertFalse(same.contains("sameInstant"))
        XCTAssertFalse(same.contains("b.contains"))

        let follow = try XCTUnwrap(SourcePins.body(of: "static func occurrencesFollowOrKeep(", in: file))
        XCTAssertEqual(count("let afterIndex = InstantIndex(after.detached.map(\\.slot))", in: follow), 1)
        XCTAssertEqual(count("guard let position = afterIndex.firstPosition(sameInstantAs: was.slot) else { return false }", in: follow), 1)
        XCTAssertEqual(count("let now = after.detached[position]", in: follow), 1)
        XCTAssertEqual(count("guard sameSlots(before.keptSlots, after.keptSlots) else { return false }", in: follow), 1)
        XCTAssertFalse(follow.contains("after.detached.first"))
        XCTAssertFalse(follow.contains("UndoPostState.sameInstant"))

        let diff = try XCTUnwrap(SourcePins.body(of: "static func diff(recorded: SeriesExceptions, current: SeriesExceptions) -> ExceptionsDiff", in: file))
        XCTAssertEqual(count("let recordedSet = InstantSet(recordedSlots)", in: diff), 1)
        XCTAssertEqual(count("let currentSet = InstantSet(currentSlots)", in: diff), 1)
        XCTAssertEqual(count("let recordedDetached = InstantIndex(recorded.detached.map(\\.slot))", in: diff), 1)
        XCTAssertEqual(count("let currentDetached = InstantIndex(current.detached.map(\\.slot))", in: diff), 1)
        XCTAssertEqual(count("InstantSet(", in: diff), 2)
        XCTAssertEqual(count("InstantIndex(", in: diff), 2)
        XCTAssertEqual(count("for slot in recordedSlots where !currentSet.contains(slot) { result.deleted.append(slot) }", in: diff), 1)
        XCTAssertEqual(count("for slot in currentSlots where !recordedSet.contains(slot) { result.added.append(slot) }", in: diff), 1)
        XCTAssertEqual(count("for slot in recordedSlots where currentSet.contains(slot) {", in: diff), 1)
        XCTAssertEqual(count("recordedDetached.firstPosition(sameInstantAs: slot).map { recorded.detached[$0] }", in: diff), 1)
        XCTAssertEqual(count("currentDetached.firstPosition(sameInstantAs: slot).map { current.detached[$0] }", in: diff), 1)
        XCTAssertFalse(diff.contains("UndoPostState.sameInstant"))
        XCTAssertFalse(diff.contains(".first {"))

        // What is left in the file: the two single passes of `firstSlotIsPlain`.
        XCTAssertEqual(count("UndoPostState.sameInstant", in: file), 2)
        let plain = try XCTUnwrap(SourcePins.body(of: "static func firstSlotIsPlain(", in: file))
        XCTAssertEqual(count("UndoPostState.sameInstant", in: plain), 2)
    }

    /// The three structures compare with `UndoPostState.sameInstant`, element first, as the scans did,
    /// and are declared beside the counter (the file #520's pin exempts), so no other file of the
    /// server names a counter.
    func testTheStructuresUseTheSameComparison() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/InstantSet.swift"))
        let lookup = try XCTUnwrap(SourcePins.body(of: "func firstPosition(sameInstantAs query: Date) -> Int?", in: file))
        XCTAssertEqual(count("guard UndoPostState.sameInstant(sorted[index].instant, query) else { break }", in: lookup), 2)
        XCTAssertEqual(count("UndoPostState.sameInstant(", in: lookup), 2)
        XCTAssertEqual(count("first = min(first ?? sorted[index].position, sorted[index].position)", in: lookup), 2)
        let insert = try XCTUnwrap(SourcePins.body(of: "mutating func insert(_ instant: Date) -> Bool", in: file))
        XCTAssertEqual(count("if UndoPostState.sameInstant(sorted[low], instant) { return false }", in: insert), 1)
        XCTAssertEqual(count("if UndoPostState.sameInstant(sorted[low - 1], instant) { return false }", in: insert), 1)
        XCTAssertEqual(count("UndoPostState.sameInstant(", in: insert), 2)
        XCTAssertEqual(count("guard !instant.timeIntervalSinceReferenceDate.isNaN else { return true }", in: insert), 1)
        XCTAssertEqual(count("struct InstantIndex {", in: file), 1)
        XCTAssertEqual(count("struct DistinctInstants {", in: file), 1)
    }

    /// Nothing in the server binds the probe: it is read where a set is built (three initializers in
    /// one file) and bound by tests only.
    func testNothingInTheServerBindsTheProbe() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the scan must read the source tree")
        var reads = 0
        for file in files {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(code.contains("$probe"), "\(file.lastPathComponent): the probe is bound through `$probe.withValue`, by tests only")
            if file.lastPathComponent == "InstantSet.swift" {
                reads = count("counter ?? ComparisonCounter.probe", in: code)
                XCTAssertEqual(count("probe", in: code), 4, "the declaration and the three reads")
                XCTAssertEqual(count("@TaskLocal static var probe: ComparisonCounter?", in: code), 1)
            } else if file.lastPathComponent != "DeletedOccurrenceCheck.swift" {
                // #520's `verdict` takes a counter by parameter; no other file names one.
                XCTAssertFalse(code.contains("ComparisonCounter"), file.lastPathComponent)
            }
        }
        XCTAssertEqual(reads, 3)
    }

    /// The copies of `main`'s functions the equivalence tests run reach none of the new structures,
    /// and still hold the scans they are kept for.
    func testTheCopiesOfMainCallNoNewHelper() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Helpers/UndoSlotComparisonsOnMain.swift")
        let code = SourcePins.code(try String(contentsOf: helper, encoding: .utf8))
        for name in ["InstantSet", "InstantIndex", "DistinctInstants", "firstPosition", "ComparisonCounter"] {
            XCTAssertFalse(code.contains(name), name)
        }
        XCTAssertEqual(count("if !generated.contains(where: { UndoPostState.sameInstant($0.slot, slot) }) { generated.append((slot, occurrence)) }", in: code), 1)
        XCTAssertEqual(count("func isGenerated(_ slot: Date) -> Bool { generatedSlots.contains { UndoPostState.sameInstant($0, slot) } }", in: code), 1)
        XCTAssertEqual(count("resolve: { slot in generated.first { UndoPostState.sameInstant($0.slot, slot) }?.occurrence },", in: code), 1)
        XCTAssertEqual(count("!exceptions.detached.contains { UndoPostState.sameInstant($0.slot, slot) }", in: code), 1)
        XCTAssertEqual(count("&& !exceptions.keptSlots.contains { UndoPostState.sameInstant($0, slot) }", in: code), 1)
        XCTAssertEqual(count("a.count == b.count && a.allSatisfy { slot in b.contains { UndoPostState.sameInstant($0, slot) } }", in: code), 1)
        XCTAssertEqual(count("guard let now = after.detached.first(where: { UndoPostState.sameInstant($0.slot, was.slot) }) else { return false }", in: code), 1)
        XCTAssertEqual(count("func contains(_ slots: [Date], _ slot: Date) -> Bool { slots.contains { UndoPostState.sameInstant($0, slot) } }", in: code), 1)
        XCTAssertEqual(count("list.first { UndoPostState.sameInstant($0.slot, slot) }", in: code), 1)
        // A copy calls copies: the restorer its surplus slots, the store-level restore the restorer,
        // follow-or-keep its `sameSlots`.
        XCTAssertEqual(count("SeriesExceptionsPlanner.surplusSlotsOnMain(", in: code), 1)
        XCTAssertEqual(count("try SeriesExceptionsRestorer.restoreOnMain(", in: code), 1)
        XCTAssertEqual(count("guard sameSlotsOnMain(", in: code), 1)
        XCTAssertFalse(code.contains("SeriesExceptionsPlanner.surplusSlots("))
        XCTAssertFalse(code.contains("SeriesExceptionsRestorer.restore("))
        XCTAssertFalse(code.contains("guard sameSlots("))
    }
}
