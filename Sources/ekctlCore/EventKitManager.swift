import CoreGraphics
import CoreLocation
import EventKit
import Foundation

/// EventKitManager handles all interactions with the EventKit framework.
///
/// IMPORTANT: macOS Permission Requirements
/// ----------------------------------------
/// On macOS, command-line tools require special setup to access Calendar and Reminders:
///
/// 1. The tool must be code-signed with appropriate entitlements
/// 2. An Info.plist must include privacy usage descriptions:
///    - NSCalendarsUsageDescription: Explains why calendar access is needed
///    - NSRemindersUsageDescription: Explains why reminders access is needed
///
/// 3. For development, you can embed the Info.plist:
///    - Add to Package.swift target: linkerSettings: [.unsafeFlags(["-sectcreate", "__TEXT", "__info_plist", "Info.plist"])]
///    - Or sign the binary: codesign --entitlements entitlements.plist -s - ekctl
///
/// 4. The first time the tool runs, macOS will prompt the user to grant access.
///    If denied, all operations will fail with a permission error.
///
/// 5. Users can manage permissions in: System Settings > Privacy & Security > Calendars/Reminders

/// Which EventKit stores a command touches, and therefore which TCC
/// permission prompts the user sees on first run. Commands request the
/// narrowest scope they can: a reminders-only workflow never triggers the
/// Calendar prompt, and a denied-but-unneeded permission no longer produces
/// confusing downstream "not found" errors.
public enum AccessScope {
    case events
    case reminders
    /// Requests both stores. Proceeds when at least one side is granted so a
    /// caller can explicitly implement a partial-access read workflow.
    case all

    var includesEvents: Bool { self != .reminders }
    var includesReminders: Bool { self != .events }
}

struct EventKitManagerError: LocalizedError {
    enum Classification {
        case operation
        case invalidInput
    }

    let message: String
    let classification: Classification

    init(message: String, classification: Classification = .operation) {
        self.message = message
        self.classification = classification
    }

    var errorDescription: String? { message }
}

func eventKitFailureOutput(_ error: Error) -> JSONOutput {
    if let managerError = error as? EventKitManagerError,
       managerError.classification == .invalidInput
    {
        return JSONOutput.error(
            managerError.localizedDescription,
            code: "invalid_input",
            exitCode: 64
        )
    }
    return JSONOutput.error(error.localizedDescription)
}

/// Small synchronization primitive used by completion-handler EventKit APIs.
/// Keeping callback state in a locked box avoids a late callback racing a
/// timeout path that has already returned to the caller.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

public class EventKitManager {
    /// `timeFormat` controls how `eventToDict`/`reminderToDict` render
    /// timestamps — see `TimeFormat` (issue #3).
    public init(timeFormat: TimeFormat = .rfc3339) {
        self.timeFormat = timeFormat
    }

    private let timeFormat: TimeFormat
    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var reminderAccessGranted = false

    private static let permissionWait: DispatchTimeInterval = .seconds(60)
    private static let reminderFetchWait: DispatchTimeInterval = .seconds(30)
    private static let geocodeWait: TimeInterval = 5

    /// Requests access to the EventKit stores named by `scope`.
    /// This must be called before any other EventKit operation. Denial of a
    /// *needed* permission throws `EventKitAccessError`; rendering and process
    /// status selection belong exclusively to the CLI.
    public func requestAccess(_ scope: AccessScope = .all) throws {
        var calendarError: Error?
        var reminderError: Error?

        if scope.includesEvents {
            let semaphore = DispatchSemaphore(value: 0)
            let result = LockedBox<(granted: Bool, error: Error?)?>(nil)
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { granted, error in
                    result.set((granted, error))
                    semaphore.signal()
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, error in
                    result.set((granted, error))
                    semaphore.signal()
                }
            }
            guard semaphore.wait(timeout: .now() + Self.permissionWait) == .success,
                  let accessResult = result.get()
            else {
                throw EventKitAccessError.timedOut(store: "Calendar")
            }
            calendarAccessGranted = accessResult.granted
            calendarError = accessResult.error
        }

