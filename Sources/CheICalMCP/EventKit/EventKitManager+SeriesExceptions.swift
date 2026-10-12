import EventKit
import Foundation

/// #285 — the EventKit side of recording and restoring a series' exceptions. The decisions are
/// `SeriesExceptionsPlanner` and `SeriesExceptionsRestorer` (pure, tested); this is the thin layer
/// that lists occurrences and writes, verified on device.
extension EventKitManager {
    /// The exceptions of `series`, read before a whole-series delete removes anything: the
    /// occurrences that exist over the series' scan window, split into those that stay and those
    /// edited on their own. Nil when they cannot be listed (no identifier or calendar), so the
    /// record says so instead of claiming there were none.
    func captureSeriesExceptions(of series: EKEvent) -> SeriesExceptions? {
        guard let id = series.eventIdentifier, !id.isEmpty, let calendar = series.calendar else { return nil }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: series.calendarItemExternalIdentifier)
        let window = UndoPostState.seriesScanWindow(of: series)
        var observed: [SeriesExceptionsPlanner.ObservedOccurrence] = []
        // Listed over a wider range than the window: an occurrence edited on its own is matched by
        // its current time, so one moved out of the window is only found there (PR #318 verify B1).
        let range = SeriesExceptionsPlanner.listingRange(for: window)
        eventStore.enumerateEvents(matching: eventStore.predicateForEvents(withStart: range.start, end: range.end,
                                                                           calendars: [calendar])) { occurrence, _ in
            observed.append(Self.observed(occurrence))
        }
        return SeriesExceptionsPlanner.capture(observed, of: seriesIDs, window: window)
    }

    private static func observed(_ occurrence: EKEvent) -> SeriesExceptionsPlanner.ObservedOccurrence {
        SeriesExceptionsPlanner.ObservedOccurrence(
            ids: .init(eventIdentifier: occurrence.eventIdentifier, externalIdentifier: occurrence.calendarItemExternalIdentifier),
            isDetached: occurrence.isDetached, occurrenceDate: occurrence.occurrenceDate, startDate: occurrence.startDate,
            snapshot: EventSnapshot(from: occurrence, includeRecurrence: false))
    }

    /// Undo of a whole-series delete that recorded `exceptions`, after `restored` was saved from
    /// the rules: removes the occurrences the original series did not have (deleted on their own
    /// before the delete) and recreates each occurrence edited on its own as a one-off event.
    /// All or nothing: a failure deletes `restored` and the one-off events again.
    func restoreSeriesExceptions(_ exceptions: SeriesExceptions, of restored: EKEvent) throws -> SeriesExceptionsRestorer.Outcome {
        guard let id = restored.eventIdentifier, !id.isEmpty, let calendar = restored.calendar else {
            try rollbackRestoredSeries(restored, exclusionsApplied: 0)
            throw EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not restore the exceptions of the recreated series (it has no identifier). The series was deleted again; nothing was restored. Retry undo.")
        }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: restored.calendarItemExternalIdentifier)
        var generated: [(slot: Date, occurrence: EKEvent)] = []
        eventStore.enumerateEvents(matching: eventStore.predicateForEvents(withStart: exceptions.window.start, end: exceptions.window.end,
                                                                           calendars: [calendar])) { occurrence, _ in
            let ids = UndoPostState.OccurrenceIDs(eventIdentifier: occurrence.eventIdentifier,
                                                  externalIdentifier: occurrence.calendarItemExternalIdentifier)
            if UndoPostState.isOccurrence(ids, of: seriesIDs) {
                generated.append((occurrence.occurrenceDate ?? occurrence.startDate, occurrence))
            }
        }
        do {
            return try SeriesExceptionsRestorer.restore(
                exceptions: exceptions, generated: generated,
                remove: { try self.eventStore.remove($0, span: .thisEvent) },
                createOneOff: { detached in
                    let oneOff = EKEvent(eventStore: self.eventStore)
                    do { return try self.saveOneOff(oneOff, from: detached.snapshot) } catch {
                        throw SeriesExceptionsOneOffWriteFailed(possiblyWritten: oneOff)
                    }
                },
                removeOneOff: { oneOff in
                    // A save that threw may or may not have written: remove only what the store holds.
                    guard let id = oneOff.eventIdentifier, self.storedEvent(id: id) != nil else { return }
                    try self.eventStore.remove(oneOff, span: .thisEvent)
                },
                rollbackSeries: { try self.eventStore.remove(restored, span: .futureEvents) })
        } catch let error as SeriesExceptionsRestoreError {
            markNeedsRefresh()
            throw Self.restoreFailure(error)
        }
    }

    private func rollbackRestoredSeries(_ restored: EKEvent, exclusionsApplied: Int) throws {
        do { try eventStore.remove(restored, span: .futureEvents); markNeedsRefresh() } catch {
            throw Self.restoreFailure(.rollbackFailed(exclusionsApplied: exclusionsApplied))
        }
    }

    /// Rolled back → a plain error (the record is put back for a retry). The compensating delete
    /// failing is permanent: a retry would create a second series, so the record is discarded.
    private static func restoreFailure(_ error: SeriesExceptionsRestoreError) -> Error {
        func day(_ date: Date) -> String { EventKitManager.formatExclusionDay(date, timezone: nil) }
        switch error {
        case .surplusUnresolved(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not restore the exceptions of the series: no occurrence of the recreated series on \(day(date)). The series was deleted again; nothing was restored. Retry undo.")
        case .removeFailed(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not remove the occurrence on \(day(date)) that the deleted series did not have. The recreated series was deleted again; nothing was restored. Retry undo.")
        case .oneOffFailed(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not recreate the occurrence edited on its own on \(day(date)). The recreated series and the occurrences recreated so far were deleted again; nothing was restored. Retry undo.")
        case .rollbackFailed(let applied):
            return UnrecoverableUndoError(
                message: "Undo recreated the series but could not finish restoring its exceptions, and deleting it again failed too: the series exists with \(applied) occurrence(s) removed, and any occurrences edited on their own that were recreated before the failure remain. Check Calendar; this undo entry is discarded because a retry would create a second series.")
        }
    }

    /// Whether the calendar of `snapshot` already holds an occurrence of a recurring series with its
    /// title at its start (`OccurrenceSlotGuard`). The store is refreshed first when this server
    /// wrote since the last refresh, so the series an earlier undo just recreated is seen.
    func seriesHoldsSlot(of snapshot: EventSnapshot) throws -> Bool {
        let calendar = try snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier })
        refreshIfNeeded()
        let end = max(snapshot.endDate, snapshot.startDate.addingTimeInterval(60))
        var holders: [OccurrenceSlotGuard.Holder] = []
        eventStore.enumerateEvents(matching: eventStore.predicateForEvents(withStart: snapshot.startDate, end: end,
                                                                           calendars: [calendar])) { event, _ in
            holders.append(.init(title: event.title, startDate: event.startDate, hasRecurrenceRules: event.hasRecurrenceRules))
        }
        return OccurrenceSlotGuard.isHeld(title: snapshot.title, start: snapshot.startDate, by: holders)
    }
}
