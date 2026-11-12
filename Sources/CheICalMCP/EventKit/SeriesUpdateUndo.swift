import CheMCPKit
import EventKit
import Foundation

/// #263 (maintainer decision 2026-11-12, "先做 iCloud 的整串修改 undo"): the first recurring update
/// that undo restores. Every other update that touches a recurring event stays the #236 marker,
/// refused and discarded (`RecurringUpdateKind`).
///
/// The record is taken only for an `update_event` with span "all" through the series' own object
/// (not an occurrence's own identifier, #416 / #428, nor a stand-in, #326), on an iCloud calendar,
/// that wrote nothing but `title`, `notes` or `location`, on a series the exceptions listing covers
/// whole. Those three fields are the only inverse measured on device (Diagnosis 2026-11-09: the
/// inverse span-all write gave back the listing before the update, field for field, with an
/// occurrence deleted and one edited on their own). A time, zone, all-day, calendar, alarm or rule
/// change is not restored: its inverse would bypass the forward refusals of `update_event` (#503,
/// #509, #451, #478, #513), several of which depend on the time of the call.
///
/// The undo writes only when, read again, the series is the one the update left apart from the
/// update itself: the same identifiers, the same rule, still on iCloud, its fields as the update
/// left them (#236's guard), and its occurrences edited or deleted on their own exactly those after
/// the update. Then it writes the old values with span "all" in one save and reads back. Pure; the
/// EventKit side is `EventKitManager+SeriesUpdateUndo.swift`.
struct SeriesUpdateRecord {
    /// The series' identifier after the save.
    let id: String
    let externalIdentifier: String?
    /// The series before the update, with its rules.
    let old: EventSnapshot
    /// The series as the update left it, read back by identifier (`postWriteSnapshot`).
    let saved: EventSnapshot
    /// What the update wrote and the undo writes back, in `SeriesUpdateUndo.restorableOrder`.
    let fields: [String]
    /// The series' exceptions before the save: what the read-back after the restore must show.
    let before: SeriesExceptions
    /// The exceptions after the save, over `before.windows`: what the undo compares with. A
    /// span-all write also writes into occurrences edited on their own (device 2026-11-09: one took
    /// the new notes and location), so this is not `before`.
    let after: SeriesExceptions

    /// #435: the same record under the identifier a later move gave the series.
    func replacingIdentifier(_ new: String) -> SeriesUpdateRecord {
        SeriesUpdateRecord(id: new, externalIdentifier: externalIdentifier, old: old, saved: saved, fields: fields,
                           before: before, after: after)
    }
}

enum SeriesUpdateUndo {
    /// The fields whose inverse was measured (Diagnosis 2026-11-09), in the order texts list them.
    static let restorableOrder = ["title", "notes", "location"]
    /// The keys of an `update_event` call that write nothing.
    static let addressKeys: Set<String> = ["event_id", "span"]

    /// What the call wrote, when every key it passed is an address key or a restorable field and it
    /// wrote at least one field; nil otherwise. A key it does not know is not restorable (fail closed).
    static func restorableFields(requested: Set<String>) -> [String]? {
        let written = requested.subtracting(addressKeys)
        guard !written.isEmpty, written.isSubset(of: Set(restorableOrder)) else { return nil }
        return restorableOrder.filter(written.contains)
    }

    /// Whether a calendar's account is iCloud. EventKit has no type for it on current systems: an
    /// iCloud account is a CalDAV source titled "iCloud" (the title Calendar shows; the legacy
    /// `.mobileMe` type counts too). Fail closed: any other type or title, or no source, is not
    /// iCloud. Known limit: another CalDAV account whose title is exactly "iCloud" would pass.
    static func isICloud(sourceType: EKSourceType?, sourceTitle: String?) -> Bool {
        switch sourceType {
        case .mobileMe?: return true
        case .calDAV?: return sourceTitle == "iCloud"
        default: return false
        }
    }

    /// The restorable fields of an update, judged before its save from what the call is; nil keeps
    /// the #236 marker. A `location` string written over a place with coordinates is not restorable:
    /// writing the string back would not give the coordinates back.
    static func recordable(kind: RecurringUpdateKind?, wholeSeriesCall: Bool, throughOwnOccurrence: Bool, viaStandIn: Bool,
                           requested: Set<String>, isICloud: Bool, placeHasCoordinates: Bool) -> [String]? {
        guard kind == .series, wholeSeriesCall, !throughOwnOccurrence, !viaStandIn, isICloud,
              let fields = restorableFields(requested: requested) else { return nil }
        if fields.contains("location"), placeHasCoordinates { return nil }
        return fields
    }

