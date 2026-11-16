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
                       "Older undo entries of this series were not moved to the recreated series, because 2 of its occurrences that had been edited on their own came back as separate events. An undo of those entries will answer that; they can only be given up with discard_id.")
        XCTAssertEqual(DeleteUndoFollow.appendingNotFollowed("Undone: restored event 'S' (new ID: E1). Note", oneOffs: 1),
                       "Undone: restored event 'S' (new ID: E1). Note. " + DeleteUndoFollow.notFollowedSentence(oneOffs: 1))
    }

    /// The title through `undoShownTitle`: a quote replaced, a hidden character dropped; nothing
    /// else of the record is in the text.
    func testTheNotFollowedRefusal() {
        let title = "Stand'up\u{202E}"
        let message = UndoTargetMissingError.seriesNotFollowed(title: title).message
        XCTAssertEqual(message, "Cannot undo: the recurring event '\(undoShownTitle(title))' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names is not the one that exists now. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.")
        XCTAssertFalse(message.contains("Stand'up"), "the quote is replaced")
        XCTAssertFalse(message.contains("\u{202E}"), "the hidden character is dropped")
        XCTAssertEqual(UndoFailureDisposition.of(UndoTargetMissingError.seriesNotFollowed(title: "S")), .restore, "kept, as every not-found")
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
