import Foundation

public struct ParsedRecurrence {
    public let frequency: String
    public let interval: Int
    public let endCount: Int?
    public let endDate: Date?
    public let days: String?
    public let months: [NSNumber]?
    public let daysOfMonth: [NSNumber]?
    public let weeksOfYear: [NSNumber]?
    public let daysOfYear: [NSNumber]?
    public let setPositions: [NSNumber]?
}

public enum InputValidationError: LocalizedError, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// Fail-closed parsing for recurrence and small scalar command values.
public enum InputValidation {
    private static let integerRegex = try! NSRegularExpression(pattern: #"^-?(?:0|[1-9][0-9]*)$"#)
    private static let positiveRegex = try! NSRegularExpression(pattern: #"^(?:0|[1-9][0-9]*)$"#)
    private static let weekdayRegex = try! NSRegularExpression(
        pattern: #"^(-?(?:0|[1-9][0-9]*))?(mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)$"#,
        options: [.caseInsensitive]
    )

    public static func parsePriority(_ value: String) throws -> Int {
        guard value.count == 1, let scalar = value.unicodeScalars.first,
              scalar.value >= 48, scalar.value <= 57
        else { throw InputValidationError.message("Priority must be one digit from 0 through 9.") }
        return Int(scalar.value - 48)
    }

    public static func validateHexColor(_ value: String) throws -> String {
        let pattern = try! NSRegularExpression(pattern: #"^#[0-9A-Fa-f]{6}$"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard pattern.firstMatch(in: value, range: range)?.range == range else {
            throw InputValidationError.message("Color must be exactly #RRGGBB.")
        }
        return value
    }

    public static func validateIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 1_024,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(","),
              value.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw InputValidationError.message(
                "Identifiers must be non-empty, at most 1024 characters, and contain no surrounding whitespace, commas, or control characters."
            )
        }
        return value
    }

    public static func parseRecurrence(
        frequency: String?,
        interval: String?,
        endCount: String?,
        endDate: String?,
        noEnd: Bool,
        days: String?,
        months: String?,
        daysOfMonth: String?,
        weeksOfYear: String?,
        daysOfYear: String?,
        setPositions: String?,
        allDay: Bool,
        eventStart: Date,
        timeZone: TimeZone
    ) throws -> ParsedRecurrence? {
        let anyOption = [interval, endCount, endDate, days, months, daysOfMonth,
                         weeksOfYear, daysOfYear, setPositions].contains { $0 != nil } || noEnd
        guard let rawFrequency = frequency else {
            if anyOption {
                throw InputValidationError.message(
                    "Recurrence options require --recurrence-frequency.")
            }
            return nil
        }

        let normalizedFrequency = rawFrequency.lowercased()
        guard ["daily", "weekly", "monthly", "yearly"].contains(normalizedFrequency) else {
            throw InputValidationError.message(
                "Recurrence frequency must be daily, weekly, monthly, or yearly.")
        }

        let parsedInterval = try interval.map {
            try parsePositive($0, flag: "--recurrence-interval")
        } ?? 1
        let parsedCount = try endCount.map {
            try parsePositive($0, flag: "--recurrence-end-count")
        }

        let selectedEndModes = (parsedCount == nil ? 0 : 1) + (endDate == nil ? 0 : 1) + (noEnd ? 1 : 0)
        guard selectedEndModes == 1 else {
            throw InputValidationError.message(
                "Choose exactly one recurrence end: --recurrence-end-count, "
                    + "--recurrence-end-date, or --recurrence-no-end.")
        }

        var parsedEndDate: Date?
        if let endDate {
            if allDay {
                guard let localDay = DateParsing.parseLocalDay(endDate),
                      let startOfDay = localDay.date(in: timeZone)
                else {
                    throw InputValidationError.message(
                        "All-day recurrence end dates must use YYYY-MM-DD.")
                }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
                    throw InputValidationError.message("Invalid recurrence end date.")
                }
                parsedEndDate = nextDay.addingTimeInterval(-0.001)
            } else {
                guard let date = DateParsing.parse(endDate) else {
                    throw InputValidationError.message(
                        "Timed recurrence end dates must use \(DateParsing.acceptedFormats).")
                }
                parsedEndDate = date
            }
            guard let parsedEndDate, parsedEndDate >= eventStart else {
                throw InputValidationError.message(
                    "Recurrence end date must not precede the first event.")
            }
        }

        let normalizedDays = try days.map {
            try validateWeekdays($0, frequency: normalizedFrequency)
        }
        let parsedMonths = try months.map {
            try parseMonths($0, flag: "--recurrence-months")
        }
        let parsedMonthDays = try daysOfMonth.map {
            try parseIntegerList($0, flag: "--recurrence-days-of-month", range: -31...31)
        }
        let parsedWeeks = try weeksOfYear.map {
            try parseIntegerList($0, flag: "--recurrence-weeks-of-year", range: -53...53)
        }
        let parsedYearDays = try daysOfYear.map {
            try parseIntegerList($0, flag: "--recurrence-days-of-year", range: -366...366)
        }
        let parsedPositions = try setPositions.map {
            try parseIntegerList($0, flag: "--recurrence-set-positions", range: -366...366)
        }