        if scope.includesReminders {
            let semaphore = DispatchSemaphore(value: 0)
            let result = LockedBox<(granted: Bool, error: Error?)?>(nil)
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToReminders { granted, error in
                    result.set((granted, error))
                    semaphore.signal()
                }
            } else {
                eventStore.requestAccess(to: .reminder) { granted, error in
                    result.set((granted, error))
                    semaphore.signal()
                }
            }
            guard semaphore.wait(timeout: .now() + Self.permissionWait) == .success,
                  let accessResult = result.get()
            else {
                throw EventKitAccessError.timedOut(store: "Reminders")
            }
            reminderAccessGranted = accessResult.granted
            reminderError = accessResult.error
        }

        // EventKit sometimes reports a user denial as an NSError instead of
        // only returning `granted == false`. Preserve the public exit-code
        // contract by treating that case (and an already denied/restricted
        // authorization state) as permission denial, not a system failure.
        if let error = calendarError {
            if Self.isEventKitPermissionError(error)
                || Self.authorizationDeniesRequestedAccess(to: .event)
            {
                calendarAccessGranted = false
            } else {
                throw EventKitAccessError.system(
                    store: "Calendar", message: error.localizedDescription)
            }
        }
        if let error = reminderError {
            if Self.isEventKitPermissionError(error)
                || Self.authorizationDeniesRequestedAccess(to: .reminder)
            {
                reminderAccessGranted = false
            } else {
                throw EventKitAccessError.system(
                    store: "Reminders", message: error.localizedDescription)
            }
        }

        // Check the permission the requested scope actually depends on.
        let deniedStore: String?
        switch scope {
        case .events:
            deniedStore = calendarAccessGranted ? nil : "Calendar"
        case .reminders:
            deniedStore = reminderAccessGranted ? nil : "Reminders"
        case .all:
            // Mixed-store commands degrade gracefully when only one side is
            // granted, so only a full denial is fatal.
            deniedStore = (calendarAccessGranted || reminderAccessGranted)
                ? nil : "Calendar and Reminders"
        }
        if let deniedStore {
            throw EventKitAccessError.denied(store: deniedStore)
        }
    }

    static func isEventKitPermissionError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == EKErrorDomain
            && cocoaError.code == EKError.Code.eventStoreNotAuthorized.rawValue
    }

    private static func authorizationDeniesRequestedAccess(
        to entityType: EKEntityType
    ) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if status == .denied || status == .restricted { return true }
        if #available(macOS 14.0, *), status == .writeOnly { return true }
        return false
    }

    // MARK: - Calendar Operations

    /// Lists EventKit sources so callers can make an explicit account choice
    /// before creating an event calendar.
    public func listSources() -> JSONOutput {
        let sources = eventStore.sources.map { source -> [String: Any] in
            [
                "id": source.sourceIdentifier,
                "title": source.title,
                "type": sourceTypeString(source.sourceType),
                "eventCalendarCount": source.calendars(for: .event).count,
            ]
        }
        return JSONOutput.success(["sources": sources, "count": sources.count])
    }

    /// Creates a new event calendar in exactly the source selected by the
    /// caller. There is intentionally no iCloud/local/first-source fallback.
    public func createCalendar(
        sourceID: String,
        title: String,
        color: String?,
        dryRun: Bool = false
    ) -> JSONOutput {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return JSONOutput.error("Calendar title must not be empty.")
        }
        guard let source = eventStore.sources.first(where: { $0.sourceIdentifier == sourceID }) else {
            return JSONOutput.error("Calendar source not found with ID: \(sourceID)")
        }

        let parsedColor: CGColor?
        do {
            parsedColor = try validatedColor(color)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Calendar creation validated; no calendar was saved.",
                "calendar": [
                    "id": NSNull(),
                    "title": title,
                    "type": "event",
                    "source": ["id": source.sourceIdentifier, "title": source.title],
                    "color": parsedColor?.hexString ?? "#000000",
                ],
            ])
        }

        let newCalendar = EKCalendar(for: .event, eventStore: eventStore)
        newCalendar.title = title
        newCalendar.source = source
        if let parsedColor { newCalendar.cgColor = parsedColor }

        do {
            try eventStore.saveCalendar(newCalendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Calendar created successfully",
                "calendar": calendarToDict(newCalendar, type: "event"),
                "id": newCalendar.calendarIdentifier,
            ])
        } catch {
            return JSONOutput.error("Failed to create calendar: \(error.localizedDescription)")
        }
    }

    /// Updates an event-only calendar. Mixed event/reminder containers are
    /// rejected because deleting or changing one can affect both stores.
    public func updateCalendar(
        calendarID: String,
        title: String?,
        color: String?,
        dryRun: Bool = false
    ) -> JSONOutput {
        let calendar: EKCalendar
        do {
            calendar = try eventOnlyCalendar(withIdentifier: calendarID)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }
        guard !calendar.isImmutable else {
            return JSONOutput.error("Calendar '\(calendar.title)' is immutable.")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return JSONOutput.error("Calendar title must not be empty.")
        }

        let parsedColor: CGColor?
        do {
            parsedColor = try validatedColor(color)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }

        var changes: [String: Any] = [:]
        if let title { changes["title"] = ["before": calendar.title, "after": title] }
        if let parsedColor {
            changes["color"] = [
                "before": calendar.cgColor?.hexString ?? "#000000",
                "after": parsedColor.hexString,
            ]
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Calendar update validated; no calendar was saved.",
                "calendar": calendarToDict(calendar, type: "event"),
                "changes": changes,
            ])
        }

        if let title { calendar.title = title }
        if let parsedColor { calendar.cgColor = parsedColor }

        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Calendar updated successfully",
                "calendar": calendarToDict(calendar, type: "event"),
            ])
        } catch {
            return JSONOutput.error("Failed to update calendar: \(error.localizedDescription)")
        }
    }

    /// Deletes an event-only calendar.
    public func deleteCalendar(calendarID: String, dryRun: Bool = false) -> JSONOutput {
        let calendar: EKCalendar
        do {
            calendar = try eventOnlyCalendar(withIdentifier: calendarID)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }
        guard !calendar.isImmutable else {
            return JSONOutput.error("Calendar '\(calendar.title)' is immutable.")
        }

        let snapshot = calendarToDict(calendar, type: "event")
        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Calendar deletion validated; no calendar was removed.",
                "calendar": snapshot,
            ])
        }

        do {
            try eventStore.removeCalendar(calendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Calendar deleted successfully",
                "deletedCalendar": snapshot,
            ])
        } catch {
            return JSONOutput.error("Failed to delete calendar: \(error.localizedDescription)")
        }
    }

    /// Lists event calendars only. Reminder lists have a separate method and
    /// therefore never require Calendar callers to request Reminders access.
    public func listCalendars() -> JSONOutput {
        let calendars = eventStore.calendars(for: .event).map {
            calendarToDict($0, type: "event")
        }
        return JSONOutput.success(["calendars": calendars, "count": calendars.count])
    }

    /// Lists reminder lists only.
    public func listReminderLists() -> JSONOutput {
        let lists = eventStore.calendars(for: .reminder).map {
            calendarToDict($0, type: "reminder")
        }
        return JSONOutput.success(["reminderLists": lists, "count": lists.count])
    }

    // MARK: - Event Operations

    /// Lists events in a calendar within a date range
    public func listEvents(
        calendarIDs: [String],
        from startDate: Date,
        to endDate: Date,
        search: String? = nil,
        availability: AvailabilityFilter? = nil,
        sortedByStartAscending: Bool = false,
        limit: Int? = nil
    ) -> JSONOutput {
        guard startDate < endDate else {
            return JSONOutput.error("Event query start date must be earlier than end date.")
        }
        guard DateRanges.isSupportedEventQuery(start: startDate, end: endDate) else {
            return JSONOutput.error(
                "Event query ranges must not exceed \(DateRanges.maximumNextWindowDays) days.")
        }

        let availableCalendars = Dictionary(
            uniqueKeysWithValues: eventStore.calendars(for: .event).map {
                ($0.calendarIdentifier, $0)
            })
        var calendars: [EKCalendar] = []
        for id in calendarIDs {
            guard let calendar = availableCalendars[id] else {
                return JSONOutput.error("Event calendar not found with ID: \(id)")
            }
            calendars.append(calendar)
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        var filtered = eventStore.events(matching: predicate).filter { event in
            EventFilter.matchesSearch(search, in: [event.title, event.location, event.notes])
            && EventFilter.matchesAvailability(
                availability,
                eventAvailability: Self.availabilityString(event.availability))
        }
        if sortedByStartAscending {
            filtered.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        }
        if let limit = limit, filtered.count > limit {
            filtered = Array(filtered.prefix(limit))
        }
        let eventDicts = filtered.map { eventToDict($0) }

        return JSONOutput.success(["events": eventDicts, "count": eventDicts.count])
    }

    /// Convenience overload that accepts a single calendar ID.
    public func listEvents(calendarID: String, from startDate: Date, to endDate: Date) -> JSONOutput {
        return listEvents(calendarIDs: [calendarID], from: startDate, to: endDate)
    }

    /// Single source of truth for mapping EKEventAvailability to its public string
    /// form. Used by both `eventToDict` (for output) and `listEvents` (for filtering
    /// against `AvailabilityFilter`) so the two paths can't drift apart.
    static func availabilityString(_ a: EKEventAvailability) -> String {
        switch a {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        case .notSupported: return "notSupported"
        @unknown default: return "unknown"
        }
    }

    /// Shows one concrete event. A recurring event must be accompanied by an
    /// exact occurrence selector; an identifier alone would return its first
    /// occurrence and is therefore rejected.
    public func showEvent(
        eventID: String,
        selector: EventOccurrenceSelector? = nil
    ) -> JSONOutput {
        do {
            let event = try resolveEvent(eventID: eventID, selector: selector)
            return JSONOutput.success(["event": eventToDict(event)])
        } catch {
            return eventKitFailureOutput(error)
        }
    }

    /// Updates an existing calendar event
    public func updateEvent(
        eventID: String,
        selector: EventOccurrenceSelector? = nil,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        location: String?,
        notes: String?,
        allDay: Bool?,
        url: String?,
        availability: AvailabilitySetting?,
        alarms: [Double]?,
        geocodeLocation: Bool = false,
        dryRun: Bool = false
    ) -> JSONOutput {
        let event: EKEvent
        do {
            event = try resolveEvent(eventID: eventID, selector: selector)
        } catch {
            return eventKitFailureOutput(error)
        }

        guard event.calendar?.allowsContentModifications == true else {
            return JSONOutput.error("Event calendar does not allow modifications.")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return JSONOutput.error("Event title must not be empty.")
        }
        if geocodeLocation && (location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            return JSONOutput.error("--geocode-location requires a non-empty location.")
        }
        if let alarms, alarms.contains(where: { !$0.isFinite }) {
            return JSONOutput.error("Alarm offsets must be finite numbers.")
        }

        let proposedStart = startDate ?? event.startDate
        let proposedEnd = endDate ?? event.endDate
        let proposedAllDay = allDay ?? event.isAllDay
        do {
            try validateEventDates(
                start: proposedStart,
                end: proposedEnd,
                allDay: proposedAllDay,
                requireAllDayBoundaries: startDate != nil || endDate != nil || allDay != nil)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }

        let parsedURL: URL?
        if let url {
            guard let value = URL(string: url), value.scheme != nil else {
                return JSONOutput.error("Event URL must be an absolute URL.")
            }
            parsedURL = value
        } else {
            parsedURL = nil
        }

        var changes: [String: Any] = [:]
        if let title { changes["title"] = ["before": event.title ?? "", "after": title] }
        if let startDate {
            changes["startDate"] = [
                "before": jsonValue(event.startDate.map {
                    formatEventDate($0, allDay: event.isAllDay)
                }),
                "after": formatEventDate(startDate, allDay: proposedAllDay),
            ]
        }
        if let endDate {
            changes["endDate"] = [
                "before": jsonValue(event.endDate.map {
                    formatEventDate($0, allDay: event.isAllDay)
                }),
                "after": formatEventDate(endDate, allDay: proposedAllDay),
            ]
        }
        if let location {
            changes["location"] = ["before": jsonValue(event.location), "after": location]
            changes["structuredLocation"] = [
                "beforePresent": event.structuredLocation != nil,
                "afterIntent": geocodeLocation ? "replace-with-geocoded-location" : "clear",
                "message": geocodeLocation
                    ? "The existing structured location will be replaced only if opt-in geocoding succeeds."
                    : "The existing structured location, if any, will be cleared.",
            ]
        }
        if let notes { changes["notes"] = ["before": jsonValue(event.notes), "after": notes] }
        if let allDay { changes["allDay"] = ["before": event.isAllDay, "after": allDay] }
        if let url {
            changes["url"] = ["before": jsonValue(event.url?.absoluteString), "after": url]
        }
        if let availability {
            changes["availability"] = [
                "before": Self.availabilityString(event.availability),
                "after": Self.availabilityString(availability.ekAvailability),
            ]
        }
        if let alarms {
            changes["alarms"] = alarmReplacementPreview(
                existing: event.alarms ?? [],
                replacementOffsets: alarms)
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Event update validated; no event was saved.",
                "event": eventToDict(event),
                "changes": changes,
                "geocodingWouldRun": geocodeLocation,
            ])
        }

        // Geocoding is the only network-capable preparation step. Complete it
        // before changing the EventKit object so failure cannot leave a dirty
        // object waiting to be committed by later work.
        var resolvedStructuredLocation: EKStructuredLocation?
        if geocodeLocation, let location {
            do {
                resolvedStructuredLocation = try resolveLocation(location)
            } catch {
                return JSONOutput.error(error.localizedDescription)
            }
        }

        if let title = title { event.title = title }
        if let startDate = startDate { event.startDate = startDate }
        if let endDate = endDate { event.endDate = endDate }
        if let location = location {
            event.location = location
            event.structuredLocation = geocodeLocation ? resolvedStructuredLocation : nil
        }
        if let notes = notes { event.notes = notes }
        if let allDay = allDay { event.isAllDay = allDay }

        if let parsedURL { event.url = parsedURL }

        if let availability = availability {
            event.availability = availability.ekAvailability
        }

        if let alarms = alarms {
            if let existing = event.alarms {
                for alarm in existing { event.removeAlarm(alarm) }
            }
            for offset in alarms {
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Event updated successfully",
                "event": eventToDict(event),
            ])
        } catch {
            return JSONOutput.error("Failed to update event: \(error.localizedDescription)")
        }
    }

    /// Creates a new calendar event
    public func addEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        allDay: Bool,
        recurrenceFrequency: String? = nil,
        recurrenceInterval: Int = 1,
        recurrenceEndCount: Int? = nil,
        recurrenceEndDate: Date? = nil,
        recurrenceDays: String? = nil,
        recurrenceMonths: [NSNumber]? = nil,
        recurrenceDaysOfMonth: [NSNumber]? = nil,
        recurrenceWeeksOfYear: [NSNumber]? = nil,
        recurrenceDaysOfYear: [NSNumber]? = nil,
        recurrenceSetPositions: [NSNumber]? = nil,
        alarms: [Double]? = nil,
        url: String? = nil,
        availability: AvailabilitySetting? = nil,
        geocodeLocation: Bool = false,
        dryRun: Bool = false
    ) -> JSONOutput {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return JSONOutput.error("Event title must not be empty.")
        }
        do {
            try validateEventDates(
                start: startDate,
                end: endDate,
                allDay: allDay,
                requireAllDayBoundaries: allDay)
            try validateRecurrenceArguments(
                frequency: recurrenceFrequency,
                interval: recurrenceInterval,
                endCount: recurrenceEndCount,
                endDate: recurrenceEndDate,
                eventStart: startDate,
                days: recurrenceDays,
                months: recurrenceMonths,
                daysOfMonth: recurrenceDaysOfMonth,
                weeksOfYear: recurrenceWeeksOfYear,
                daysOfYear: recurrenceDaysOfYear,
                setPositions: recurrenceSetPositions)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }
        if let alarms, alarms.contains(where: { !$0.isFinite }) {
            return JSONOutput.error("Alarm offsets must be finite numbers.")
        }
        if geocodeLocation && (location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            return JSONOutput.error("--geocode-location requires a non-empty location.")
        }

        let parsedURL: URL?
        if let url {
            guard let value = URL(string: url), value.scheme != nil else {
                return JSONOutput.error("Event URL must be an absolute URL.")
            }
            parsedURL = value
        } else {
            parsedURL = nil
        }

        let calendar: EKCalendar
        do {
            calendar = try eventCalendar(withIdentifier: calendarID)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications.")
        }

        var resolvedStructuredLocation: EKStructuredLocation?
        if !dryRun, geocodeLocation, let location {
            do {
                resolvedStructuredLocation = try resolveLocation(location)
            } catch {
                return JSONOutput.error(error.localizedDescription)
            }
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        // Location handling will be done below
        event.notes = notes
        event.isAllDay = allDay

        if let parsedURL { event.url = parsedURL }

        if let availability = availability {
            event.availability = availability.ekAvailability
        }

        if let alarms = alarms {
            for offset in alarms {
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }
        }

        // Location & Structured Location
        if let locationString = location {
            event.location = locationString
            if geocodeLocation, !dryRun {
                event.structuredLocation = resolvedStructuredLocation
            }
        }

        // Recurrence Support
        if let freqString = recurrenceFrequency?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !freqString.isEmpty
        {
            var frequency: EKRecurrenceFrequency
            switch freqString {
            case "daily": frequency = .daily
            case "weekly": frequency = .weekly
            case "monthly": frequency = .monthly
            case "yearly": frequency = .yearly
            default: return JSONOutput.error("Invalid recurrence frequency: \(freqString)")
            }

            var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
            if let daysStr = recurrenceDays {
                var days: [EKRecurrenceDayOfWeek] = []
                let dayMap: [String: EKWeekday] = [
                    "mon": .monday, "monday": .monday,
                    "tue": .tuesday, "tuesday": .tuesday,
                    "wed": .wednesday, "wednesday": .wednesday,
                    "thu": .thursday, "thursday": .thursday,
                    "fri": .friday, "friday": .friday,
                    "sat": .saturday, "saturday": .saturday,
                    "sun": .sunday, "sunday": .sunday,
                ]

                // Parse strings like "mon", "1mon", "-1fri"
                for dayPart in daysStr.split(separator: ",") {
                    var part = dayPart.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    var weekNumber = 0

                    // Extract leading number if present
                    if let range = part.range(of: "^-?\\d+", options: .regularExpression) {
                        if let num = Int(part[range]) {
                            weekNumber = num
                            part.removeSubrange(range)
                        }
                    }

                    if let weekday = dayMap[part] {
                        if weekNumber != 0 {
                            days.append(EKRecurrenceDayOfWeek(weekday, weekNumber: weekNumber))
                        } else {
                            days.append(EKRecurrenceDayOfWeek(weekday))
                        }
                    } else {
                        return JSONOutput.error("Invalid recurrence day: \(dayPart)")
                    }
                }
                daysOfTheWeek = days.isEmpty ? nil : days
            }

            var recurrenceEnd: EKRecurrenceEnd?
            if let count = recurrenceEndCount {
                recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
            } else if let recEndDate = recurrenceEndDate {
                recurrenceEnd = EKRecurrenceEnd(end: recEndDate)
            }

            let rule = EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: recurrenceInterval,
                daysOfTheWeek: daysOfTheWeek,
                daysOfTheMonth: recurrenceDaysOfMonth,
                monthsOfTheYear: recurrenceMonths,
                weeksOfTheYear: recurrenceWeeksOfYear,
                daysOfTheYear: recurrenceDaysOfYear,
                setPositions: recurrenceSetPositions,
                end: recurrenceEnd
            )
            event.addRecurrenceRule(rule)
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Event creation validated; no event was saved.",
                "event": eventToDict(event),
                "geocodingWouldRun": geocodeLocation,
            ])
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Event created successfully",
                "event": eventToDict(event),
            ])
        } catch {
            return JSONOutput.error("Failed to create event: \(error.localizedDescription)")
        }
    }

    /// Deletes a calendar event
    public func deleteEvent(
        eventID: String,
        selector: EventOccurrenceSelector? = nil,
        dryRun: Bool = false
    ) -> JSONOutput {
        let event: EKEvent
        do {
            event = try resolveEvent(eventID: eventID, selector: selector)
        } catch {
            return eventKitFailureOutput(error)
        }
        guard event.calendar?.allowsContentModifications == true else {
            return JSONOutput.error("Event calendar does not allow modifications.")
        }

        let title = event.title ?? "Untitled"
        let snapshot = eventToDict(event)

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Event deletion validated; no event was removed.",
                "event": snapshot,
            ])
        }

        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Event '\(title)' deleted successfully",
                "deletedEventID": eventID,
                "deletedEvent": snapshot,
            ])
        } catch {
            return JSONOutput.error("Failed to delete event: \(error.localizedDescription)")
        }
    }

    // MARK: - Reminder Operations

    /// Lists reminders in a reminder list
    public func listReminders(listID: String, completed: Bool?, search: String? = nil) -> JSONOutput {
        let calendar: EKCalendar
        do {
            calendar = try reminderList(withIdentifier: listID)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }

        let predicate = eventStore.predicateForReminders(in: [calendar])
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<[EKReminder]?>(nil)

        let fetchIdentifier = eventStore.fetchReminders(matching: predicate) { fetchedReminders in
            result.set(fetchedReminders)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.reminderFetchWait) == .success else {
            eventStore.cancelFetchRequest(fetchIdentifier)
            return JSONOutput.error("Timed out fetching reminders.")
        }
        guard var reminders = result.get() else {
            return JSONOutput.error("EventKit returned no reminder results.")
        }

        if let completed = completed {
            reminders = reminders.filter { $0.isCompleted == completed }
        }
        reminders = reminders.filter { reminder in
            EventFilter.matchesSearch(search, in: [reminder.title, reminder.notes])
        }

        let reminderDicts = reminders.map { reminderToDict($0) }

        return JSONOutput.success(["reminders": reminderDicts, "count": reminderDicts.count])
    }

    /// Shows details of a specific reminder
    public func showReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        return JSONOutput.success(["reminder": reminderToDict(reminder)])
    }

    /// Creates a new reminder
    public func addReminder(
        listID: String,
        title: String,
        dueDate: Date?,
        priority: Int,
        notes: String?,
        dryRun: Bool = false
    ) -> JSONOutput {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return JSONOutput.error("Reminder title must not be empty.")
        }
        guard (0...9).contains(priority) else {
            return JSONOutput.error("Reminder priority must be between 0 and 9.")
        }

        let calendar: EKCalendar
        do {
            calendar = try reminderList(withIdentifier: listID)
        } catch {
            return JSONOutput.error(error.localizedDescription)
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error(
                "Reminder list '\(calendar.title)' does not allow modifications.")
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.priority = priority
        reminder.notes = notes

        if let dueDate = dueDate {
            reminder.dueDateComponents = Self.reminderDueComponents(from: dueDate)
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Reminder creation validated; no reminder was saved.",
                "reminder": reminderToDict(reminder),
            ])
        }

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Reminder created successfully",
                "reminder": reminderToDict(reminder),
            ])
        } catch {
            return JSONOutput.error("Failed to create reminder: \(error.localizedDescription)")
        }
    }

    /// Updates an existing reminder
    public func updateReminder(
        reminderID: String,
        title: String?,
        dueDate: Date?,
        priority: Int?,
        notes: String?,
        completed: Bool?,
        dryRun: Bool = false
    ) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }
        guard reminder.calendar?.allowsContentModifications == true else {
            return JSONOutput.error("Reminder list does not allow modifications.")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return JSONOutput.error("Reminder title must not be empty.")
        }
        if let priority, !(0...9).contains(priority) {
            return JSONOutput.error("Reminder priority must be between 0 and 9.")
        }

        var changes: [String: Any] = [:]
        if let title { changes["title"] = ["before": reminder.title ?? "", "after": title] }
        if let notes { changes["notes"] = ["before": reminder.notes ?? "", "after": notes] }
        if let priority { changes["priority"] = ["before": reminder.priority, "after": priority] }
        if let completed { changes["completed"] = ["before": reminder.isCompleted, "after": completed] }
        if let dueDate {
            changes["dueDate"] = [
                "before": reminderDueDate(reminder).map { localDateFormatter.string(from: $0) } ?? "",
                "after": localDateFormatter.string(from: dueDate),
            ]
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Reminder update validated; no reminder was saved.",
                "reminder": reminderToDict(reminder),
                "changes": changes,
            ])
        }

        if let title = title { reminder.title = title }
        if let notes = notes { reminder.notes = notes }
        if let priority = priority { reminder.priority = priority }
        if let completed = completed {
            if completed && !reminder.isCompleted {
                reminder.isCompleted = true
                reminder.completionDate = Date()
            } else if !completed && reminder.isCompleted {
                reminder.isCompleted = false
                reminder.completionDate = nil
            }
        }
        if let dueDate = dueDate {
            reminder.dueDateComponents = Self.reminderDueComponents(from: dueDate)
        }

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Reminder updated successfully",
                "reminder": reminderToDict(reminder),
            ])
        } catch {
            return JSONOutput.error("Failed to update reminder: \(error.localizedDescription)")
        }
    }

    /// Marks a reminder as completed
    public func completeReminder(reminderID: String, dryRun: Bool = false) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }
        guard reminder.calendar?.allowsContentModifications == true else {
            return JSONOutput.error("Reminder list does not allow modifications.")
        }

        if reminder.isCompleted {
            return JSONOutput.success([
                "status": "success",
                "dryRun": dryRun,
                "applied": false,
                "alreadyCompleted": true,
                "message": "Reminder is already completed; completion date was preserved.",
                "reminder": reminderToDict(reminder),
            ])
        }

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Reminder completion validated; no reminder was saved.",
                "reminder": reminderToDict(reminder),
                "changes": ["completed": ["before": false, "after": true]],
            ])
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Reminder '\(reminder.title ?? "Untitled")' marked as completed",
                "reminder": reminderToDict(reminder),
            ])
        } catch {
            return JSONOutput.error("Failed to complete reminder: \(error.localizedDescription)")
        }
    }

    /// Deletes a reminder
    public func deleteReminder(reminderID: String, dryRun: Bool = false) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }
        guard reminder.calendar?.allowsContentModifications == true else {
            return JSONOutput.error("Reminder list does not allow modifications.")
        }

        let title = reminder.title ?? "Untitled"
        let snapshot = reminderToDict(reminder)

        if dryRun {
            return JSONOutput.success([
                "status": "success",
                "dryRun": true,
                "applied": false,
                "message": "Reminder deletion validated; no reminder was removed.",
                "reminder": snapshot,
            ])
        }

        do {
            try eventStore.remove(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "dryRun": false,
                "applied": true,
                "message": "Reminder '\(title)' deleted successfully",
                "deletedReminderID": reminderID,
                "deletedReminder": snapshot,
            ])
        } catch {
            return JSONOutput.error("Failed to delete reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    private func eventCalendar(withIdentifier id: String) throws -> EKCalendar {
        guard let calendar = eventStore.calendars(for: .event).first(where: {
            $0.calendarIdentifier == id
        }) else {
            throw EventKitManagerError(message: "Event calendar not found with ID: \(id)")
        }
        return calendar
    }

    private func eventOnlyCalendar(withIdentifier id: String) throws -> EKCalendar {
        let calendar = try eventCalendar(withIdentifier: id)
        guard calendar.allowedEntityTypes == .event else {
            throw EventKitManagerError(
                message: "Calendar '\(calendar.title)' is not event-only; mixed event/reminder containers are unsupported.")
        }
        return calendar
    }

    private func reminderList(withIdentifier id: String) throws -> EKCalendar {
        guard let calendar = eventStore.calendars(for: .reminder).first(where: {
            $0.calendarIdentifier == id
        }) else {
            throw EventKitManagerError(message: "Reminder list not found with ID: \(id)")
        }
        return calendar
    }

    /// Resolves a concrete recurring occurrence without ever using the first
    /// occurrence returned by `event(withIdentifier:)` as a mutation target.
    private func resolveEvent(
        eventID: String,
        selector: EventOccurrenceSelector?
    ) throws -> EKEvent {
        guard let anchor = eventStore.event(withIdentifier: eventID) else {
            throw EventKitManagerError(message: "Event not found with ID: \(eventID)")
        }

        let isRecurring = anchor.hasRecurrenceRules || anchor.occurrenceDate != nil
        guard isRecurring else {
            guard selector == nil else {
                throw EventKitManagerError(
                    message: "Occurrence selector was provided for a non-recurring event.",
                    classification: .invalidInput)
            }
            return anchor
        }

        guard let selector else {
            throw EventKitManagerError(
                message: "Recurring event requires both occurrenceDate and expectedStart.",
                classification: .invalidInput)
        }
        guard let calendar = anchor.calendar else {
            throw EventKitManagerError(message: "Recurring event has no calendar.")
        }

        // Query at the observed current start so moved/detached occurrences are
        // materialized. The original occurrence date then identifies the exact
        // member of the series.
        let predicate = eventStore.predicateForEvents(
            withStart: selector.expectedStart.addingTimeInterval(-1),
            end: selector.expectedStart.addingTimeInterval(1),
            calendars: [calendar]
        )
        let matches = eventStore.events(matching: predicate).filter { candidate in
            candidate.eventIdentifier == eventID
                && candidate.calendar?.calendarIdentifier == calendar.calendarIdentifier
                && datesMatchAtOutputPrecision(candidate.occurrenceDate, selector.occurrenceDate)
                && datesMatchAtOutputPrecision(candidate.startDate, selector.expectedStart)
        }

        guard matches.count == 1, let occurrence = matches.first else {
            if matches.isEmpty {
                throw EventKitManagerError(
                    message: "Recurring occurrence was not found at the supplied occurrenceDate and expectedStart; re-list the event before retrying.")
            }
            throw EventKitManagerError(
                message: "Recurring occurrence selector is ambiguous (\(matches.count) matches); no event was selected.")
        }
        return occurrence
    }

    /// Event timestamps are emitted to whole-second precision. Match selector
    /// input at that same precision so a value copied from JSON round-trips.
    private func datesMatchAtOutputPrecision(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return Int64(lhs.timeIntervalSince1970.rounded(.down))
            == Int64(rhs.timeIntervalSince1970.rounded(.down))
    }

    private func validateEventDates(
        start: Date?,
        end: Date?,
        allDay: Bool,
        requireAllDayBoundaries: Bool
    ) throws {
        guard let start, let end else {
            throw EventKitManagerError(message: "Event start and end dates are required.")
        }
        guard start < end else {
            throw EventKitManagerError(message: "Event start date must be earlier than end date.")
        }

        if allDay && requireAllDayBoundaries {
            let calendar = Calendar.current
            let startBoundary = calendar.startOfDay(for: start)
            let endBoundary = calendar.startOfDay(for: end)
            guard abs(start.timeIntervalSince(startBoundary)) < 0.001,
                  abs(end.timeIntervalSince(endBoundary)) < 0.001
            else {
                throw EventKitManagerError(
                    message: "All-day event start and end must be date-only local-day boundaries.")
            }
        }
    }

    private func validateRecurrenceArguments(
        frequency: String?,
        interval: Int,
        endCount: Int?,
        endDate: Date?,
        eventStart: Date,
        days: String?,
        months: [NSNumber]?,
        daysOfMonth: [NSNumber]?,
        weeksOfYear: [NSNumber]?,
        daysOfYear: [NSNumber]?,
        setPositions: [NSNumber]?
    ) throws {
        let normalizedFrequency = frequency?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasFrequency = normalizedFrequency?.isEmpty == false
        let hasDetails = days != nil || months != nil || daysOfMonth != nil
            || weeksOfYear != nil || daysOfYear != nil || setPositions != nil
            || endCount != nil || endDate != nil || interval != 1

        guard hasFrequency || !hasDetails else {
            throw EventKitManagerError(
                message: "Recurrence detail options require a recurrence frequency.")
        }
        guard hasFrequency else { return }
        guard ["daily", "weekly", "monthly", "yearly"].contains(normalizedFrequency!) else {
            throw EventKitManagerError(
                message: "Invalid recurrence frequency: \(normalizedFrequency!)")
        }
        guard interval > 0 else {
            throw EventKitManagerError(message: "Recurrence interval must be positive.")
        }
        if let endCount, endCount <= 0 {
            throw EventKitManagerError(message: "Recurrence end count must be positive.")
        }
        if let endDate, endDate < eventStart {
            throw EventKitManagerError(
                message: "Recurrence end date must not precede the event start.")
        }
        if endCount != nil && endDate != nil {
            throw EventKitManagerError(
                message: "Recurrence end count and end date are mutually exclusive.")
        }

        let hasDays = days?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSetInput = hasDays || daysOfMonth != nil || months != nil
            || weeksOfYear != nil || daysOfYear != nil

        if normalizedFrequency == "daily", hasDays {
            throw EventKitManagerError(
                message: "Recurrence days are not valid for a daily recurrence.")
        }
        if normalizedFrequency != "monthly", daysOfMonth != nil {
            throw EventKitManagerError(
                message: "Recurrence days of month require a monthly recurrence.")
        }
        if normalizedFrequency != "yearly",
           months != nil || weeksOfYear != nil || daysOfYear != nil
        {
            throw EventKitManagerError(
                message: "Recurrence months, weeks of year, and days of year require a yearly recurrence.")
        }
        if setPositions != nil && !hasSetInput {
            throw EventKitManagerError(
                message: "Recurrence set positions require at least one day, month, week, or year-day selector.")
        }

        try validateNumbers(
            months, named: "recurrence months", absoluteRange: 1...12, allowsNegative: false)
        try validateNumbers(daysOfMonth, named: "recurrence days of month", absoluteRange: 1...31)
        try validateNumbers(weeksOfYear, named: "recurrence weeks of year", absoluteRange: 1...53)
        try validateNumbers(daysOfYear, named: "recurrence days of year", absoluteRange: 1...366)
        try validateNumbers(setPositions, named: "recurrence set positions", absoluteRange: 1...366)

        if let days {
            let rawDays = days.split(separator: ",", omittingEmptySubsequences: false)
            guard !rawDays.isEmpty,
                  rawDays.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw EventKitManagerError(message: "Recurrence days must not be empty.")
            }
            for rawDay in rawDays {
                var value = rawDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var weekNumber = 0
                var includedWeekNumber = false
                if let range = value.range(of: "^-?\\d+", options: .regularExpression) {
                    guard let number = Int(value[range]) else {
                        throw EventKitManagerError(message: "Invalid recurrence day: \(rawDay)")
                    }
                    weekNumber = number
                    includedWeekNumber = true
                    value.removeSubrange(range)
                }
                guard ["mon", "monday", "tue", "tuesday", "wed", "wednesday",
                       "thu", "thursday", "fri", "friday", "sat", "saturday",
                       "sun", "sunday"].contains(value)
                else {
                    throw EventKitManagerError(message: "Invalid recurrence day: \(rawDay)")
                }
                guard !includedWeekNumber || weekNumber != 0 else {
                    throw EventKitManagerError(
                        message: "A recurrence day week number cannot be zero.")
                }
                guard (-53...53).contains(weekNumber) else {
                    throw EventKitManagerError(
                        message: "Recurrence day week number must be between -53 and 53.")
                }
                if normalizedFrequency == "weekly" && weekNumber != 0 {
                    throw EventKitManagerError(
                        message: "Weekly recurrence days cannot include a week number.")
                }
                if normalizedFrequency == "monthly" && !(-5...5).contains(weekNumber) {
                    throw EventKitManagerError(
                        message: "Monthly recurrence day week numbers must be between -5 and 5, excluding zero.")
                }
            }
        }
    }

    private func validateNumbers(
        _ values: [NSNumber]?,
        named name: String,
        absoluteRange: ClosedRange<Int>,
        allowsNegative: Bool = true
    ) throws {
        guard let values else { return }
        guard !values.isEmpty else {
            throw EventKitManagerError(message: "\(name.capitalized) must not be empty.")
        }
        for value in values {
            let double = value.doubleValue
            let integer = value.intValue
            guard double.isFinite, double == Double(integer), integer != 0,
                  Self.isValidSignedSelector(
                    integer,
                    absoluteRange: absoluteRange,
                    allowsNegative: allowsNegative)
            else {
                throw EventKitManagerError(
                    message: "Invalid \(name) value: \(value).")
            }
        }
    }

    /// Range checking without `abs(Int.min)`, which traps instead of returning
    /// a value. Kept internal so the public manager's defensive validation can
    /// be regression-tested independently of a live EventKit store.
    static func isValidSignedSelector(
        _ value: Int,
        absoluteRange: ClosedRange<Int>,
        allowsNegative: Bool
    ) -> Bool {
        if absoluteRange.contains(value) { return true }
        guard allowsNegative else { return false }
        let negativeRange = (-absoluteRange.upperBound)...(-absoluteRange.lowerBound)
        return negativeRange.contains(value)
    }

    private func validatedColor(_ color: String?) throws -> CGColor? {
        guard let color else { return nil }
        guard color.range(of: "^#?[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let parsed = CGColor.fromHex(color)
        else {
            throw EventKitManagerError(
                message: "Calendar color must be exactly six hexadecimal digits (for example, #FF0000).")
        }
        return parsed
    }

    private func calendarToDict(_ calendar: EKCalendar, type: String) -> [String: Any] {
        [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "type": type,
            "source": [
                "id": calendar.source?.sourceIdentifier ?? "",
                "title": calendar.source?.title ?? "Unknown",
                "type": calendar.source.map { sourceTypeString($0.sourceType) } ?? "unknown",
            ],
            "color": calendar.cgColor?.hexString ?? "#000000",
            "allowsModifications": calendar.allowsContentModifications,
            "immutable": calendar.isImmutable,
            "allowedEntityTypes": calendar.allowedEntityTypes.rawValue,
        ]
    }

    private func sourceTypeString(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    private enum GeocodeResult {
        case success(CLLocation)
        case failure(String)
    }

    /// Resolves a string address only after the caller has explicitly opted in.
    /// Timeout cancels the underlying request, and every failure occurs before
    /// an EventKit save is attempted.
    private func resolveLocation(_ address: String) throws -> EKStructuredLocation {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<GeocodeResult?>(nil)
        let geocoder = CLGeocoder()

        geocoder.geocodeAddressString(address) { placemarks, error in
            if let location = placemarks?.first?.location {
                result.set(.success(location))
            } else {
                result.set(.failure(error?.localizedDescription ?? "No matching location was found."))
            }
            semaphore.signal()
        }

        let deadline = Date(timeIntervalSinceNow: Self.geocodeWait)
        while semaphore.wait(timeout: .now()) == .timedOut {
            if Date() >= deadline {
                geocoder.cancelGeocode()
                throw EventKitManagerError(
                    message: "Geocoding timed out after \(Int(Self.geocodeWait)) seconds; no event was saved.")
            }
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.05)))
        }

        switch result.get() {
        case .success(let location):
            let structured = EKStructuredLocation(title: address)
            structured.geoLocation = location
            structured.radius = 0
            return structured
        case .failure(let message):
            throw EventKitManagerError(
                message: "Geocoding failed: \(message); no event was saved.")
        case nil:
            throw EventKitManagerError(
                message: "Geocoding completed without a result; no event was saved.")
        }
    }

    private func relativeAlarmOffsets(_ event: EKEvent) -> [Double] {
        (event.alarms ?? []).compactMap { alarm in
            alarm.absoluteDate == nil ? alarm.relativeOffset : nil
        }
    }

    func alarmToDict(_ alarm: EKAlarm) -> [String: Any] {
        var result: [String: Any]
        if let absoluteDate = alarm.absoluteDate {
            result = [
                "type": "absolute",
                "date": localDateFormatter.string(from: absoluteDate),
            ]
        } else {
            result = [
                "type": "relative",
                "offsetSeconds": alarm.relativeOffset,
            ]
        }

        result["actionType"] = alarmTypeString(alarm.type)
        result["proximity"] = alarmProximityString(alarm.proximity)
        result["hasStructuredLocation"] = alarm.structuredLocation != nil
        result["hasEmailActionMetadata"] = alarm.emailAddress != nil
        result["hasSoundActionMetadata"] = alarm.soundName != nil
        return result
    }

    /// EventKit does not offer an in-place "set relative offsets" operation:
    /// ekctl removes every existing alarm object and creates new relative
    /// alarms. Keep this preview deliberately explicit because an existing
    /// absolute alarm or custom action/geofence carries more information than
    /// its relative trigger alone.
    func alarmReplacementPreview(
        existing: [EKAlarm],
        replacementOffsets: [Double]
    ) -> [String: Any] {
        [
            "before": existing.map(alarmToDict),
            "after": replacementOffsets.map {
                alarmToDict(EKAlarm(relativeOffset: $0))
            },
            "replacesAllExistingAlarmObjects": true,
            "existingAlarmCount": existing.count,
            "replacementAlarmCount": replacementOffsets.count,
            "message": "All existing alarm objects and their action, sound/email/procedure, proximity, and structured-location metadata will be removed before the listed relative alarms are created.",
        ]
    }

    private func alarmTypeString(_ type: EKAlarmType) -> String {
        switch type {
        case .display: return "display"
        case .audio: return "audio"
        case .procedure: return "procedure"
        case .email: return "email"
        @unknown default: return "unknown"
        }
    }

    private func alarmProximityString(_ proximity: EKAlarmProximity) -> String {
        switch proximity {
        case .none: return "none"
        case .enter: return "enter"
        case .leave: return "leave"
        @unknown default: return "unknown"
        }
    }

    private func recurrenceRuleToDict(
        _ rule: EKRecurrenceRule,
        allDay: Bool
    ) -> [String: Any] {
        let daysOfWeek: [[String: Any]] = (rule.daysOfTheWeek ?? []).map { day in
            [
                "day": weekdayString(day.dayOfTheWeek),
                "weekNumber": day.weekNumber,
            ]
        }

        var result: [String: Any] = [
            "frequency": recurrenceFrequencyString(rule.frequency),
            "interval": rule.interval,
            "firstDayOfWeek": rule.firstDayOfTheWeek,
            "daysOfWeek": daysOfWeek,
            "daysOfMonth": (rule.daysOfTheMonth ?? []).map(\.intValue),
            "monthsOfYear": (rule.monthsOfTheYear ?? []).map(\.intValue),
            "weeksOfYear": (rule.weeksOfTheYear ?? []).map(\.intValue),
            "daysOfYear": (rule.daysOfTheYear ?? []).map(\.intValue),
            "setPositions": (rule.setPositions ?? []).map(\.intValue),
        ]

        if let recurrenceEnd = rule.recurrenceEnd {
            if recurrenceEnd.occurrenceCount > 0 {
                result["end"] = [
                    "type": "count",
                    "occurrenceCount": recurrenceEnd.occurrenceCount,
                ]
            } else if let endDate = recurrenceEnd.endDate {
                result["end"] = [
                    "type": "date",
                    "endDate": formatEventDate(endDate, allDay: allDay),
                ]
            } else {
                result["end"] = NSNull()
            }
        } else {
            result["end"] = NSNull()
        }

        return result
    }

    private func recurrenceFrequencyString(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }

    private func weekdayString(_ weekday: EKWeekday) -> String {
        switch weekday {
        case .sunday: return "sunday"
        case .monday: return "monday"
        case .tuesday: return "tuesday"
        case .wednesday: return "wednesday"
        case .thursday: return "thursday"
        case .friday: return "friday"
        case .saturday: return "saturday"
        @unknown default: return "unknown"
        }
    }

    private func jsonValue<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private func reminderDueDate(_ reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return Self.date(fromReminderDueComponents: components)
    }

    /// EventKit requires reminder due components to carry a Gregorian
    /// calendar. Using Calendar.current can silently encode another era/year
    /// when the user's system calendar is non-Gregorian.
    static func reminderDueComponents(
        from date: Date,
        timeZone: TimeZone = .current
    ) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.calendar = calendar
        components.timeZone = timeZone
        return components
    }

    /// Prefer EventKit's embedded calendar when reading existing data. Legacy
    /// components without one are interpreted as Gregorian, matching the API
    /// contract and the components produced above.
    static func date(fromReminderDueComponents components: DateComponents) -> Date? {
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        if let timeZone = components.timeZone {
            calendar.timeZone = timeZone
        }
        return calendar.date(from: components)
    }

    /// Date formatter for all timestamp output — ISO 8601 in the user's local
    /// timezone. Built once per manager (not per item): DateFormatter
    /// construction is comparatively expensive and `listEvents` renders a
    /// timestamp pair for every event returned.
    private lazy var localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale forces 24-hour `HH` to actually mean 24-hour, regardless of the
        // user's "Use 24-hour time" system preference (Apple QA1480). Without this, PM
        // times silently render as 12-hour without an AM/PM marker on locales like en_GB
        // — e.g. 16:00 becomes "4:00" (see issue #8).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat.dateFormatPattern  // ISO 8601 with timezone offset
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// All-day values are a civil-date contract. Emitting a timestamp would
    /// falsely attach an offset to EventKit's floating date and can move the
    /// displayed day when another process parses it in a different zone.
    private lazy var dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private func formatEventDate(_ date: Date, allDay: Bool) -> String {
        (allDay ? dateOnlyFormatter : localDateFormatter).string(from: date)
    }

    /// Converts an EKEvent to a dictionary for JSON output
    private func eventToDict(_ event: EKEvent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "calendar": [
                "id": event.calendar?.calendarIdentifier ?? "",
                "title": event.calendar?.title ?? "",
            ],
            "allDay": event.isAllDay,
        ]

        if let startDate = event.startDate {
            dict["startDate"] = formatEventDate(startDate, allDay: event.isAllDay)
        }
        if let endDate = event.endDate {
            dict["endDate"] = formatEventDate(endDate, allDay: event.isAllDay)
        }
        if let location = event.location, !location.isEmpty {
            dict["location"] = location
        } else {
            dict["location"] = NSNull()
        }
        if let notes = event.notes, !notes.isEmpty {
            dict["notes"] = notes
        } else {
            dict["notes"] = NSNull()
        }
        if let url = event.url {
            dict["url"] = url.absoluteString
        }

        dict["hasAlarms"] = event.hasAlarms
        dict["hasRecurrenceRules"] = event.hasRecurrenceRules
        dict["relativeAlarmOffsetsSeconds"] = relativeAlarmOffsets(event)
        dict["alarms"] = (event.alarms ?? []).map(alarmToDict)
        dict["recurrenceRules"] = (event.recurrenceRules ?? []).map {
            recurrenceRuleToDict($0, allDay: event.isAllDay)
        }

        if event.hasRecurrenceRules || event.occurrenceDate != nil,
           let occurrenceDate = event.occurrenceDate,
           let expectedStart = event.startDate
        {
            dict["selector"] = occurrenceSelectorToDict(
                occurrenceDate: occurrenceDate,
                expectedStart: expectedStart,
                allDay: event.isAllDay)
        } else {
            dict["selector"] = NSNull()
        }
        dict["detached"] = event.isDetached

        dict["availability"] = Self.availabilityString(event.availability)

        if let attendees = event.attendees, !attendees.isEmpty {
            dict["attendees"] = attendees.map { participant -> [String: Any] in
                var entry: [String: Any] = [
                    "name": participant.name ?? "",
                    "status": participantStatusString(participant.participantStatus),
                    "role": participantRoleString(participant.participantRole),
                ]
                // EKParticipant email is encoded in the URL as mailto:
                let url = participant.url
                if url.scheme == "mailto" {
                    entry["email"] = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                }
                return entry
            }
        } else {
            dict["attendees"] = [] as [[String: Any]]
        }

        return dict
    }

    /// The occurrence date is the original recurring slot and is independent
    /// of a detached occurrence's current all-day state. Always retain its
    /// timestamp so a timed occurrence moved to an all-day date remains
    /// exactly targetable. The expected current start follows normal all-day
    /// output rules.
    func occurrenceSelectorToDict(
        occurrenceDate: Date,
        expectedStart: Date,
        allDay: Bool
    ) -> [String: String] {
        [
            "occurrenceDate": localDateFormatter.string(from: occurrenceDate),
            "expectedStart": formatEventDate(expectedStart, allDay: allDay),
        ]
    }

    /// Converts an EKReminder to a dictionary for JSON output
    private func reminderToDict(_ reminder: EKReminder) -> [String: Any] {
        let formatter = localDateFormatter

        var dict: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": [
                "id": reminder.calendar?.calendarIdentifier ?? "",
                "title": reminder.calendar?.title ?? "",
            ],
            "completed": reminder.isCompleted,
            "priority": reminder.priority,
        ]

        if let dueDateComponents = reminder.dueDateComponents,
            let dueDate = Self.date(fromReminderDueComponents: dueDateComponents)
        {
            dict["dueDate"] = formatter.string(from: dueDate)
        } else {
            dict["dueDate"] = NSNull()
        }

        if let completionDate = reminder.completionDate {
            dict["completionDate"] = formatter.string(from: completionDate)
        }

        if let notes = reminder.notes, !notes.isEmpty {
            dict["notes"] = notes
        } else {
            dict["notes"] = NSNull()
        }

        if let url = reminder.url {
            dict["url"] = url.absoluteString
        }

        return dict
    }
}

// MARK: - AvailabilitySetting → EventKit

extension AvailabilitySetting {
    /// The EKEventAvailability value this CLI setting assigns. Lives here
    /// (not Filters.swift) so the CLI-string enum stays EventKit-free.
    public var ekAvailability: EKEventAvailability {
        switch self {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        }
    }
}

// MARK: - EKParticipant Helpers

private func participantStatusString(_ status: EKParticipantStatus) -> String {
    switch status {
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .pending: return "pending"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "inProcess"
    default: return "unknown"
    }
}

private func participantRoleString(_ role: EKParticipantRole) -> String {
    switch role {
    case .required: return "required"
    case .optional: return "optional"
    case .chair: return "chair"
    case .nonParticipant: return "nonParticipant"
    default: return "unknown"
    }
}

// MARK: - CGColor Extension for Hex String

extension CGColor {
    public var hexString: String {
        guard let components = components, components.count >= 3 else {
            return "#000000"
        }

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public static func fromHex(_ hex: String) -> CGColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
