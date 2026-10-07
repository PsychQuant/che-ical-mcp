import EventKit

extension EventSnapshot {
    /// #245 — the availability `apply` writes, or nil to leave the event's: nothing was recorded
    /// (`.notSupported`), the calendar does not support the value (the calendar default is kept
    /// rather than failing the restore), or the event already has it. Pure, because an in-memory
    /// EKEvent ignores `availability`; the write itself was checked on device.
    static func availabilityToWrite(recorded: EKEventAvailability, supported: EKCalendarEventAvailabilityMask,
                                    current: EKEventAvailability) -> EKEventAvailability? {
        guard recorded != current, let mask = mask(of: recorded), supported.contains(mask) else { return nil }
        return recorded
    }

    private static func mask(of availability: EKEventAvailability) -> EKCalendarEventAvailabilityMask? {
        switch availability {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        case .notSupported: return nil
        @unknown default: return nil
        }
    }
}
