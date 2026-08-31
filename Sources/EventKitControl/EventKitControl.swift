import ArgumentParser
import Darwin
import EventKit
import Foundation
import EventKitControlCore

// MARK: - Shared command safety

private let invalidInputExit: Int32 = 64

private func writeStderr(_ value: String) {
    guard let data = (value + "\n").data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: data)
}

/// The only path used to render operation results. Failures go to stderr and
/// terminate with the status embedded in their structured payload.
private func emit(_ result: JSONOutput, format: OutputFormat) throws {
    let rendered = result.format(format)
    if result.isError {
        writeStderr(rendered)
        throw ExitCode(rawValue: result.exitStatus)
    }
    print(rendered)
}

private func invalid(_ message: String, format: OutputFormat) throws -> Never {
    try emit(
        .error(message, code: "invalid_input", exitCode: invalidInputExit),
        format: format)
    fatalError("emit(error:) always throws")
}

private func operationFailed(_ message: String, format: OutputFormat) throws -> Never {
    try emit(.error(message), format: format)
    fatalError("emit(error:) always throws")
}

private func configFailed(
    _ error: Error,
    context: String,
    format: OutputFormat
) throws -> Never {
    if let configError = error as? ConfigStoreError {
        switch configError {
        case .invalidAliasName, .invalidAliasID, .invalidCalendarList:
            try invalid(configError.localizedDescription, format: format)
        default:
            break
        }
    }
    try operationFailed("\(context): \(error.localizedDescription)", format: format)
}

private func requestAccess(
    _ manager: EventKitManager,
    _ scope: AccessScope,
    format: OutputFormat
) throws {
    do {
        try manager.requestAccess(scope)
    } catch let error as EventKitAccessError {
        try emit(
            .error(
                error.localizedDescription,
                code: error.errorCode,
                exitCode: error.exitStatus),
            format: format)
    } catch {
        try operationFailed("EventKit access failed: \(error.localizedDescription)", format: format)
    }
}

private func parseTimestamp(_ value: String, flag: String, format: OutputFormat) throws -> Date {
    guard let date = DateParsing.parse(value) else {
        try invalid("Invalid \(flag). Use \(DateParsing.acceptedFormats).", format: format)
    }
    return date
}

private func parseLocalDay(_ value: String, flag: String, format: OutputFormat) throws -> Date {
    guard let day = DateParsing.parseLocalDay(value),
          let date = day.date(in: .current)
    else {
        try invalid("Invalid \(flag). All-day values must use \(DateParsing.allDayFormat).", format: format)
    }
    return date
}

private func parseEventDate(
    _ value: String,
    flag: String,
    allDay: Bool,
    format: OutputFormat
) throws -> Date {
    if allDay { return try parseLocalDay(value, flag: flag, format: format) }
    return try parseTimestamp(value, flag: flag, format: format)
}

private func parseSelectorDate(
    _ value: String,
    flag: String,
    format: OutputFormat
) throws -> Date {
    if let day = DateParsing.parseLocalDay(value), let date = day.date(in: .current) {
        return date
    }
    return try parseTimestamp(value, flag: flag, format: format)
}

private func parseAlarms(_ value: String?, format: OutputFormat) throws -> [Double]? {
    guard let value else { return nil }
    do {
        return try AlarmParsing.parseRequired(value)
    } catch {
        try invalid("Invalid --alarms: \(error.localizedDescription)", format: format)
    }
}

private func parsePriority(
    _ value: String?,
    default defaultValue: Int? = nil,
    format: OutputFormat
) throws -> Int? {
    guard let value else { return defaultValue }
    do {
        return try InputValidation.parsePriority(value)
    } catch {
        try invalid("Invalid --priority: \(error.localizedDescription)", format: format)
    }
}

private func validateColor(_ value: String?, format: OutputFormat) throws {
    guard let value else { return }
    do {
        _ = try InputValidation.validateHexColor(value)
    } catch {
        try invalid("Invalid --color: \(error.localizedDescription)", format: format)
    }
}

private func validateIdentifier(
    _ value: String,
    flag: String,
    format: OutputFormat
) throws {
    do {
        _ = try InputValidation.validateIdentifier(value)
    } catch {
        try invalid("Invalid \(flag): \(error.localizedDescription)", format: format)
    }
}