        switch normalizedFrequency {
        case "daily":
            guard normalizedDays == nil, parsedMonths == nil, parsedMonthDays == nil,
                  parsedWeeks == nil, parsedYearDays == nil, parsedPositions == nil
            else { throw incompatible(normalizedFrequency) }
        case "weekly":
            guard parsedMonths == nil, parsedMonthDays == nil, parsedWeeks == nil,
                  parsedYearDays == nil, parsedPositions == nil
            else { throw incompatible(normalizedFrequency) }
        case "monthly":
            guard parsedMonths == nil, parsedWeeks == nil, parsedYearDays == nil else {
                throw incompatible(normalizedFrequency)
            }
            guard !(normalizedDays != nil && parsedMonthDays != nil) else {
                throw InputValidationError.message(
                    "Monthly recurrence cannot combine weekdays and days of month.")
            }
            if parsedPositions != nil && normalizedDays == nil && parsedMonthDays == nil {
                throw InputValidationError.message(
                    "Set positions require another monthly recurrence selector.")
            }
        case "yearly":
            guard parsedMonthDays == nil else { throw incompatible(normalizedFrequency) }
            if parsedPositions != nil && normalizedDays == nil && parsedMonths == nil
                && parsedWeeks == nil && parsedYearDays == nil
            {
                throw InputValidationError.message(
                    "Set positions require another yearly recurrence selector.")
            }
        default:
            preconditionFailure("frequency was validated")
        }

        return ParsedRecurrence(
            frequency: normalizedFrequency,
            interval: parsedInterval,
            endCount: parsedCount,
            endDate: parsedEndDate,
            days: normalizedDays,
            months: parsedMonths?.map(NSNumber.init),
            daysOfMonth: parsedMonthDays?.map(NSNumber.init),
            weeksOfYear: parsedWeeks?.map(NSNumber.init),
            daysOfYear: parsedYearDays?.map(NSNumber.init),
            setPositions: parsedPositions?.map(NSNumber.init)
        )
    }

    private static func parsePositive(_ value: String, flag: String) throws -> Int {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard positiveRegex.firstMatch(in: value, range: range)?.range == range,
              let parsed = Int(value), parsed > 0, parsed <= Int(Int32.max)
        else {
            throw InputValidationError.message("\(flag) must be a positive integer.")
        }
        return parsed
    }

    private static func parseIntegerList(
        _ value: String, flag: String, range allowed: ClosedRange<Int>
    ) throws -> [Int] {
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw InputValidationError.message("\(flag) must not be empty.")
        }
        var result: [Int] = []
        var seen: Set<Int> = []
        for component in components {
            let token = component.trimmingCharacters(in: .whitespaces)
            let nsRange = NSRange(token.startIndex..<token.endIndex, in: token)
            guard !token.isEmpty,
                  integerRegex.firstMatch(in: token, range: nsRange)?.range == nsRange,
                  let number = Int(token), number != 0, allowed.contains(number),
                  seen.insert(number).inserted
            else {
                throw InputValidationError.message(
                    "\(flag) contains an invalid, zero, duplicate, or out-of-range value.")
            }
            result.append(number)
        }
        return result
    }

    private static func parseMonths(_ value: String, flag: String) throws -> [Int] {
        let names: [String: Int] = [
            "jan": 1, "january": 1, "feb": 2, "february": 2,
            "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
            "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8,
            "august": 8, "sep": 9, "september": 9, "oct": 10,
            "october": 10, "nov": 11, "november": 11, "dec": 12,
            "december": 12,
        ]
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw InputValidationError.message("\(flag) must not be empty.")
        }
        var result: [Int] = []
        var seen: Set<Int> = []
        for component in components {
            let token = component.trimmingCharacters(in: .whitespaces).lowercased()
            let number: Int?
            if let named = names[token] {
                number = named
            } else {
                let nsRange = NSRange(token.startIndex..<token.endIndex, in: token)
                number = positiveRegex.firstMatch(in: token, range: nsRange)?.range == nsRange
                    ? Int(token) : nil
            }
            guard let number, (1...12).contains(number), seen.insert(number).inserted else {
                throw InputValidationError.message(
                    "\(flag) contains an invalid or duplicate month.")
            }
            result.append(number)
        }
        return result
    }

    private static func validateWeekdays(_ value: String, frequency: String) throws -> String {
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw InputValidationError.message("Recurrence weekdays must not be empty.")
        }
        var normalized: [String] = []
        var seen: Set<String> = []
        for component in components {
            let token = component.trimmingCharacters(in: .whitespaces).lowercased()
            let range = NSRange(token.startIndex..<token.endIndex, in: token)
            guard let match = weekdayRegex.firstMatch(in: token, range: range), match.range == range
            else {
                throw InputValidationError.message("Invalid recurrence weekday: \(token).")
            }
            let ordinalString = capture(1, match: match, input: token)
            if let ordinalString {
                let limit = frequency == "monthly" ? 5 : 53
                guard let ordinal = Int(ordinalString),
                      frequency != "weekly",
                      ((-limit)...(-1)).contains(ordinal)
                        || (1...limit).contains(ordinal)
                else {
                    throw InputValidationError.message(
                        "Weekday ordinals are not valid for this recurrence frequency.")
                }
            }
            guard let weekday = capture(2, match: match, input: token) else {
                throw InputValidationError.message("Invalid recurrence weekday: \(token).")
            }
            // Collapse spelling variants (`mon`/`monday`) before duplicate
            // detection so the same semantic selector cannot be supplied twice.
            let canonical = (ordinalString ?? "") + String(weekday.lowercased().prefix(3))
            guard seen.insert(canonical).inserted else {
                throw InputValidationError.message("Duplicate recurrence weekday: \(token).")
            }
            normalized.append(canonical)
        }
        return normalized.joined(separator: ",")
    }

    private static func capture(
        _ index: Int, match: NSTextCheckingResult, input: String
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: input) else {
            return nil
        }
        return String(input[swiftRange])
    }

    private static func incompatible(_ frequency: String) -> InputValidationError {
        .message("One or more selectors are incompatible with \(frequency) recurrence.")
    }
}
