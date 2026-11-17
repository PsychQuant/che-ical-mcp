import Foundation

/// #538: the undo of a delete writes a new item from the record's snapshot, and the store gives it
/// a new identifier (measured on iCloud, 2026-11-13, for a one-off event and a reminder; for a
/// series under #335). Older undo and redo records still name the removed identifier; this type
/// holds the rule for when they follow the recreated item, and the two texts said when a series
/// does not.
enum DeleteUndoFollow {
    /// The identifier a delete record holds: the event's own, and for an event with rules the
    /// series' identifier without a `/RID=` part (the #326 stand-in is an occurrence whose
    /// identifier can carry one). Empty when the event had none. Also normalizes the identifier
    /// of a recreated series, so a followed record never names one occurrence of it.
    static func removedIdentifier(eventIdentifier: String?, hasRules: Bool) -> String {
        guard let id = eventIdentifier, !id.isEmpty else { return "" }
        return hasRules ? (DetachedOccurrenceSpan.seriesIdentifier(of: id) ?? id) : id
    }

    /// What the undo of an event's delete does with older records of the removed identifier.
    enum Decision: Equatable {
        /// Move them to this identifier (`CalendarUndoManager.replaceEventIdentifier`).
        case follow(String)
        /// A series whose `oneOffs` occurrences edited on their own came back as separate events and
        /// that reads back under another identifier (or none): nothing follows, and the records are
        /// flagged (`CalendarUndoManager.markSeriesNotFollowed`).
        case flag(oneOffs: Int)
        /// Nothing follows and nothing is flagged.
        case none
    }

    /// The closed list of the spec requirement "Records follow an item the undo of its delete
    /// recreated", for events. `newID` is the recreated event's identifier, nil when the undo wrote
    /// nothing (a slot its series already holds). `isOccurrenceRecord`: the snapshot is one
    /// occurrence of a series (`.deleteOccurrence`, a split move, the rule-less record of one
    /// occurrence). `outcome` is what the arm returned: nil for a one-off event, a series outcome for
    /// a series, an occurrence outcome for one occurrence.
    static func decision(removedID: String, newID: String?, isOccurrenceRecord: Bool,
                         outcome: UndoEventOutcome?) -> Decision {
        guard !isOccurrenceRecord, !removedID.isEmpty else { return .none }
        let follow: Decision = {
            guard let newID, !newID.isEmpty, newID != removedID else { return .none }
            return .follow(newID)
        }()
        switch outcome {
        case nil, .seriesFromRules?:
            return follow
        case .seriesWithExceptions(let restored)?:
            guard restored.oneOffs > 0 else { return follow }
            // #538 fix 1 (F26): a recreated series under the removed identifier is the series the
            // older records name, so there is nothing to flag or to say.
            return newID == removedID ? .none : .flag(oneOffs: restored.oneOffs)
        case .occurrenceOneOff?, .occurrenceOneOffSlotUnchecked?, .occurrenceAlreadyHeld?, .editedOccurrenceAlreadyHeld?:
            return .none
        }
    }

    /// The identifier older records move to, or nil (`decision`'s `.follow`).
    static func identifierToFollow(removedID: String, newID: String?, isOccurrenceRecord: Bool,
                                   outcome: UndoEventOutcome?) -> String? {
        guard case .follow(let id) = decision(removedID: removedID, newID: newID, isOccurrenceRecord: isOccurrenceRecord,
                                              outcome: outcome) else { return nil }
        return id
    }

    /// The reminder counterpart: records follow when the save returned with an identifier that is
    /// not empty and differs from the removed one.
    static func reminderIdentifierToFollow(removedID: String, newID: String) -> String? {
        guard !removedID.isEmpty, !newID.isEmpty, newID != removedID else { return nil }
        return newID
    }

    /// Ends the answer of a series delete's undo when older records of the series were flagged
    /// instead of moved. Fixed words and a count; the title and the new ID are in the answer before it.
    /// #538 fix 1 (R3): the last sentence speaks of an entry whose undo is not found, which is what
    /// answers the flagged text; an entry of an update that touched the series is neither flagged
    /// nor counted, and its undo is refused and discarded before any lookup.
    static func notFollowedSentence(oneOffs: Int) -> String {
        "Older undo entries of this series were not moved to the recreated series, because \(oneOffs) of its occurrences that had been edited on their own came back as separate events." + notFollowedWayOn
    }

    /// The last sentence of both forms.
    private static let notFollowedWayOn = " An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id."

    /// #538 fix 1 (R1): the batch form, for the members of a batch undo whose older records were
    /// flagged: their `oneOffs`, one entry per member. Nil when there are none.
    static func batchNotFollowedSentence(_ oneOffs: [Int]) -> String? {
        guard !oneOffs.isEmpty else { return nil }
        let total = oneOffs.reduce(0, +)
        let which = oneOffs.count == 1
            ? "Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because \(total) of its occurrences"
            : "Older undo entries of \(oneOffs.count) recurring events this batch recreated were not moved to their recreated series, because \(total) of their occurrences"
        return which + " that had been edited on their own came back as separate events." + notFollowedWayOn
    }

    /// The answer of a delete's undo with the sentence above appended.
    static func appendingNotFollowed(_ text: String, oneOffs: Int) -> String {
        text + ". " + notFollowedSentence(oneOffs: oneOffs)
    }
}