private func validateIdentifiers(
    _ values: [String],
    flag: String,
    format: OutputFormat
) throws {
    for value in values {
        try validateIdentifier(value, flag: flag, format: format)
    }
}

private func validateURL(_ value: String?, format: OutputFormat) throws {
    guard let value else { return }
    guard let components = URLComponents(string: value),
          let scheme = components.scheme,
          !scheme.isEmpty,
          value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          value.rangeOfCharacter(from: .controlCharacters) == nil,
          (!["http", "https"].contains(scheme.lowercased()) || components.host?.isEmpty == false)
    else {
        try invalid("Invalid --url. Supply an absolute URL with a scheme.", format: format)
    }
}

private func validateEventRange(
    start: Date,
    end: Date,
    allDay: Bool,
    format: OutputFormat
) throws {
    guard end > start else {
        try invalid("--end must be later than --start.", format: format)
    }
    if allDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard calendar.component(.hour, from: start) == 0,
              calendar.component(.minute, from: start) == 0,
              calendar.component(.hour, from: end) == 0,
              calendar.component(.minute, from: end) == 0
        else {
            try invalid("All-day boundaries must be local calendar days.", format: format)
        }
    }
}

private func requestedOutputFormat(
    arguments: [String] = Array(CommandLine.arguments.dropFirst())
) -> OutputFormat {
    var selected: OutputFormat = .json
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--format", index + 1 < arguments.count,
           let value = OutputFormat(rawValue: arguments[index + 1])
        {
            selected = value
            index += 2
            continue
        }
        if argument.hasPrefix("--format="),
           let value = OutputFormat(rawValue: String(argument.dropFirst("--format=".count)))
        {
            selected = value
        }
        index += 1
    }
    return selected
}

struct MutationOptions: ParsableArguments {
    @Flag(name: .long, help: "Validate and preview the operation without writing anything.")
    var dryRun = false
}

struct OccurrenceOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Recurring item's original occurrence date (strict timestamp or local YYYY-MM-DD)."
    )
    var occurrence: String?

    @Option(
        name: .long,
        help: "Occurrence's current expected start (strict timestamp or local YYYY-MM-DD)."
    )
    var expectedStart: String?

    func selector(format: OutputFormat) throws -> EventOccurrenceSelector? {
        switch (occurrence, expectedStart) {
        case (nil, nil):
            return nil
        case let (.some(occurrence), .some(expectedStart)):
            return EventOccurrenceSelector(
                occurrenceDate: try parseSelectorDate(
                    occurrence, flag: "--occurrence", format: format),
                expectedStart: try parseSelectorDate(
                    expectedStart, flag: "--expected-start", format: format))
        default:
            try invalid(
                "--occurrence and --expected-start must be supplied together.",
                format: format)
        }
    }
}

// MARK: - Main command

@main
struct EventKitControl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eventkitcontrol",
        abstract: "Safely manage macOS Calendar events and Reminders using EventKit.",
        version: "1.0.1",
        subcommands: [
            List.self, Show.self, Add.self, Update.self, Delete.self, Complete.self,
            Alias.self, CalendarCmd.self, Today.self, Tomorrow.self, Next.self,
        ],
        defaultSubcommand: List.self
    )

    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch let code as ExitCode {
            Darwin.exit(code.rawValue)
        } catch {
            let code = exitCode(for: error)
            if code.isSuccess {
                exit(withError: error)
            }
            let invalidInput = code == .validationFailure
            let status: Int32 = invalidInput ? invalidInputExit : 1
            let output = JSONOutput.error(
                message(for: error),
                code: invalidInput ? "invalid_input" : "operation_failed",
                exitCode: status)
            writeStderr(output.format(requestedOutputFormat()))
            Darwin.exit(status)
        }
    }
}

// MARK: - List commands

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List EventKit objects.",
        subcommands: [
            ListCalendars.self, ListReminderLists.self, ListSources.self,
            ListEvents.self, ListReminders.self,
        ]
    )
}

struct ListCalendars: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars", abstract: "List event calendars.")
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(manager.listCalendars(), format: outputFormat.format)
    }
}

struct ListReminderLists: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder-lists", abstract: "List reminder lists.")
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(manager.listReminderLists(), format: outputFormat.format)
    }
}

struct ListSources: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "List account sources and IDs available for event-calendar creation.")
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(manager.listSources(), format: outputFormat.format)
    }
}

