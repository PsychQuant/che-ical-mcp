import EventKit
import Foundation

/// #263 — the EventKit side of the whole-series update undo (`SeriesUpdateUndo`, pure): the record
/// site in `updateEvent` (a plan before the first field is assigned, the record after the save) and
/// the undo arm. `SeriesUpdateUndoWiringTests` pins the order of both.
extension EventKitManager {
    /// What the record site knows before the save of a restorable update.
    struct SeriesUpdatePlan {
        let fields: [String]
        /// The series' exceptions before the save, over the window placed now.
        let before: SeriesExceptions
    }

    /// Whether `series` is an iCloud series, from its calendar's account.
    static func isICloudSeries(_ series: EKEvent) -> Bool {
        SeriesUpdateUndo.isICloud(sourceType: series.calendar?.source?.sourceType, sourceTitle: series.calendar?.source?.title)
    }

    /// Called after every refusal of `updateEvent` and before its first field is assigned. Nil keeps
    /// the #236 marker: the shape is not restorable, or the series' exceptions cannot be listed, or
    /// the listing does not cover the whole series (a series with no end never is). Lists only when
    /// the shape is restorable.
    func seriesUpdatePlan(series: EKEvent, kind: RecurringUpdateKind?, wholeSeries: Bool, throughOwnOccurrence: Bool,
                          viaStandIn: Bool, requested: Set<String>) -> SeriesUpdatePlan? {
        guard let fields = SeriesUpdateUndo.recordable(
            kind: kind, wholeSeriesCall: wholeSeries, throughOwnOccurrence: throughOwnOccurrence, viaStandIn: viaStandIn,
            requested: requested, isICloud: Self.isICloudSeries(series),
            placeHasCoordinates: series.structuredLocation?.geoLocation != nil) else { return nil }
        guard let before = captureSeriesExceptions(of: series) else { return nil }
        guard SeriesUpdateUndo.covers(before, firstStart: series.startDate, end: seriesExceptionsStore.seriesEnd(of: series)) else {
            return nil
        }
        return SeriesUpdatePlan(fields: fields, before: before)
    }

    /// Called after the save: the record, with the series' exceptions listed again over the windows
    /// listed before the save, and the series read back as the undo reads it. Nil (the marker) when
    /// the series has no identifier, its exceptions cannot be listed now, or an occurrence edited on
    /// its own already held a value the update wrote (`editedOccurrenceHoldsWrittenValue`). The
    /// listing refreshes the store; the refresh flag is set again after it, so the next read of
    /// another call still refreshes, as after any write.
    func seriesUpdateRecord(plan: SeriesUpdatePlan, series: EKEvent, old: EventSnapshot) -> SeriesUpdateRecord? {
        refreshIfNeeded()
        defer { markNeedsRefresh() }
        guard let id = series.eventIdentifier, !id.isEmpty,
              let after = SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore, windows: plan.before.windows) else {
            return nil
        }
        let saved = postWriteSnapshot(eventID: id, saved: series)
        guard !SeriesUpdateUndo.editedOccurrenceHoldsWrittenValue(before: plan.before, old: old, saved: saved, fields: plan.fields) else {
            return nil
        }
        return SeriesUpdateRecord(id: id, externalIdentifier: series.calendarItemExternalIdentifier, old: old,
                                  saved: saved, fields: plan.fields, before: plan.before, after: after)
    }

    /// The undo of `.updateSeries`. The #236 guard first: it resolves the series by its identifier,
    /// refreshes it and compares its fields with the state the update left (its access check is the
    /// only suspension, before the comparison). From there nothing suspends: the series' identity,
    /// rule, account and exceptions are checked (`SeriesUpdateUndo.refusal`; a refusal keeps the
    /// record), the recorded fields are written back with span "all" in one save (rolled back when
    /// it throws; the record is kept), and the series is read back. A read-back that does not show
    /// the state before the update is reported as such and the record discarded; the actor excludes
    /// this server's other calls, not another process's change in between.
    func undoSeriesUpdate(_ operation: UndoOperation, _ record: SeriesUpdateRecord) async throws -> String {
        let series = try await verifiedEvent(of: operation, verb: .undo)
        let exceptions = SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore, windows: record.after.windows)
        let current = SeriesUpdateUndo.Current(
            eventIdentifier: series.eventIdentifier, externalIdentifier: series.calendarItemExternalIdentifier,
            hasRules: series.hasRecurrenceRules, isDetached: series.isDetached,
            rules: series.recurrenceRules?.map(RecurrenceRuleSnapshot.init(from:)), isICloud: Self.isICloudSeries(series),
            covered: exceptions.map {
                SeriesUpdateUndo.covers($0, firstStart: series.startDate, end: seriesExceptionsStore.seriesEnd(of: series))
            } ?? false,
            exceptions: exceptions)
        if let refusal = SeriesUpdateUndo.refusal(record, current: current) {
            throw SeriesUpdateUndo.refusalError(refusal, title: record.saved.title)
        }
        guard let calendar = series.calendar else {
            throw SeriesUpdateUndo.refusalError(.unlisted, title: record.saved.title)
        }
        record.old.applyRestoring(Set(record.fields), to: series, calendar: calendar)
        do {
            try eventStore.save(series, span: .futureEvents)
        } catch {
            series.rollback()
            throw error
        }
        markNeedsRefresh()
        refreshIfNeeded()
        // A lookup that fails is a read-back that shows nothing, reported as such; the write happened.
        let readSeries = (try? storedEvent(id: record.id)).flatMap { $0.refresh() ? $0 : nil }
        let readBack = SeriesUpdateUndo.ReadBack(
            series: readSeries.map { EventSnapshot(from: $0) },
            exceptions: SeriesExceptionsUndo.capture(of: readSeries ?? series, in: seriesExceptionsStore, windows: record.before.windows))
        let mismatch = SeriesUpdateUndo.readBackMismatch(record, readBack: readBack)
        // The read-back refreshed the store; the next read of another call refreshes again.
        markNeedsRefresh()
        guard mismatch.isEmpty else {
            throw SeriesUpdateUndo.readBackError(record, mismatch: mismatch)
        }
        return SeriesUpdateUndo.undoneMessage(record)
    }
}