    /// Whether an occurrence edited on its own held, before the update, the value the update wrote to
    /// a field, while the series held another. After the update it cannot be told from an occurrence
    /// that took the value from the series, so the inverse write could replace its own edit (the
    /// measured shape kept an own title that differed from both values). Such an update keeps the
    /// marker. nil and empty text are the same, as `differsFromSeries` reads them.
    static func editedOccurrenceHoldsWrittenValue(before: SeriesExceptions, old: EventSnapshot, saved: EventSnapshot,
                                                  fields: [String]) -> Bool {
        func value(_ field: String, _ event: EventSnapshot) -> String? {
            switch field {
            case "title": return event.title
            case "notes": return event.notes ?? ""
            case "location": return event.location ?? ""
            default: return nil
            }
        }
        return fields.contains { field in
            guard let new = value(field, saved), let was = value(field, old), new != was else { return false }
            return before.detached.contains { value(field, $0.snapshot) == new }
        }
    }

    /// Whether the listing saw every occurrence of the series: it starts and ends inside one of the
    /// listed windows (`SeriesExceptionsPlanner.deleteWindow`, at most 1460 days). A series with no
    /// end, or whose end cannot be shown, is never covered, so its update stays the marker.
    static func covers(_ exceptions: SeriesExceptions, firstStart: Date, end: SeriesExceptionsPlanner.SeriesEnd) -> Bool {
        guard !exceptions.seriesStartsBeforeWindow, !exceptions.seriesContinuesAfterWindow,
              !exceptions.seriesMayContinueAfterWindow else { return false }
        let last: Date
        switch end {
        case .endsAt(let date), .endsBy(let date): last = date
        case .open, .unknown: return false
        }
        return exceptions.windows.contains { $0.start <= firstStart && last < $0.end }
    }

    /// How two listings of a series' exceptions differ, by slot: occurrences gone (`deleted`), there
    /// now and not before (`added`, a deleted occurrence back or a new one), and occurrences edited
    /// on their own since, edited again, or no longer listed as edited (`edited`).
    struct ExceptionsDiff: Equatable {
        var deleted: [Date] = []
        var added: [Date] = []
        var edited: [Date] = []
        /// The listings were made over different windows, so they do not compare.
        var otherWindows = false

        var isEmpty: Bool { deleted.isEmpty && added.isEmpty && edited.isEmpty && !otherWindows }
    }

    static func diff(recorded: SeriesExceptions, current: SeriesExceptions) -> ExceptionsDiff {
        var result = ExceptionsDiff()
        guard recorded.windows == current.windows else {
            result.otherWindows = true
            return result
        }
        func contains(_ slots: [Date], _ slot: Date) -> Bool { slots.contains { UndoPostState.sameInstant($0, slot) } }
        func detached(_ list: [DetachedOccurrence], at slot: Date) -> DetachedOccurrence? {
            list.first { UndoPostState.sameInstant($0.slot, slot) }
        }
        let recordedSlots = recorded.keptSlots + recorded.detached.map(\.slot)
        let currentSlots = current.keptSlots + current.detached.map(\.slot)
        for slot in recordedSlots where !contains(currentSlots, slot) { result.deleted.append(slot) }
        for slot in currentSlots where !contains(recordedSlots, slot) { result.added.append(slot) }
        for slot in recordedSlots where contains(currentSlots, slot) {
            switch (detached(recorded.detached, at: slot), detached(current.detached, at: slot)) {
            case (nil, nil): continue
            case let (was?, now?):
                if !was.snapshot.changedFields(in: now.snapshot, restoring: nil).isEmpty { result.edited.append(slot) }
            default:
                result.edited.append(slot)
            }
        }
        result.deleted.sort()
        result.added.sort()
        result.edited.sort()
        return result
    }

    /// The series as the undo reads it, after #236's guard passed.
    struct Current {
        let eventIdentifier: String?
        let externalIdentifier: String?
        let hasRules: Bool
        let isDetached: Bool
        let rules: [RecurrenceRuleSnapshot]?
        let isICloud: Bool
        /// `covers` of the listing below, with the series' start and end read now.
        let covered: Bool
        /// The exceptions listed over the recorded windows; nil when they could not be listed.
        let exceptions: SeriesExceptions?
    }

    /// Why the undo writes nothing (the record is kept).
    enum Refusal: Equatable {
        /// The identifier no longer reads as the same series (another identifier, an occurrence, a one-off).
        case identity
        case ruleChanged
        case notICloud
        case notCovered
        case unlisted
        case exceptionsChanged(ExceptionsDiff)
    }

    /// The first reason the undo of `record` must not write, in a fixed order; nil when it may.
    static func refusal(_ record: SeriesUpdateRecord, current: Current) -> Refusal? {
        guard current.eventIdentifier == record.id, current.externalIdentifier == record.externalIdentifier,
              current.hasRules, !current.isDetached else { return .identity }
        guard RecurrenceRuleSnapshot.sameRules(record.saved.recurrenceRules, current.rules, allDay: record.saved.isAllDay) else {
            return .ruleChanged
        }
        guard current.isICloud else { return .notICloud }
        guard let exceptions = current.exceptions else { return .unlisted }
        guard current.covered else { return .notCovered }
        let diff = diff(recorded: record.after, current: exceptions)
        return diff.isEmpty ? nil : .exceptionsChanged(diff)
    }

    /// The way on of a kept refusal, in #269's words: it names no tool besides undo and undo_history.
    static let wayOn = "To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."