struct ListEvents: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events in one or more calendars within a date range.")

    @Option(name: .long, help: "Calendar ID or alias; comma-separate multiple values.")
    var calendar: String
    @Option(name: .long, help: "Start in \(DateParsing.acceptedFormats).") var from: String
    @Option(name: .long, help: "End in \(DateParsing.acceptedFormats).") var to: String
    @Option(name: .long, help: "Case-insensitive title, location, and notes search.")
    var search: String?
    @Option(name: .long, help: "Availability filter.") var availability: AvailabilityFilter?
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let start = try parseTimestamp(from, flag: "--from", format: outputFormat.format)
        let end = try parseTimestamp(to, flag: "--to", format: outputFormat.format)
        guard end > start else {
            try invalid("--to must be later than --from.", format: outputFormat.format)
        }
        guard DateRanges.isSupportedEventQuery(start: start, end: end) else {
            try invalid(
                "Event query ranges must not exceed \(DateRanges.maximumNextWindowDays) days.",
                format: outputFormat.format)
        }
        let calendarIDs: [String]
        do {
            calendarIDs = try ConfigManager.resolveCalendarIDs(calendar)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifiers(calendarIDs, flag: "--calendar", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.listEvents(
                calendarIDs: calendarIDs,
                from: start,
                to: end,
                search: search,
                availability: availability),
            format: outputFormat.format)
    }
}

struct ListReminders: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders", abstract: "List reminders in one reminder list.")
    @Option(name: .long, help: "Reminder-list ID or alias.") var list: String
    @Option(name: .long, help: "Filter by completion status.") var completed: Bool?
    @Option(name: .long, help: "Case-insensitive title and notes search.") var search: String?
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let listID: String
        do {
            listID = try ConfigManager.resolveAlias(list)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifier(listID, flag: "--list", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(
            manager.listReminders(listID: listID, completed: completed, search: search),
            format: outputFormat.format)
    }
}

// MARK: - Show commands

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show one item.", subcommands: [ShowEvent.self, ShowReminder.self])
}

struct ShowEvent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "event")
    @Argument(help: "Event identifier.") var eventID: String
    @OptionGroup var occurrence: OccurrenceOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try validateIdentifier(eventID, flag: "event ID", format: outputFormat.format)
        let selector = try occurrence.selector(format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(manager.showEvent(eventID: eventID, selector: selector), format: outputFormat.format)
    }
}

struct ShowReminder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reminder")
    @Argument(help: "Reminder identifier.") var reminderID: String
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try validateIdentifier(reminderID, flag: "reminder ID", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(manager.showReminder(reminderID: reminderID), format: outputFormat.format)
    }
}

// MARK: - Add commands

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create an item.", subcommands: [AddEvent.self, AddReminder.self])
}

