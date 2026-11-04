import Foundation

/// #268: what `update_event` and `update_reminder` answer for the item's identifier.
///
/// A save that moves the item to a calendar or list in another account can give it a new
/// identifier (#226, device: iCloud → Google). The response reports the identifier after the save
/// (`id`), whether it differs from the one the call named (`id_changed`, as `move_events_batch`
/// and `copy_event` report it), and the input as `previous_id` only when it changed.
///
/// An edit of one occurrence (`occurrence_date`, span "this") saves a detached occurrence, which
/// reads back as `<series>/RID=<seconds>` (device, iCloud, 2026-11-04). That id addresses only the
/// occurrence, while the series keeps its identifier, so it is not a change of `id`: the response
/// keeps the input and gives the occurrence's id as `occurrence_id` (PR #387 verify round 1).
enum UpdatedIdentifier {
    /// - Parameters:
    ///   - input: the identifier the call named.
    ///   - saved: the identifier the saved item reads back with; nil or empty keeps `input`.
    static func responseFields(input: String, saved: String?) -> [String: Any] {
        guard let saved, !saved.isEmpty, saved != input else {
            return ["id": input, "id_changed": false]
        }
        if saved.hasPrefix(input + occurrenceMarker) {
            return ["id": input, "id_changed": false, "occurrence_id": saved]
        }
        return ["id": saved, "id_changed": true, "previous_id": input]
    }

    /// What EventKit appends to a series' identifier for an occurrence edited on its own.
    static let occurrenceMarker = "/RID="
}