    static func refusalError(_ refusal: Refusal, title: String) -> SeriesUpdateUndoRefusal {
        let reason: String
        switch refusal {
        case .identity:
            reason = "its recorded identifier no longer reads as the same series (it is gone, an occurrence edited on its own, a one-off event, or another series now)"
        case .ruleChanged:
            reason = "the series' repetition was changed after the update"
        case .notICloud:
            reason = "its calendar is not on iCloud now, and undo restores a whole-series update only there"
        case .notCovered:
            reason = "the series no longer ends within the dates its occurrences were listed over, so occurrences changed after the update could not all be checked"
        case .unlisted:
            reason = "the occurrences of the series could not be listed to check them"
        case .exceptionsChanged(let diff):
            reason = "occurrences of the series were changed on their own after the update (\(changedCounts(diff)))"
        }
        return SeriesUpdateUndoRefusal(message: "Cannot undo the update of the recurring event '\(undoShownTitle(title))': \(reason). Undoing now could overwrite or lose changes made after the update, so nothing was written and this history entry was kept. \(wayOn)")
    }

    private static func changedCounts(_ diff: ExceptionsDiff) -> String {
        func count(_ n: Int, _ what: String) -> String? { n == 0 ? nil : "\(n) \(what) on \(n == 1 ? "its" : "their") own" }
        var parts = [count(diff.deleted.count, "deleted"), count(diff.edited.count, "edited")].compactMap { $0 }
        if !diff.added.isEmpty { parts.append("\(diff.added.count) back or added") }
        if diff.otherWindows { parts.append("listed over other dates") }
        return parts.joined(separator: ", ")
    }

    /// The series and its exceptions read back after the restore.
    struct ReadBack {
        let series: EventSnapshot?
        let exceptions: SeriesExceptions?
    }

    /// What the read-back shows differently from the state before the update; empty when it shows
    /// that state. Only what the undo wrote or could have changed is compared: the restored fields,
    /// the rule, and the exceptions (against the listing before the update).
    static func readBackMismatch(_ record: SeriesUpdateRecord, readBack: ReadBack) -> [String] {
        var mismatch: [String] = []
        if let series = readBack.series {
            let changed = record.old.changedFields(in: series, restoring: nil)
            mismatch += record.fields.filter(changed.contains)
            if !RecurrenceRuleSnapshot.sameRules(record.old.recurrenceRules, series.recurrenceRules, allDay: record.old.isAllDay) {
                mismatch.append("recurrence")
            }
        } else {
            mismatch.append("the series could not be read")
        }
        guard let exceptions = readBack.exceptions else { return mismatch + ["the occurrences could not be listed"] }
        let diff = diff(recorded: record.before, current: exceptions)
        func occurrences(_ n: Int) -> String { "\(n) occurrence\(n == 1 ? "" : "s")" }
        if !diff.added.isEmpty { mismatch.append("\(occurrences(diff.added.count)) deleted before the update came back") }
        if !diff.deleted.isEmpty { mismatch.append("\(occurrences(diff.deleted.count)) \(diff.deleted.count == 1 ? "is" : "are") missing") }
        if !diff.edited.isEmpty {
            mismatch.append("\(occurrences(diff.edited.count)) edited on \(diff.edited.count == 1 ? "its" : "their") own \(diff.edited.count == 1 ? "differs" : "differ") from before the update")
        }
        if diff.otherWindows { mismatch.append("the occurrences were listed over other dates") }
        return mismatch
    }

    /// The write happened; the read-back did not show the state before the update. Said plainly, and
    /// the record is discarded: a retry would compare with a state that is gone.
    static func readBackError(_ record: SeriesUpdateRecord, mismatch: [String]) -> UnrecoverableUndoError {
        UnrecoverableUndoError(message: "Undo wrote the previous \(list(record.fields)) to the whole recurring event '\(undoShownTitle(record.saved.title))', but reading the series back did not show it as it was before the update: \(mismatch.joined(separator: "; ")). The series may not be as it was before the update; check it in Calendar. This history entry was discarded, because running the undo again could not be checked against this state.")
    }

    static func undoneMessage(_ record: SeriesUpdateRecord) -> String {
        "Undone: restored the \(list(record.fields)) of the whole recurring event '\(undoVisibleTitle(record.old.title))' to \(record.fields.count == 1 ? "its value" : "their values") before the update; its occurrences edited or deleted on their own were checked before and after the write and are as they were before the update"
    }

    /// "title", "title and notes", "title, notes and location".
    static func list(_ fields: [String]) -> String {
        guard let last = fields.last else { return "" }
        guard fields.count > 1 else { return last }
        return fields.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// #263: the undo of a whole-series update was refused because the series is not as the update left
/// it. Nothing was written; the record is kept (`UndoFailureDisposition.of` gives `.restore`).
/// Author-controlled text: the reasons are closed, the counts are numbers, and the store-derived
/// title passes `undoShownTitle`. That is the condition under which this type conforms to
/// `TrustedErrorMessage`.
struct SeriesUpdateUndoRefusal: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

extension SeriesUpdateUndoRefusal: TrustedErrorMessage {}