struct AddEvent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "event")

    @Option(name: .long, help: "Event-calendar ID or alias.") var calendar: String
    @Option(name: .long, help: "Event title.") var title: String
    @Option(name: .long, help: "Timed timestamp, or YYYY-MM-DD with --all-day.") var start: String
    @Option(name: .long, help: "Timed end, or exclusive YYYY-MM-DD boundary with --all-day.")
    var end: String
    @Option(name: .long, help: "Location text.") var location: String?
    @Option(name: .long, help: "Notes.") var notes: String?
    @Flag(name: .long, help: "Require date-only start/end values.") var allDay = false

    @Option(name: .long, help: "daily, weekly, monthly, or yearly.")
    var recurrenceFrequency: String?
    @Option(name: .long, help: "Positive recurrence interval.") var recurrenceInterval: String?
    @Option(name: .long, help: "Positive occurrence count.") var recurrenceEndCount: String?
    @Option(name: .long, help: "Strict timestamp, or YYYY-MM-DD for all-day events.")
    var recurrenceEndDate: String?
    @Flag(name: .long, help: "Explicitly create an unbounded recurrence.")
    var recurrenceNoEnd = false
    @Option(name: .long, help: "Comma-separated weekdays, optionally with ordinals.")
    var recurrenceDays: String?
    @Option(name: .long, help: "Comma-separated month numbers or names.")
    var recurrenceMonths: String?
    @Option(name: .long, help: "Comma-separated signed month days.")
    var recurrenceDaysOfMonth: String?
    @Option(name: .long, help: "Comma-separated signed year weeks.")
    var recurrenceWeeksOfYear: String?
    @Option(name: .long, help: "Comma-separated signed year days.")
    var recurrenceDaysOfYear: String?
    @Option(name: .long, help: "Comma-separated signed set positions.")
    var recurrenceSetPositions: String?

    @Option(name: .long, help: "Alarm minutes: bare positive/negative are before; explicit + is after.")
    var alarms: String?
    @Option(name: .long, help: "Absolute event URL.") var url: String?
    @Option(name: .long, help: "Event availability.") var availability: AvailabilitySetting?
    @Flag(name: .long, help: "Opt in to sending --location to Apple's geocoder before saving.")
    var geocodeLocation = false
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try invalid("--title must not be empty.", format: outputFormat.format)
        }
        if geocodeLocation && location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            try invalid("--geocode-location requires a non-empty --location.", format: outputFormat.format)
        }
        try validateURL(url, format: outputFormat.format)
        let startDate = try parseEventDate(
            start, flag: "--start", allDay: allDay, format: outputFormat.format)
        let endDate = try parseEventDate(
            end, flag: "--end", allDay: allDay, format: outputFormat.format)
        try validateEventRange(
            start: startDate, end: endDate, allDay: allDay, format: outputFormat.format)
        let parsedAlarms = try parseAlarms(alarms, format: outputFormat.format)
        let recurrence: ParsedRecurrence?
        do {
            recurrence = try InputValidation.parseRecurrence(
                frequency: recurrenceFrequency,
                interval: recurrenceInterval,
                endCount: recurrenceEndCount,
                endDate: recurrenceEndDate,
                noEnd: recurrenceNoEnd,
                days: recurrenceDays,
                months: recurrenceMonths,
                daysOfMonth: recurrenceDaysOfMonth,
                weeksOfYear: recurrenceWeeksOfYear,
                daysOfYear: recurrenceDaysOfYear,
                setPositions: recurrenceSetPositions,
                allDay: allDay,
                eventStart: startDate,
                timeZone: .current)
        } catch {
            try invalid(error.localizedDescription, format: outputFormat.format)
        }
        let calendarID: String
        do {
            calendarID = try ConfigManager.resolveAlias(calendar)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifier(calendarID, flag: "--calendar", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.addEvent(
                calendarID: calendarID,
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                allDay: allDay,
                recurrenceFrequency: recurrence?.frequency,
                recurrenceInterval: recurrence?.interval ?? 1,
                recurrenceEndCount: recurrence?.endCount,
                recurrenceEndDate: recurrence?.endDate,
                recurrenceDays: recurrence?.days,
                recurrenceMonths: recurrence?.months,
                recurrenceDaysOfMonth: recurrence?.daysOfMonth,
                recurrenceWeeksOfYear: recurrence?.weeksOfYear,
                recurrenceDaysOfYear: recurrence?.daysOfYear,
                recurrenceSetPositions: recurrence?.setPositions,
                alarms: parsedAlarms,
                url: url,
                availability: availability,
                geocodeLocation: geocodeLocation,
                dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

struct AddReminder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reminder")
    @Option(name: .long, help: "Reminder-list ID or alias.") var list: String
    @Option(name: .long, help: "Reminder title.") var title: String
    @Option(name: .long, help: "Due date in \(DateParsing.acceptedFormats).") var due: String?
    @Option(name: .long, help: "One digit from 0 through 9.") var priority: String?
    @Option(name: .long, help: "Notes.") var notes: String?
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try invalid("--title must not be empty.", format: outputFormat.format)
        }
        let dueDate = try due.map {
            try parseTimestamp($0, flag: "--due", format: outputFormat.format)
        }
        let parsedPriority = try parsePriority(
            priority, default: 0, format: outputFormat.format) ?? 0
        let listID: String
        do {
            listID = try ConfigManager.resolveAlias(list)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifier(listID, flag: "--list", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(
            manager.addReminder(
                listID: listID,
                title: title,
                dueDate: dueDate,
                priority: parsedPriority,
                notes: notes,
                dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

// MARK: - Update commands

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update an item.", subcommands: [UpdateEvent.self, UpdateReminder.self])
}

struct UpdateEvent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "event")
    @Argument(help: "Event identifier.") var eventID: String
    @OptionGroup var occurrence: OccurrenceOptions
    @Option(name: .long) var title: String?
    @Option(name: .long, help: "New timestamp, or YYYY-MM-DD when --all-day true.")
    var start: String?
    @Option(name: .long, help: "New exclusive boundary; format follows --all-day.")
    var end: String?
    @Option(name: .long) var location: String?
    @Option(name: .long) var notes: String?
    @Option(name: .long, help: "Date changes require start, end, and this flag together.")
    var allDay: Bool?
    @Option(name: .long) var url: String?
    @Option(name: .long) var availability: AvailabilitySetting?
    @Option(name: .long, help: "Replacement alarm offsets in minutes.") var alarms: String?
    @Flag(name: .long, help: "Explicitly remove every alarm from the event.")
    var clearAlarms = false
    @Flag(name: .long, help: "Opt in to geocoding the new --location.")
    var geocodeLocation = false
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try validateIdentifier(eventID, flag: "event ID", format: outputFormat.format)
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try invalid("--title must not be empty.", format: outputFormat.format)
        }
        let changesRequested = title != nil || start != nil || end != nil || location != nil
            || notes != nil || allDay != nil || url != nil || availability != nil || alarms != nil
            || clearAlarms || geocodeLocation
        guard changesRequested else {
            try invalid("No event changes were supplied.", format: outputFormat.format)
        }
        let changesDateShape = start != nil || end != nil || allDay != nil
        if changesDateShape && !(start != nil && end != nil && allDay != nil) {
            try invalid(
                "Date changes require --start, --end, and --all-day true/false together.",
                format: outputFormat.format)
        }
        if geocodeLocation && location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            try invalid("--geocode-location requires a non-empty --location.", format: outputFormat.format)
        }
        if alarms != nil && clearAlarms {
            try invalid(
                "--alarms and --clear-alarms are mutually exclusive.",
                format: outputFormat.format)
        }
        try validateURL(url, format: outputFormat.format)
        let startDate = try start.map {
            try parseEventDate(
                $0, flag: "--start", allDay: allDay!, format: outputFormat.format)
        }
        let endDate = try end.map {
            try parseEventDate($0, flag: "--end", allDay: allDay!, format: outputFormat.format)
        }
        if let startDate, let endDate {
            try validateEventRange(
                start: startDate,
                end: endDate,
                allDay: allDay!,
                format: outputFormat.format)
        }
        let parsedAlarms = clearAlarms
            ? [] : try parseAlarms(alarms, format: outputFormat.format)
        let selector = try occurrence.selector(format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.updateEvent(
                eventID: eventID,
                selector: selector,
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                allDay: allDay,
                url: url,
                availability: availability,
                alarms: parsedAlarms,
                geocodeLocation: geocodeLocation,
                dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

struct UpdateReminder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reminder")
    @Argument(help: "Reminder identifier.") var reminderID: String
    @Option(name: .long) var title: String?
    @Option(name: .long, help: "New due date in \(DateParsing.acceptedFormats).") var due: String?
    @Option(name: .long, help: "One digit from 0 through 9.") var priority: String?
    @Option(name: .long) var notes: String?
    @Option(name: .long) var completed: Bool?
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try validateIdentifier(reminderID, flag: "reminder ID", format: outputFormat.format)
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try invalid("--title must not be empty.", format: outputFormat.format)
        }
        guard title != nil || due != nil || priority != nil || notes != nil || completed != nil else {
            try invalid("No reminder changes were supplied.", format: outputFormat.format)
        }
        let dueDate = try due.map {
            try parseTimestamp($0, flag: "--due", format: outputFormat.format)
        }
        let parsedPriority = try parsePriority(priority, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(
            manager.updateReminder(
                reminderID: reminderID,
                title: title,
                dueDate: dueDate,
                priority: parsedPriority,
                notes: notes,
                completed: completed,
                dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

// MARK: - Calendar commands

struct CalendarCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Manage event calendars.",
        subcommands: [CreateCalendar.self, UpdateCalendar.self, DeleteCalendar.self])
}

struct CreateCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @Option(name: .long, help: "Exact source ID from `eventkitcontrol list sources`.") var source: String
    @Option(name: .long) var title: String
    @Option(name: .long, help: "Exact #RRGGBB color.") var color: String?
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try validateIdentifier(source, flag: "--source", format: outputFormat.format)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try invalid("--title must not be empty.", format: outputFormat.format)
        }
        try validateColor(color, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.createCalendar(
                sourceID: source, title: title, color: color, dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

struct UpdateCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update")
    @Argument(help: "Event-calendar ID or alias.") var calendarID: String
    @Option(name: .long) var title: String?
    @Option(name: .long, help: "Exact #RRGGBB color.") var color: String?
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        guard title != nil || color != nil else {
            try invalid("No calendar changes were supplied.", format: outputFormat.format)
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try invalid("--title must not be empty.", format: outputFormat.format)
        }
        try validateColor(color, format: outputFormat.format)
        let resolvedID: String
        do {
            resolvedID = try ConfigManager.resolveAlias(calendarID)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifier(resolvedID, flag: "calendar ID", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.updateCalendar(
                calendarID: resolvedID,
                title: title,
                color: color,
                dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

struct DeleteCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Delete an event calendar.")
    @Argument(help: "Event-calendar ID or alias.") var calendarID: String
    @Option(name: .long, help: "Exact resolved calendar ID; required for a real deletion.")
    var confirm: String?
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let resolvedID: String
        do {
            resolvedID = try ConfigManager.resolveAlias(calendarID)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifier(resolvedID, flag: "calendar ID", format: outputFormat.format)
        if !mutation.dryRun && confirm != resolvedID {
            try invalid(
                "Calendar deletion requires --confirm with the exact resolved ID: \(resolvedID)",
                format: outputFormat.format)
        }
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.deleteCalendar(calendarID: resolvedID, dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

// MARK: - Delete and complete commands

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete an item.", subcommands: [DeleteEvent.self, DeleteReminder.self])
}

struct DeleteEvent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "event")
    @Argument(help: "Event identifier.") var eventID: String
    @OptionGroup var occurrence: OccurrenceOptions
    @Flag(name: .long, help: "Required for a real deletion.") var yes = false
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        guard yes || mutation.dryRun else {
            try invalid(
                "Event deletion requires --yes (or use --dry-run).", format: outputFormat.format)
        }
        try validateIdentifier(eventID, flag: "event ID", format: outputFormat.format)
        let selector = try occurrence.selector(format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.deleteEvent(
                eventID: eventID, selector: selector, dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

struct DeleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reminder")
    @Argument(help: "Reminder identifier.") var reminderID: String
    @Flag(name: .long, help: "Required for a real deletion.") var yes = false
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        guard yes || mutation.dryRun else {
            try invalid(
                "Reminder deletion requires --yes (or use --dry-run).", format: outputFormat.format)
        }
        try validateIdentifier(reminderID, flag: "reminder ID", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(
            manager.deleteReminder(reminderID: reminderID, dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

struct Complete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark an item completed.", subcommands: [CompleteReminder.self])
}

struct CompleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reminder")
    @Argument(help: "Reminder identifier.") var reminderID: String
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try validateIdentifier(reminderID, flag: "reminder ID", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .reminders, format: outputFormat.format)
        try emit(
            manager.completeReminder(reminderID: reminderID, dryRun: mutation.dryRun),
            format: outputFormat.format)
    }
}

// MARK: - Alias commands

struct Alias: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage local aliases.",
        subcommands: [AliasSet.self, AliasRemove.self, AliasList.self])
}

struct AliasSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set")
    @Argument(help: "Alias name.") var name: String
    @Argument(help: "Calendar or reminder-list ID.") var id: String
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        do {
            try ConfigManager.validateAlias(name: name, id: id)
            // A dry run must validate the same existing config state that the
            // real read-modify-write operation depends on. This read is
            // side-effect-free and also provides an accurate before value.
            let aliases = try ConfigManager.getAliases()
            if !mutation.dryRun { try ConfigManager.setAlias(name: name, id: id) }
            try emit(
                .success([
                    "dryRun": mutation.dryRun,
                    "applied": !mutation.dryRun,
                    "message": mutation.dryRun
                        ? "Alias update validated; configuration was not changed."
                        : "Alias set successfully.",
                    "alias": ["name": name, "id": id],
                    "changes": [
                        "id": [
                            "before": aliases[name].map { $0 as Any } ?? NSNull(),
                            "after": id,
                        ],
                    ],
                ]),
                format: outputFormat.format)
        } catch let code as ExitCode {
            throw code
        } catch {
            try configFailed(error, context: "Failed to set alias", format: outputFormat.format)
        }
    }
}

struct AliasRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove")
    @Argument(help: "Alias name.") var name: String
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        do {
            try ConfigManager.validateAliasName(name)
            let aliases = try ConfigManager.getAliases()
            guard aliases[name] != nil else {
                try operationFailed("Alias '\(name)' was not found.", format: outputFormat.format)
            }
            if !mutation.dryRun {
                guard try ConfigManager.removeAlias(name: name) else {
                    try operationFailed("Alias '\(name)' was not found.", format: outputFormat.format)
                }
            }
            try emit(
                .success([
                    "dryRun": mutation.dryRun,
                    "applied": !mutation.dryRun,
                    "message": mutation.dryRun
                        ? "Alias removal validated; configuration was not changed."
                        : "Alias removed successfully.",
                    "alias": ["name": name, "id": aliases[name]!],
                ]),
                format: outputFormat.format)
        } catch let code as ExitCode {
            throw code
        } catch {
            try configFailed(error, context: "Failed to remove alias", format: outputFormat.format)
        }
    }
}

struct AliasList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        do {
            let aliases = try ConfigManager.getAliases()
            let rows = aliases.sorted(by: { $0.key < $1.key }).map {
                ["name": $0.key, "id": $0.value]
            }
            try emit(
                .success([
                    "aliases": rows,
                    "count": rows.count,
                    "configPath": try ConfigManager.configPath(),
                ]),
                format: outputFormat.format)
        } catch let code as ExitCode {
            throw code
        } catch {
            try operationFailed(
                "Failed to read aliases: \(error.localizedDescription)", format: outputFormat.format)
        }
    }
}

// MARK: - Quick date-range commands

private func listQuickRange(
    calendar: String,
    search: String?,
    availability: AvailabilityFilter?,
    range: (Date, Date),
    outputFormat: OutputFormatOptions
) throws {
    let calendarIDs: [String]
    do {
        calendarIDs = try ConfigManager.resolveCalendarIDs(calendar)
    } catch {
        try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
    }
    try validateIdentifiers(calendarIDs, flag: "--calendar", format: outputFormat.format)
    let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
    try requestAccess(manager, .events, format: outputFormat.format)
    try emit(
        manager.listEvents(
            calendarIDs: calendarIDs,
            from: range.0,
            to: range.1,
            search: search,
            availability: availability),
        format: outputFormat.format)
}

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today", abstract: "List events occurring today in local time.")
    @Option(name: .long) var calendar: String
    @Option(name: .long) var search: String?
    @Option(name: .long) var availability: AvailabilityFilter?
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try listQuickRange(
            calendar: calendar,
            search: search,
            availability: availability,
            range: DateRanges.today(),
            outputFormat: outputFormat)
    }
}

