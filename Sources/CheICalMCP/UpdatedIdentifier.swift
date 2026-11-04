import EventKit
import Foundation

/// #268: what `update_event` and `update_reminder` answer for the item's identifier.
///
/// A save that moves the item to a calendar or list in another account can give it a new
/// identifier (#226, device: iCloud → Google), and a span "future" save from a later occurrence
/// ends the series and starts a new one. The response reports the identifier after the save
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
    /// - Parameters:
    ///   - master: the resolved series object's identifier, read after the save.
    ///   - occurrence: the saved occurrence's identifier. Fallback only when `master` is nil or
    ///     empty: its part before /RID= (iCloud's shape); nil when it has no such part.
    static func savedOccurrenceSeries(savedIsOccurrence: Bool, span: EKSpan,
                                      master: String?, occurrence: String?) -> String? {
        guard savedIsOccurrence, span == .thisEvent else { return nil }
        if let master, !master.isEmpty { return master }
        guard let occurrence, let marker = occurrence.range(of: "/RID=") else { return nil }
        return String(occurrence[..<marker.lowerBound])
    }
}
