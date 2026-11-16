import EventKit
import Foundation

/// #268: what `update_event` and `update_reminder` answer for the item's identifier.
///
/// A save that moves the item to a calendar or list in another account can give it a new
/// identifier (#226, device: iCloud → Google), so can a calendar of the same Google account
/// (#484, measured), and a span "future" save from a later occurrence ends the series and starts
/// a new one. The response reports the identifier after the save
/// (`id`), whether it differs from the one the call named (`id_changed`, as `move_events_batch`
/// and `copy_event` report it), and the input as `previous_id` only when it changed.
///
/// An edit of one occurrence (`occurrence_date`, span "this") saves a detached occurrence with an
/// identifier of its own (on iCloud the series id followed by /RID= and a number, device
/// 2026-11-04), which addresses only that occurrence. Which saves those are is known from the save
/// itself, not from the id's shape (PR #387 verify round 2): `id` is then the series' identifier
/// after the save, compared with the input, and the occurrence's id is `occurrence_id`.
enum UpdatedIdentifier {
    /// - Parameters:
    ///   - input: the identifier the call named.
    ///   - saved: the identifier the saved item reads back with; nil or empty keeps `input`.
    ///   - seriesIdentifier: non-nil when the saved item is one occurrence edited on its own: the
    ///     identifier of its series after the save (nil or empty keeps `input`).
    static func responseFields(input: String, saved: String?, seriesIdentifier: String? = nil) -> [String: Any] {
        if let seriesIdentifier {
            let series = seriesIdentifier.isEmpty ? input : seriesIdentifier
            var fields: [String: Any] = ["id": series, "id_changed": series != input]
            if series != input { fields["previous_id"] = input }
            if let saved, !saved.isEmpty { fields["occurrence_id"] = saved }
            return fields
        }
        guard let saved, !saved.isEmpty, saved != input else {
            return ["id": input, "id_changed": false]
        }
        return ["id": saved, "id_changed": true, "previous_id": input]
    }

    /// The series identifier of a save of one occurrence, or nil when the save was not one
    /// (`savedIsOccurrence`: the saved object is an occurrence, not the resolved series; span
    /// "future" from an occurrence starts a new series, whose own id the save reports).
    ///
    /// It never reports a stale identifier as unchanged (PR #387 verify rounds 3-4). An occurrence
    /// edit with a calendar of another account is refused before the save
    /// (`EventKitManager.refusesOccurrenceEditAcrossAccounts`), so every save here stayed in its
    /// account and the series identifier did not change.
    /// - The series object is used only when it refreshed after the save (the caller passes
    ///   `masterRefreshed: false` for the stand-in, which is an occurrence object); a /RID= part of
    ///   its id is stripped.
    /// - Otherwise the series part of the saved occurrence id (before /RID=, iCloud's shape).
    /// - Otherwise "" (keep the input).
    static func savedOccurrenceSeries(savedIsOccurrence: Bool, span: EKSpan, masterRefreshed: Bool,
                                      master: String?, occurrence: String?) -> String? {
        guard savedIsOccurrence, span == .thisEvent else { return nil }
        if masterRefreshed, let master, let series = seriesPart(of: master) { return series }
        if let occurrence, occurrence.contains(occurrenceMarker), let series = seriesPart(of: occurrence) { return series }
        return ""
    }

    /// #428: the series' identifier answered for an `update_event` span `all` that named the series
    /// and went through its first occurrence edited on its own (`saved`, the occurrence's id after
    /// the save). Its part before /RID=, or, with no /RID=, the saved id itself, as a new series may
    /// read back without one; never the input, which may resolve to nothing after a new series
    /// started (verify r1). A saved event with no identifier gives "", which `responseFields` reads
    /// as the input; a save that returned no identifier was not seen. Measured on iCloud
    /// (2026-11-08): the first left and the only one left both read back as `<new series>/RID=<n>`.
    static func seriesThroughOccurrence(saved: String?) -> String {
        guard let saved, !saved.isEmpty else { return "" }
        return seriesOfOccurrenceId(saved) ?? saved
    }

    private static let occurrenceMarker = "/RID="

    /// The series part of an id that is itself one occurrence (`<series>/RID=<n>`, iCloud's shape);
    /// nil for any other id, whose series cannot be read from it.
    static func seriesOfOccurrenceId(_ id: String) -> String? {
        guard id.contains(occurrenceMarker) else { return nil }
        return seriesPart(of: id)
    }

    /// `id` without a /RID= suffix; nil when nothing is left.
    private static func seriesPart(of id: String) -> String? {
        let series = id.range(of: occurrenceMarker).map { String(id[..<$0.lowerBound]) } ?? id
        return series.isEmpty ? nil : series
    }
}
