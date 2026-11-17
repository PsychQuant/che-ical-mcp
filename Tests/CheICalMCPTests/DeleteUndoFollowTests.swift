import XCTest
@testable import CheICalMCP

/// #538: the rule for when older undo records follow an item that the undo of its delete
/// recreated under a new identifier, and the texts said about it. Pure values: the rule is a
/// closed list (`DeleteUndoFollow.decision`), one assertion per row of the spec's table.
final class DeleteUndoFollowTests: XCTestCase {
    private func decide(_ removed: String, _ new: String?, occurrence: Bool = false,
                        _ outcome: UndoEventOutcome?) -> DeleteUndoFollow.Decision {
        DeleteUndoFollow.decision(removedID: removed, newID: new, isOccurrenceRecord: occurrence, outcome: outcome)
    }

    private func withExceptions(stayedDeleted: Int = 0, oneOffs: Int, firstKept: Bool = false,
                                notApplied: Bool = false) -> UndoEventOutcome {
        .seriesWithExceptions(.init(stayedDeleted: stayedDeleted, oneOffs: oneOffs,
                                    firstOccurrenceKeptFromRule: firstKept, notApplied: notApplied))
    }

    // MARK: - the closed list

    /// spec-example: undo-history-discard / the closed list of the follow rule
    func testTheClosedListOfTheFollowRule() {
        XCTAssertEqual(decide("A", "B", nil), .follow("B"), "a one-off event follows")
        XCTAssertEqual(decide("S", "T", .seriesFromRules), .follow("T"), "a series from its rules follows")
        XCTAssertEqual(decide("S", "T", withExceptions(oneOffs: 0)), .follow("T"), "no separate events: follows")
        XCTAssertEqual(decide("S", "T", withExceptions(oneOffs: 1)), .flag(oneOffs: 1), "a separate event: flagged, not followed")
        XCTAssertEqual(decide("A", "B", occurrence: true, .occurrenceOneOff(notCarriedOver: [])), .none, "an occurrence record")
        XCTAssertEqual(decide("A", nil, nil), .none, "nothing written")
        XCTAssertEqual(decide("", "B", nil), .none, "no removed identifier")
        XCTAssertEqual(decide("A", "A", nil), .none, "the same identifier")
        XCTAssertEqual(decide("S", "S", withExceptions(oneOffs: 1)), .none, "a series that kept its identifier: not flagged")
    }

    /// #538 fix 1 (F26): a recreated series that reads back under the removed identifier is not
    /// flagged, whatever came back as separate events: the older records still name the series that
    /// exists, and a flag would make its sentence promise a refusal that does not come. iCloud gave
    /// every recreated series a new identifier as measured (#335, #538), so this row is not reached
    /// there; it holds the rule for a store that keeps the identifier.
    func testASeriesThatKeptTheRemovedIdentifierIsNotFlagged() {
        XCTAssertEqual(decide("S", "S", withExceptions(oneOffs: 1)), .none)
        XCTAssertEqual(decide("S", "S", withExceptions(stayedDeleted: 2, oneOffs: 3)), .none)
        XCTAssertEqual(decide("S", "S", withExceptions(oneOffs: 0)), .none, "nor followed, as before")
        XCTAssertEqual(decide("S", "T", withExceptions(oneOffs: 1)), .flag(oneOffs: 1), "another identifier is still flagged")
    }

    /// The series outcomes whose `oneOffs` is zero all follow: an occurrence deleted on its own that
    /// stayed deleted, exceptions not applied, a first occurrence kept from the rule.
    func testEverySeriesOutcomeWithoutSeparateEventsFollows() {
        XCTAssertEqual(decide("S", "T", withExceptions(stayedDeleted: 2, oneOffs: 0)), .follow("T"))
        XCTAssertEqual(decide("S", "T", withExceptions(oneOffs: 0, notApplied: true)), .follow("T"))
        XCTAssertEqual(decide("S", "T", withExceptions(oneOffs: 0, firstKept: true)), .follow("T"))
    }

    /// A flagged series is flagged whatever the new identifier, also when the store wrote none:
    /// the flag says why the records stay, not where they go.
    func testASeriesWithSeparateEventsIsFlaggedWithItsCount() {
        XCTAssertEqual(decide("S", "T", withExceptions(stayedDeleted: 1, oneOffs: 3)), .flag(oneOffs: 3))
        XCTAssertEqual(decide("S", nil, withExceptions(oneOffs: 2)), .flag(oneOffs: 2))
        XCTAssertEqual(decide("", "T", withExceptions(oneOffs: 2)), .none, "nothing to flag without the removed identifier")
    }

