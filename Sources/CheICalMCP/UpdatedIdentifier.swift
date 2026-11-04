import Foundation

/// #268: what `update_event` and `update_reminder` answer for the item's identifier.
///
/// A save that moves the item to a calendar or list in another account can give it a new
/// identifier (#226, device: iCloud → Google). The response reports the identifier after the save
/// (`id`), whether it differs from the one the call named (`id_changed`, as `move_events_batch`
/// and `copy_event` report it), and the input as `previous_id` only when it changed.
enum UpdatedIdentifier {
    /// - Parameters:
    ///   - input: the identifier the call named.
    ///   - saved: the identifier the saved item reads back with; nil or empty keeps `input`.
    static func responseFields(input: String, saved: String?) -> [String: Any] {
        guard let saved, !saved.isEmpty, saved != input else {
            return ["id": input, "id_changed": false]
        }
        return ["id": saved, "id_changed": true, "previous_id": input]
    }
}