struct Tomorrow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tomorrow", abstract: "List events occurring tomorrow in local time.")
    @Option(name: .long) var calendar: String
    @Option(name: .long) var search: String?
    @Option(name: .long) var availability: AvailabilityFilter?
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        try listQuickRange(
            calendar: calendar,
            search: search,
            availability: availability,
            range: DateRanges.tomorrow(),
            outputFormat: outputFormat)
    }
}

struct Next: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next", abstract: "List the next upcoming events.")
    @Option(name: .long) var calendar: String
    @Option(name: .long, help: "Positive number of events.") var count = 1
    @Option(name: .long, help: "Positive lookahead in days.") var days = 90
    @Option(name: .long) var search: String?
    @Option(name: .long) var availability: AvailabilityFilter?
    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        guard count > 0 else {
            try invalid("--count must be positive.", format: outputFormat.format)
        }
        guard (1...DateRanges.maximumNextWindowDays).contains(days) else {
            try invalid(
                "--days must be between 1 and \(DateRanges.maximumNextWindowDays).",
                format: outputFormat.format)
        }
        guard let range = DateRanges.nextWindow(days: days) else {
            try invalid("--days could not be represented as a date range.", format: outputFormat.format)
        }
        let calendarIDs: [String]
        do {
            calendarIDs = try ConfigManager.resolveCalendarIDs(calendar)
        } catch {
            try configFailed(error, context: "Could not read aliases", format: outputFormat.format)
        }
        try validateIdentifiers(calendarIDs, flag: "--calendar", format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try requestAccess(manager, .events, format: outputFormat.format)
        try emit(
            manager.listEvents(
                calendarIDs: calendarIDs,
                from: range.0,
                to: range.1,
                search: search,
                availability: availability,
                sortedByStartAscending: true,
                limit: count),
            format: outputFormat.format)
    }
}