    /// Every outcome of one occurrence's undo: no record follows and none is flagged.
    func testNoOccurrenceOutcomeFollowsOrFlags() {
        let outcomes: [UndoEventOutcome] = [.occurrenceOneOff(notCarriedOver: []), .occurrenceOneOffSlotUnchecked(notCarriedOver: []),
                                            .occurrenceAlreadyHeld, .editedOccurrenceAlreadyHeld]
        for outcome in outcomes {
            XCTAssertEqual(decide("A", "B", outcome), .none, "\(outcome)")
        }
        XCTAssertEqual(decide("A", "B", occurrence: true, nil), .none, "an occurrence record without an outcome")
        XCTAssertEqual(decide("S", "T", occurrence: true, .seriesFromRules), .none, "an occurrence record is never followed")
        XCTAssertEqual(decide("A", "", nil), .none, "an empty new identifier")
    }

    func testIdentifierToFollowIsTheFollowCase() {
        XCTAssertEqual(DeleteUndoFollow.identifierToFollow(removedID: "A", newID: "B", isOccurrenceRecord: false, outcome: nil), "B")
        XCTAssertNil(DeleteUndoFollow.identifierToFollow(removedID: "S", newID: "T", isOccurrenceRecord: false,
                                                         outcome: withExceptions(oneOffs: 1)))
    }

    func testTheReminderRule() {
        XCTAssertEqual(DeleteUndoFollow.reminderIdentifierToFollow(removedID: "R1", newID: "R2"), "R2")
        XCTAssertNil(DeleteUndoFollow.reminderIdentifierToFollow(removedID: "R1", newID: "R1"))
        XCTAssertNil(DeleteUndoFollow.reminderIdentifierToFollow(removedID: "", newID: "R2"))
        XCTAssertNil(DeleteUndoFollow.reminderIdentifierToFollow(removedID: "R1", newID: ""))
    }

    // MARK: - the removed identifier

    /// A series is recorded and followed without a `/RID=` part, so a record never names one
    /// occurrence of it; a one-off keeps its identifier as it is.
    func testTheRemovedIdentifier() {
        XCTAssertEqual(DeleteUndoFollow.removedIdentifier(eventIdentifier: "S", hasRules: true), "S")
        XCTAssertEqual(DeleteUndoFollow.removedIdentifier(eventIdentifier: "S/RID=800000000", hasRules: true), "S")
        XCTAssertEqual(DeleteUndoFollow.removedIdentifier(eventIdentifier: "A/RID=800000000", hasRules: false), "A/RID=800000000")
        XCTAssertEqual(DeleteUndoFollow.removedIdentifier(eventIdentifier: "A", hasRules: false), "A")
        XCTAssertEqual(DeleteUndoFollow.removedIdentifier(eventIdentifier: nil, hasRules: true), "")
        XCTAssertEqual(DeleteUndoFollow.removedIdentifier(eventIdentifier: "", hasRules: false), "")
    }

    // MARK: - texts

    func testTheNotFollowedSentence() {
        XCTAssertEqual(DeleteUndoFollow.notFollowedSentence(oneOffs: 2),
                       "Older undo entries of this series were not moved to the recreated series, because 2 of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.")
        XCTAssertEqual(DeleteUndoFollow.appendingNotFollowed("Undone: restored event 'S' (new ID: E1). Note", oneOffs: 1),
                       "Undone: restored event 'S' (new ID: E1). Note. " + DeleteUndoFollow.notFollowedSentence(oneOffs: 1))
    }

    /// spec-example: undo-history-discard / the batch form
    func testTheBatchSentence() {
        XCTAssertNil(DeleteUndoFollow.batchNotFollowedSentence([]), "no member flagged anything: no sentence")
        XCTAssertEqual(DeleteUndoFollow.batchNotFollowedSentence([2]),
                       "Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because 2 of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.")
        XCTAssertEqual(DeleteUndoFollow.batchNotFollowedSentence([1, 3]),
                       "Older undo entries of 2 recurring events this batch recreated were not moved to their recreated series, because 4 of their occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.")
    }

