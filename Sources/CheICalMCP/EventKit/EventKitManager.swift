import CoreLocation
import EventKit
import Foundation

/// EventKit wrapper for Calendar and Reminders operations
actor EventKitManager {
    private let eventStore = EKEventStore()
    private var hasCalendarAccess = false
    private var hasReminderAccess = false
    private var needsRefresh = false

    static let shared = EventKitManager()

    private init() {}

    // MARK: - Access Request

    func requestCalendarAccess() async throws {
        if hasCalendarAccess { return }

        if #available(macOS 14.0, *) {
            let granted = try await eventStore.requestFullAccessToEvents()
            hasCalendarAccess = granted
            if !granted {
                throw EventKitError.accessDenied(type: "Calendar")
            }
        } else {
            let granted = try await eventStore.requestAccess(to: .event)
            hasCalendarAccess = granted
            if !granted {
                throw EventKitError.accessDenied(type: "Calendar")
            }
        }
    }

    func requestReminderAccess() async throws {
        if hasReminderAccess { return }

        if #available(macOS 14.0, *) {
            let granted = try await eventStore.requestFullAccessToReminders()
            hasReminderAccess = granted
            if !granted {
                throw EventKitError.accessDenied(type: "Reminders")
            }
        } else {
            let granted = try await eventStore.requestAccess(to: .reminder)
            hasReminderAccess = granted
            if !granted {
                throw EventKitError.accessDenied(type: "Reminders")
            }
        }
    }

    // MARK: - Refresh Management

    /// Refresh EventKit sources if needed (called before read operations)
    private func refreshIfNeeded() {
        if needsRefresh {
            eventStore.refreshSourcesIfNecessary()
            needsRefresh = false
        }
    }

    /// Mark that EventKit sources need to be refreshed (called after write operations)
    private func markNeedsRefresh() {
        needsRefresh = true
    }

    // MARK: - Calendars

    /// Find a calendar by name and optional source
    /// - Parameters:
    ///   - name: Calendar name
    ///   - source: Optional source name (e.g., "iCloud", "Google", "Exchange")
    ///   - entityType: Calendar type (.event or .reminder)
    /// - Returns: The matching calendar
    /// - Throws: calendarNotFound if not found, multipleCalendarsFound if ambiguous
    func findCalendar(
        name: String,
        source: String?,
        entityType: EKEntityType
    ) throws -> EKCalendar {
        let allCalendars = eventStore.calendars(for: entityType)

        // 1. Exact match (case-sensitive)
        var calendars = allCalendars.filter { cal in
            cal.title == name &&
            (source == nil || cal.source.title == source)
        }

        // 2. Case-insensitive fallback
        if calendars.isEmpty {
            let lowerName = name.lowercased()
            let lowerSource = source?.lowercased()
            calendars = allCalendars.filter { cal in
                cal.title.lowercased() == lowerName &&
                (lowerSource == nil || cal.source.title.lowercased() == lowerSource)
            }
        }

        if calendars.isEmpty {
            let available = allCalendars.map { "\($0.title) (\($0.source.title))" }
            if let source = source {
                throw EventKitError.calendarNotFoundWithSource(name: name, source: source, available: available)
            } else {
                throw EventKitError.calendarNotFound(identifier: name, available: available)
            }
        }

        if calendars.count > 1 {
            let sources = calendars.map { $0.source.title }.joined(separator: ", ")
            throw EventKitError.multipleCalendarsFound(name: name, sources: sources)
        }

        return calendars[0]
    }

    /// Find calendars by name and optional source (returns array for filtering)
    /// - Parameters:
    ///   - name: Calendar name
    ///   - source: Optional source name
    ///   - entityType: Calendar type
    /// - Returns: Array of matching calendars (may be empty)
    func findCalendars(
        name: String,
        source: String?,
        entityType: EKEntityType
    ) throws -> [EKCalendar] {
        let allCalendars = eventStore.calendars(for: entityType)

        // 1. Exact match (case-sensitive)
        var calendars = allCalendars.filter { cal in
            cal.title == name &&
            (source == nil || cal.source.title == source)
        }

        // 2. Case-insensitive fallback
        if calendars.isEmpty {
            let lowerName = name.lowercased()
            let lowerSource = source?.lowercased()
            calendars = allCalendars.filter { cal in
                cal.title.lowercased() == lowerName &&
                (lowerSource == nil || cal.source.title.lowercased() == lowerSource)
            }
        }

        if calendars.isEmpty {
            let available = allCalendars.map { "\($0.title) (\($0.source.title))" }
            if let source = source {
                throw EventKitError.calendarNotFoundWithSource(name: name, source: source, available: available)
            } else {
                throw EventKitError.calendarNotFound(identifier: name, available: available)
            }
        }

        if calendars.count > 1 && source == nil {
            let sources = calendars.map { $0.source.title }.joined(separator: ", ")
            throw EventKitError.multipleCalendarsFound(name: name, sources: sources)
        }

        return calendars
    }

    func listCalendars(for entityType: EKEntityType? = nil) async throws -> [EKCalendar] {
        if entityType == .event || entityType == nil {
            try await requestCalendarAccess()
        }
        if entityType == .reminder || entityType == nil {
            try await requestReminderAccess()
        }
        refreshIfNeeded()

        if let type = entityType {
            return eventStore.calendars(for: type)
        } else {
            let eventCalendars = eventStore.calendars(for: .event)
            let reminderCalendars = eventStore.calendars(for: .reminder)
            return eventCalendars + reminderCalendars
        }
    }

    struct CreateCalendarResult {
        let calendar: EKCalendar
        let isDuplicate: Bool
    }

    func createCalendar(title: String, entityType: EKEntityType, color: String? = nil) async throws -> CreateCalendarResult {
        if entityType == .event {
            try await requestCalendarAccess()
        } else {
            try await requestReminderAccess()
        }

        // Idempotency: check for existing calendar with same title and type
        let existing = eventStore.calendars(for: entityType).first { $0.title == title }
        if let existing = existing {
            return CreateCalendarResult(calendar: existing, isDuplicate: true)
        }

        let calendar = EKCalendar(for: entityType, eventStore: eventStore)
        calendar.title = title

        // Set source (use default source)
        if entityType == .event {
            calendar.source = eventStore.defaultCalendarForNewEvents?.source
        } else {
            calendar.source = eventStore.defaultCalendarForNewReminders()?.source
        }

        // Set color if provided
        if let colorHex = color {
            calendar.cgColor = parseColor(colorHex)
        }

        try eventStore.saveCalendar(calendar, commit: true)
        markNeedsRefresh()
        return CreateCalendarResult(calendar: calendar, isDuplicate: false)
    }

    func updateCalendar(
        identifier: String,
        title: String? = nil,
        color: String? = nil
    ) async throws -> EKCalendar {
        try await requestCalendarAccess()
        try await requestReminderAccess()

        guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
            throw EventKitError.calendarNotFound(identifier: identifier)
        }
        guard calendar.allowsContentModifications else {
            throw EventKitError.calendarNotFound(identifier: "\(calendar.title) (read-only)")
        }

        if let t = title { calendar.title = t }
        if let c = color { calendar.cgColor = parseColor(c) }

        try eventStore.saveCalendar(calendar, commit: true)
        markNeedsRefresh()
        return calendar
    }

    func deleteCalendar(identifier: String) async throws {
        try await requestCalendarAccess()
        try await requestReminderAccess()

        guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
            throw EventKitError.calendarNotFound(identifier: identifier)
        }

        try eventStore.removeCalendar(calendar, commit: true)
        markNeedsRefresh()
    }

    // MARK: - Events

    struct CreateEventResult {
        let event: EKEvent
        let isDuplicate: Bool
    }

    /// Find an existing event that matches by title and start date on the same calendar.
    /// Used for idempotency checks to prevent duplicate event creation.
    private func findDuplicateEvent(
        title: String,
        startDate: Date,
        calendar: EKCalendar
    ) -> EKEvent? {
        // Search within a 1-minute window around the start date
        let searchStart = startDate.addingTimeInterval(-30)
        let searchEnd = startDate.addingTimeInterval(30)
        let predicate = eventStore.predicateForEvents(
            withStart: searchStart,
            end: searchEnd,
            calendars: [calendar]
        )
        let events = eventStore.events(matching: predicate)
        return events.first { $0.title == title }
    }

    func listEvents(
        startDate: Date,
        endDate: Date,
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) async throws -> [EKEvent] {
        try await requestCalendarAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return eventStore.events(matching: predicate)
    }

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        location: String? = nil,
        url: String? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        isAllDay: Bool = false,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        structuredLocation: StructuredLocationInput? = nil
    ) async throws -> CreateEventResult {
        try await requestCalendarAccess()

        // Resolve calendar first (required for both duplicate check and creation)
        guard let name = calendarName else {
            throw EventKitError.calendarNameRequired(forType: "events")
        }
        let calendar = try findCalendar(name: name, source: calendarSource, entityType: .event)

        // Idempotency: check for existing event with same title + start time on same calendar
        if let existing = findDuplicateEvent(title: title, startDate: startDate, calendar: calendar) {
            return CreateEventResult(event: existing, isDuplicate: true)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.isAllDay = isAllDay
        event.calendar = calendar

        if let urlString = url, let eventURL = URL(string: urlString) {
            event.url = eventURL
        }

        // Add alarms
        if let offsets = alarmOffsets {
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                event.addAlarm(alarm)
            }
        }

        // Add recurrence rule
        if let rule = recurrenceRule {
            event.recurrenceRules = [createRecurrenceRule(from: rule)]
        }

        // Set structured location (overrides location text if both provided)
        if let loc = structuredLocation {
            let structured = EKStructuredLocation(title: loc.title)
            if let lat = loc.latitude, let lon = loc.longitude {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            if let radius = loc.radius, radius > 0 {
                structured.radius = radius
            }
            event.structuredLocation = structured
        }

        try eventStore.save(event, span: .thisEvent)
        markNeedsRefresh()
        return CreateEventResult(event: event, isDuplicate: false)
    }

    func updateEvent(
        identifier: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        notes: String? = nil,
        location: String? = nil,
        url: String? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        isAllDay: Bool? = nil,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        clearRecurrence: Bool = false,
        structuredLocation: StructuredLocationInput? = nil
    ) async throws -> EKEvent {
        try await requestCalendarAccess()

        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }

        if let t = title { event.title = t }

        // Handle time updates carefully to prevent invalid state (startDate > endDate)
        // When only startDate is provided, preserve the original duration
        if let newStart = startDate {
            let originalDuration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = newStart
            if endDate == nil {
                // Preserve original event duration when only start time changes
                event.endDate = newStart.addingTimeInterval(originalDuration)
            }
        }
        if let newEnd = endDate {
            event.endDate = newEnd
        }

        // Validate time range
        if event.startDate >= event.endDate && !event.isAllDay {
            let dateFormatter = ISO8601DateFormatter()
            let startStr = dateFormatter.string(from: event.startDate)
            let endStr = dateFormatter.string(from: event.endDate)
            throw EventKitError.invalidTimeRange(
                message: "Start time (\(startStr)) must be before end time (\(endStr)). When changing the date, provide both start_time and end_time."
            )
        }

        if let n = notes { event.notes = n }
        if let l = location { event.location = l }
        if let a = isAllDay { event.isAllDay = a }

        if let urlString = url, let eventURL = URL(string: urlString) {
            event.url = eventURL
        }

        if let name = calendarName {
            event.calendar = try findCalendar(name: name, source: calendarSource, entityType: .event)
        }

        // Update alarms
        if let offsets = alarmOffsets {
            // Remove existing alarms
            if let existingAlarms = event.alarms {
                for alarm in existingAlarms {
                    event.removeAlarm(alarm)
                }
            }
            // Add new alarms
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                event.addAlarm(alarm)
            }
        }

        // Update recurrence rule
        if clearRecurrence {
            event.recurrenceRules = nil
        } else if let rule = recurrenceRule {
            event.recurrenceRules = [createRecurrenceRule(from: rule)]
        }

        // Update structured location
        if let loc = structuredLocation {
            let structured = EKStructuredLocation(title: loc.title)
            if let lat = loc.latitude, let lon = loc.longitude {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            if let radius = loc.radius, radius > 0 {
                structured.radius = radius
            }
            event.structuredLocation = structured
        }

        try eventStore.save(event, span: .thisEvent)
        markNeedsRefresh()
        return event
    }

    func deleteEvent(identifier: String, span: EKSpan = .thisEvent) async throws {
        try await requestCalendarAccess()

        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }

        try eventStore.remove(event, span: span)
        markNeedsRefresh()
    }

    /// Get a single event by identifier
    func getEvent(identifier: String) async throws -> EKEvent {
        try await requestCalendarAccess()
        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }
        return event
    }

    // MARK: - Search and Conflict Detection

    /// Search events by keyword(s) in title, notes, or location
    /// - Parameters:
    ///   - keywords: Array of keywords to search for
    ///   - matchMode: "any" (OR) or "all" (AND)
    ///   - startDate: Optional start date for search range
    ///   - endDate: Optional end date for search range
    ///   - calendarName: Optional calendar name filter
    ///   - calendarSource: Optional calendar source filter
    func searchEvents(
        keywords: [String],
        matchMode: String = "any",
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) async throws -> [EKEvent] {
        try await requestCalendarAccess()
        refreshIfNeeded()

        // Default to a wide date range if not specified
        let searchStart = startDate ?? Date.distantPast
        let searchEnd = endDate ?? Date.distantFuture

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: calendars)
        let allEvents = eventStore.events(matching: predicate)

        // Lowercase all keywords
        let lowercasedKeywords = keywords.map { $0.lowercased() }

        return allEvents.filter { event in
            // Combine searchable text
            let searchableText = [
                event.title?.lowercased(),
                event.notes?.lowercased(),
                event.location?.lowercased()
            ].compactMap { $0 }.joined(separator: " ")

            if matchMode == "all" {
                // AND mode: all keywords must match
                return lowercasedKeywords.allSatisfy { searchableText.contains($0) }
            } else {
                // OR mode (default): any keyword matches
                return lowercasedKeywords.contains { searchableText.contains($0) }
            }
        }
    }

    /// Backward-compatible single keyword search
    func searchEvents(
        keyword: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) async throws -> [EKEvent] {
        return try await searchEvents(
            keywords: [keyword],
            matchMode: "any",
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource
        )
    }

    // MARK: - Batch Operations

    /// Delete multiple events at once
    func deleteEventsBatch(
        identifiers: [String],
        span: EKSpan = .thisEvent
    ) async throws -> BatchDeleteResult {
        try await requestCalendarAccess()

        var successCount = 0
        var failures: [(String, String)] = []

        for id in identifiers {
            do {
                guard let event = eventStore.event(withIdentifier: id) else {
                    failures.append((id, "Event not found"))
                    continue
                }
                try eventStore.remove(event, span: span)
                successCount += 1
            } catch {
                failures.append((id, error.localizedDescription))
            }
        }

        markNeedsRefresh()
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures
        )
    }

    /// Find duplicate events across calendars
    func findDuplicateEvents(
        calendarNames: [String]?,
        startDate: Date,
        endDate: Date,
        toleranceMinutes: Int = 5
    ) async throws -> [DuplicatePair] {
        try await requestCalendarAccess()
        refreshIfNeeded()

        // Get specified calendars or all
        var calendars: [EKCalendar]?
        if let names = calendarNames, !names.isEmpty {
            let allCalendars = eventStore.calendars(for: .event)
            calendars = allCalendars.filter { names.contains($0.title) }
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        var duplicates: [DuplicatePair] = []
        let tolerance = TimeInterval(toleranceMinutes * 60)

        for i in 0..<events.count {
            for j in (i + 1)..<events.count {
                let e1 = events[i]
                let e2 = events[j]

                // Skip if same calendar
                if e1.calendar.calendarIdentifier == e2.calendar.calendarIdentifier { continue }

                // Compare titles (case-insensitive)
                guard let t1 = e1.title?.lowercased(), let t2 = e2.title?.lowercased(),
                      t1 == t2 else { continue }

                // Compare times with tolerance
                let startDiff = abs(e1.startDate.timeIntervalSince(e2.startDate))
                let endDiff = abs(e1.endDate.timeIntervalSince(e2.endDate))

                if startDiff <= tolerance && endDiff <= tolerance {
                    duplicates.append(DuplicatePair(
                        event1Id: e1.eventIdentifier ?? "",
                        event1Title: e1.title ?? "",
                        event1Calendar: e1.calendar.title,
                        event1StartDate: e1.startDate,
                        event2Id: e2.eventIdentifier ?? "",
                        event2Title: e2.title ?? "",
                        event2Calendar: e2.calendar.title,
                        event2StartDate: e2.startDate,
                        timeDifferenceSeconds: Int(startDiff)
                    ))
                }
            }
        }

        return duplicates
    }

    /// Check for events that overlap with the given time range
    func checkConflicts(
        startDate: Date,
        endDate: Date,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        excludeEventId: String? = nil
    ) async throws -> [EKEvent] {
        try await requestCalendarAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        // Filter out excluded event and check for actual overlap
        return events.filter { event in
            // Exclude the specified event (useful when checking before updating)
            if let excludeId = excludeEventId, event.eventIdentifier == excludeId {
                return false
            }
            // Check for time overlap (event must actually overlap with the range)
            return event.startDate < endDate && event.endDate > startDate
        }
    }

    /// Copy an event to another calendar, optionally deleting the original
    func copyEvent(
        identifier: String,
        toCalendarName: String,
        toCalendarSource: String? = nil,
        deleteOriginal: Bool = false
    ) async throws -> EKEvent {
        try await requestCalendarAccess()

        // Find the source event
        guard let sourceEvent = eventStore.event(withIdentifier: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }

        // Find the target calendar
        let targetCalendar = try findCalendar(name: toCalendarName, source: toCalendarSource, entityType: .event)

        // Check if target calendar allows modifications
        guard targetCalendar.allowsContentModifications else {
            throw EventKitError.calendarNotFound(identifier: "\(toCalendarName) (read-only)")
        }

        // Create a new event with the same properties
        let newEvent = EKEvent(eventStore: eventStore)
        newEvent.title = sourceEvent.title
        newEvent.startDate = sourceEvent.startDate
        newEvent.endDate = sourceEvent.endDate
        newEvent.notes = sourceEvent.notes
        newEvent.location = sourceEvent.location
        newEvent.url = sourceEvent.url
        newEvent.isAllDay = sourceEvent.isAllDay
        newEvent.calendar = targetCalendar

        // Copy alarms
        if let alarms = sourceEvent.alarms {
            for alarm in alarms {
                newEvent.addAlarm(EKAlarm(relativeOffset: alarm.relativeOffset))
            }
        }

        // Save the new event
        try eventStore.save(newEvent, span: .thisEvent)

        // Optionally delete the original
        if deleteOriginal {
            try eventStore.remove(sourceEvent, span: .thisEvent)
        }

        markNeedsRefresh()
        return newEvent
    }

    // MARK: - Reminders

    func listReminders(completed: Bool? = nil, calendarName: String? = nil, calendarSource: String? = nil) async throws -> [EKReminder] {
        try await requestReminderAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .reminder)
        }

        let predicate: NSPredicate
        if let isCompleted = completed {
            if isCompleted {
                predicate = eventStore.predicateForCompletedReminders(
                    withCompletionDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            }
        } else {
            predicate = eventStore.predicateForReminders(in: calendars)
        }

        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders = reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    struct CreateReminderResult {
        let reminder: EKReminder
        let isDuplicate: Bool
    }

    /// Find an existing incomplete reminder that matches by title on the same list.
    /// Optionally also matches due date if provided.
    private func findDuplicateReminder(
        title: String,
        dueDate: Date?,
        calendar: EKCalendar
    ) async -> EKReminder? {
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: [calendar]
        )
        let reminders = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        return reminders.first { reminder in
            guard reminder.title == title else { return false }
            // If both have due dates, compare them (within 1-minute window)
            if let existingDue = reminder.dueDateComponents,
               let due = dueDate {
                let existingDate = Calendar.current.date(from: existingDue)
                if let existingDate = existingDate {
                    return abs(existingDate.timeIntervalSince(due)) < 60
                }
            }
            // If neither has a due date, it's a match by title alone
            if reminder.dueDateComponents == nil && dueDate == nil {
                return true
            }
            // One has due date, the other doesn't — not a duplicate
            return false
        }
    }

    func createReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        locationTrigger: LocationTriggerInput? = nil
    ) async throws -> CreateReminderResult {
        try await requestReminderAccess()

        // Resolve calendar first (required for both duplicate check and creation)
        guard let name = calendarName else {
            throw EventKitError.calendarNameRequired(forType: "reminders")
        }
        let calendar = try findCalendar(name: name, source: calendarSource, entityType: .reminder)

        // Idempotency: check for existing reminder with same title (+due date) on same list
        if let existing = await findDuplicateReminder(title: title, dueDate: dueDate, calendar: calendar) {
            return CreateReminderResult(reminder: existing, isDuplicate: true)
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority
        reminder.calendar = calendar

        if let due = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }

        // Add alarms
        if let offsets = alarmOffsets {
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                reminder.addAlarm(alarm)
            }
        }

        // Add recurrence rule
        if let rule = recurrenceRule {
            reminder.recurrenceRules = [createRecurrenceRule(from: rule)]
        }

        // Add location trigger
        if let trigger = locationTrigger {
            let structured = EKStructuredLocation(title: trigger.title)
            structured.geoLocation = CLLocation(latitude: trigger.latitude, longitude: trigger.longitude)
            structured.radius = trigger.radius > 0 ? trigger.radius : 100
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = trigger.proximity
            reminder.addAlarm(alarm)
        }

        try eventStore.save(reminder, commit: true)
        markNeedsRefresh()
        return CreateReminderResult(reminder: reminder, isDuplicate: false)
    }

    func updateReminder(
        identifier: String,
        title: String? = nil,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        alarmOffsets: [Int]? = nil,
        locationTrigger: LocationTriggerInput? = nil,
        clearLocationTrigger: Bool = false
    ) async throws -> EKReminder {
        try await requestReminderAccess()

        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }

        if let t = title { reminder.title = t }
        if let n = notes { reminder.notes = n }
        if let p = priority { reminder.priority = p }

        if let due = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }

        if let name = calendarName {
            let calendar = try findCalendar(name: name, source: calendarSource, entityType: .reminder)
            reminder.calendar = calendar
        }

        // Update alarms
        if let offsets = alarmOffsets {
            if let existingAlarms = reminder.alarms {
                for alarm in existingAlarms {
                    reminder.removeAlarm(alarm)
                }
            }
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                reminder.addAlarm(alarm)
            }
        }

        // Update location trigger
        if clearLocationTrigger {
            // Remove only location-based alarms
            if let existingAlarms = reminder.alarms {
                for alarm in existingAlarms where alarm.structuredLocation != nil {
                    reminder.removeAlarm(alarm)
                }
            }
        } else if let trigger = locationTrigger {
            // Remove existing location-based alarms first
            if let existingAlarms = reminder.alarms {
                for alarm in existingAlarms where alarm.structuredLocation != nil {
                    reminder.removeAlarm(alarm)
                }
            }
            let structured = EKStructuredLocation(title: trigger.title)
            structured.geoLocation = CLLocation(latitude: trigger.latitude, longitude: trigger.longitude)
            structured.radius = trigger.radius > 0 ? trigger.radius : 100
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = trigger.proximity
            reminder.addAlarm(alarm)
        }

        try eventStore.save(reminder, commit: true)
        markNeedsRefresh()
        return reminder
    }

    func completeReminder(identifier: String, completed: Bool = true) async throws -> EKReminder {
        try await requestReminderAccess()

        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }

        reminder.isCompleted = completed
        if completed {
            reminder.completionDate = Date()
        } else {
            reminder.completionDate = nil
        }

        try eventStore.save(reminder, commit: true)
        markNeedsRefresh()
        return reminder
    }

    func deleteReminder(identifier: String) async throws {
        try await requestReminderAccess()

        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }

        try eventStore.remove(reminder, commit: true)
        markNeedsRefresh()
    }

    // MARK: - Reminder Search & Batch

    /// Search reminders by keyword(s) in title or notes
    func searchReminders(
        keywords: [String],
        matchMode: String = "any",
        calendarName: String? = nil,
        calendarSource: String? = nil,
        completed: Bool? = nil
    ) async throws -> [EKReminder] {
        try await requestReminderAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .reminder)
        }

        // Build predicate based on completed filter
        let predicate: NSPredicate
        if let isCompleted = completed {
            if isCompleted {
                predicate = eventStore.predicateForCompletedReminders(
                    withCompletionDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            }
        } else {
            predicate = eventStore.predicateForReminders(in: calendars)
        }

        let allReminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // Filter by keywords in Swift layer (for proper Unicode support)
        let lowercasedKeywords = keywords.map { $0.lowercased() }

        return allReminders.filter { reminder in
            let searchableText = [
                reminder.title?.lowercased(),
                reminder.notes?.lowercased()
            ].compactMap { $0 }.joined(separator: " ")

            if matchMode == "all" {
                return lowercasedKeywords.allSatisfy { searchableText.contains($0) }
            } else {
                return lowercasedKeywords.contains { searchableText.contains($0) }
            }
        }
    }

    /// Delete multiple reminders at once
    func deleteRemindersBatch(identifiers: [String]) async throws -> BatchDeleteResult {
        try await requestReminderAccess()

        var successCount = 0
        var failures: [(String, String)] = []

        for id in identifiers {
            do {
                guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
                    failures.append((id, "Reminder not found"))
                    continue
                }
                try eventStore.remove(reminder, commit: true)
                successCount += 1
            } catch {
                failures.append((id, error.localizedDescription))
            }
        }

        markNeedsRefresh()
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures
        )
    }

    // MARK: - Helpers

    private func createRecurrenceRule(from input: RecurrenceRuleInput) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch input.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }

        var daysOfWeek: [EKRecurrenceDayOfWeek]?
        if let days = input.daysOfWeek {
            daysOfWeek = days.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }
        }

        var end: EKRecurrenceEnd?
        if let endDate = input.endDate {
            end = EKRecurrenceEnd(end: endDate)
        } else if let count = input.occurrenceCount {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: input.interval,
            daysOfTheWeek: daysOfWeek,
            daysOfTheMonth: input.daysOfMonth?.map { NSNumber(value: $0) },
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    private func parseColor(_ hex: String) -> CGColor {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Input Types

struct RecurrenceRuleInput {
    enum Frequency {
        case daily, weekly, monthly, yearly
    }

    let frequency: Frequency
    let interval: Int
    let endDate: Date?
    let occurrenceCount: Int?
    let daysOfWeek: [Int]?
    let daysOfMonth: [Int]?
}

struct StructuredLocationInput {
    let title: String
    let latitude: Double?
    let longitude: Double?
    let radius: Double?  // meters, default 100
}

struct LocationTriggerInput {
    let title: String
    let latitude: Double
    let longitude: Double
    let radius: Double    // meters, default 100
    let proximity: EKAlarmProximity  // .enter or .leave
}

// MARK: - Errors

enum EventKitError: LocalizedError {
    case accessDenied(type: String)
    case calendarNotFound(identifier: String, available: [String] = [])
    case calendarNotFoundWithSource(name: String, source: String, available: [String] = [])
    case multipleCalendarsFound(name: String, sources: String)
    case eventNotFound(identifier: String)
    case reminderNotFound(identifier: String)
    case calendarNameRequired(forType: String)
    case invalidTimeRange(message: String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let type):
            return """
            \(type) access denied. Please grant permission:
            1. Open System Settings → Privacy & Security → \(type)
            2. Enable access for the MCP server or Terminal
            3. Restart Claude Desktop/Code
            """
        case .calendarNotFound(let id, let available):
            if available.isEmpty {
                return "Calendar not found: \(id)"
            }
            return "Calendar not found: \(id). Available: \(available.joined(separator: ", "))"
        case .calendarNotFoundWithSource(let name, let source, let available):
            if available.isEmpty {
                return "Calendar '\(name)' not found in source '\(source)'"
            }
            return "Calendar '\(name)' not found in source '\(source)'. Available: \(available.joined(separator: ", "))"
        case .multipleCalendarsFound(let name, let sources):
            return """
            Multiple calendars found with name '\(name)'.
            Available sources: \(sources)
            Please specify calendar_source to disambiguate.
            """
        case .eventNotFound(let id):
            return "Event not found: \(id)"
        case .reminderNotFound(let id):
            return "Reminder not found: \(id)"
        case .calendarNameRequired(let type):
            return "calendar_name is required for creating \(type). Use list_calendars to see available options."
        case .invalidTimeRange(let message):
            return "Invalid time range: \(message)"
        }
    }
}

// MARK: - Batch Operation Results

struct BatchDeleteResult {
    let successCount: Int
    let failedCount: Int
    let failures: [(identifier: String, error: String)]
}

struct DuplicatePair {
    let event1Id: String
    let event1Title: String
    let event1Calendar: String
    let event1StartDate: Date
    let event2Id: String
    let event2Title: String
    let event2Calendar: String
    let event2StartDate: Date
    let timeDifferenceSeconds: Int
}
