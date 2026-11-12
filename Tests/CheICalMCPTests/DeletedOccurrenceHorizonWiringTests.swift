import XCTest
@testable import CheICalMCP

/// #506: the horizon reaches the store only through `updateEvent` and `deletedOccurrenceVerdict`, which
/// no unit test runs. These pins read the source.
final class DeletedOccurrenceHorizonWiringTests: XCTestCase {
    /// `updateEvent` passes now as the horizon's start only for a change in the same account without a
    /// new rule pattern, records a `noneThrough` verdict, and both of its return points carry it (the
    /// #428 path goes through the first occurrence's own id and rebuilds the tuple).
    func testUpdateEventPassesTheHorizonOnlyForTheDecidedChangesAndReturnsIt() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        XCTAssertTrue(update.contains("horizonFrom: crossesAccounts || changesPattern ? nil : Date())"))
        XCTAssertEqual(SourcePins.ranges(of: "horizonFrom:", in: update).count, 1)
        XCTAssertTrue(update.contains("case .noneThrough(let until): deletionsChecked = DeletionCheckHorizon(until: until, zone: Self.occurrenceZone(of: event))"))
        XCTAssertTrue(update.contains("return (event, seriesIdentifier, matchedOccurrence, deletionsChecked)"))
        XCTAssertTrue(update.contains("saved.matchedOccurrence,\n                        saved.deletionsChecked)"))
        // The onlyTheAccount arm cannot swallow a noneThrough: it comes after it.
        let through = try XCTUnwrap(update.range(of: "case .noneThrough(let until):"))
        let account = try XCTUnwrap(update.range(of: "case _ where onlyTheAccount:"))
        XCTAssertLessThan(through.lowerBound, account.lowerBound)
        // The value seam and the response carry it.
        let seam = SourcePins.code(try SourcePins.source("EventWriteSource.swift"))
        XCTAssertTrue(seam.contains("value.deletionsChecked = saved.deletionsChecked"))
        let server = SourcePins.code(try SourcePins.source("Server.swift"))
        XCTAssertTrue(server.contains("if let checked = event.deletionsChecked {"))
        let serverText = try SourcePins.source("Server.swift")
        XCTAssertTrue(serverText.contains("response[\"deleted_occurrences_checked_until\"] = until"))
        XCTAssertTrue(serverText.contains("response[\"deleted_occurrences_note\"] = DeletedOccurrenceCheck.horizonNote(checkedUntil: until)"))
    }

    /// The other callers of the verdict pass no horizon: a move to another account still needs the
    /// whole series covered.
    func testTheMoveAndUndoCallersPassNoHorizon() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let move = try XCTUnwrap(SourcePins.body(of: "func moveEvent(", in: manager))
        XCTAssertFalse(move.contains("horizonFrom"))
        let guardFile = SourcePins.code(try SourcePins.source("EventKit/EventKitManager+UndoGuard.swift"))
        XCTAssertFalse(guardFile.contains("horizonFrom"))
    }

    /// `deletedOccurrenceVerdict` lists over the horizon's ranges, takes "covers the series" from the
    /// unbroken listing from the first start, and hands the ranges and the horizon to the verdict.
    func testTheVerdictListsAroundNowAndPassesTheRanges() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "func deletedOccurrenceVerdict(", in: file))
        XCTAssertTrue(body.contains("let horizon = now.flatMap { DeletedOccurrenceCheck.horizon(now: $0, calendar: calendar) }"))
        XCTAssertTrue(body.contains("let ranges = DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now ?? Date())"))
        XCTAssertTrue(body.contains("seriesOccurrences(of: series, id: id, ranges: ranges)"))
        XCTAssertTrue(body.contains("scannedTo: DeletedOccurrenceCheck.listedEnd(of: ranges, from: $0) ?? $0, calendar: calendar)"))
        XCTAssertTrue(body.contains("listed: ranges, horizon: horizon)"))
        // The horizon is taken in the zone the rule is expanded in, declared before it.
        let zone = try XCTUnwrap(body.range(of: "let calendar = Calendar.gregorian(in: zone)"))
        let horizon = try XCTUnwrap(body.range(of: "let horizon = now.flatMap"))
        XCTAssertLessThan(zone.lowerBound, horizon.lowerBound)
        let occurrences = try XCTUnwrap(SourcePins.body(of: "private func seriesOccurrences(", in: file))
        XCTAssertTrue(occurrences.contains("for range in ranges ?? SeriesExceptionsPlanner.listingRanges(for: window) {"))
    }
}