    /// The batch answer ends with the batch sentence when a member flagged older records, and is
    /// the text of before when none did.
    func testTheBatchAnswerEndsWithTheSentence() {
        let plain = UndoOperation.batchUndoneMessage(count: 2)
        XCTAssertEqual(plain, "Undone batch (2 operations)")
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: 2, notFollowed: []), plain)
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: 2, notFollowed: [1]),
                       "Undone batch (2 operations). Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because 1 of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.")
        let named = UndoOperation.batchUndoneMessage(count: 1, differing: [UndoRestoredDifference(title: "Rent", storeDiffers: ["due"])],
                                                     notFollowed: [2])
        XCTAssertTrue(named.hasPrefix("Undone batch (1 operation). Restored reminder 'Rent' — the store holds a different due; check it. Older undo entries of a recurring event"), named)
        XCTAssertTrue(named.hasSuffix("the entry can only be given up with discard_id."), named)
    }

    /// The title through `undoShownTitle`: a quote replaced, a hidden character dropped; nothing
    /// else of the record is in the text.
    func testTheNotFollowedRefusal() {
        let title = "Stand'up\u{202E}"
        let message = UndoTargetMissingError.seriesNotFollowed(title: title).message
        XCTAssertEqual(message, "Cannot undo: the recurring event '\(undoShownTitle(title))' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names no longer exists. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.")
        XCTAssertFalse(message.contains("Stand'up"), "the quote is replaced")
        XCTAssertFalse(message.contains("\u{202E}"), "the hidden character is dropped")
        XCTAssertEqual(UndoFailureDisposition.of(UndoTargetMissingError.seriesNotFollowed(title: "S")), .restore, "kept, as every not-found")
    }

    /// #538 fix 1 (F18): a title with a line break loses it, and one over 120 scalars is cut with an
    /// ellipsis, in the production builder; the expected strings are written out, not rebuilt.
    func testTheNotFollowedRefusalDropsALineBreakAndCapsTheTitle() {
        let lineBreak = UndoTargetMissingError.seriesNotFollowed(title: "Stand\nup").message
        XCTAssertTrue(lineBreak.hasPrefix("Cannot undo: the recurring event 'Standup' was deleted and then recreated by an undo"), lineBreak)
        XCTAssertFalse(lineBreak.contains("\n"), lineBreak)
        let long = UndoTargetMissingError.seriesNotFollowed(title: String(repeating: "x", count: 121)).message
        XCTAssertTrue(long.hasPrefix("Cannot undo: the recurring event '" + String(repeating: "x", count: 120) + "…' was deleted"), long)
    }

    /// #538 fix 1 (F17): a title forged to look like the identifier and the note, with the new
    /// identifier present, as production passes it after a save: the title stays inside its quotes,
    /// and the real suffix and note come right after the closing quote.
    func testAForgedTitleCannotForgeTheNewIdentifier() {
        let forged = "Rent' (new ID: FAKE) — the store holds a different due; check it\nx"
        let message = EventKitManager.restoredReminderMessage((title: forged, storeDiffers: ["title"], newID: "R2"))
        XCTAssertEqual(message, "Undone: restored reminder 'Rent\u{2019} (new ID: FAKE) — the store holds a different due; check itx' (new ID: R2) — the store holds a different title; check it")
        XCTAssertEqual(message.filter { $0 == "'" }.count, 2, message)
        XCTAssertFalse(message.contains("\n"), message)
    }

    /// The reminder delete's undo ends with the new identifier, before the note on fields the store
    /// holds differently; without one it is the text of before.
    func testTheReminderAnswerGivesTheNewIdentifier() {
        XCTAssertEqual(EventKitManager.restoredReminderMessage((title: "Pay rent", storeDiffers: [], newID: "R2")),
                       "Undone: restored reminder 'Pay rent' (new ID: R2)")
        XCTAssertEqual(EventKitManager.restoredReminderMessage((title: "Pay rent", storeDiffers: [], newID: "")),
                       "Undone: restored reminder 'Pay rent'")
        let withNote = EventKitManager.restoredReminderMessage((title: "Pay rent", storeDiffers: ["due_date"], newID: "R2"))
        XCTAssertEqual(withNote, "Undone: restored reminder 'Pay rent' (new ID: R2)" + NewObjectSave.undoSuffix(["due_date"]))
    }
}
