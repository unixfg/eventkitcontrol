import Foundation

/// A validated Gregorian civil date used for all-day events.
public struct LocalDay: Equatable, Hashable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Returns local midnight for this civil date in `timeZone`.
    public func date(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        guard let date = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: year,
                month: month,
                day: day,
                hour: 0,
                minute: 0,
                second: 0
            ))
        else { return nil }

        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return date
    }
}

/// Strict date parsing shared by every date-taking CLI flag.
///
/// Unlike `ISO8601DateFormatter.date(from:)`, this parser consumes the entire
/// input and rejects calendar normalization (for example, February 30),
/// trailing junk, and impossible time-zone offsets.
public enum DateParsing {
    public static let acceptedFormats =
        "ISO 8601 (YYYY-MM-DDTHH:mm:ss[.fraction]Z, ±HH:MM, or ±HHMM)"
    public static let allDayFormat = "YYYY-MM-DD"

    private static let timestampRegex = try! NSRegularExpression(
        pattern:
            #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:?[0-9]{2})$"#
    )
    private static let localDayRegex = try! NSRegularExpression(
        pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})$"#
    )

    public static func parse(_ string: String) -> Date? {
        let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
        guard
            let match = timestampRegex.firstMatch(in: string, range: nsRange),
            match.range == nsRange,
            let year = integerCapture(1, match: match, input: string),
            let month = integerCapture(2, match: match, input: string),
            let day = integerCapture(3, match: match, input: string),
            let hour = integerCapture(4, match: match, input: string),
            let minute = integerCapture(5, match: match, input: string),
            let second = integerCapture(6, match: match, input: string),
            (1...9999).contains(year),
            (1...12).contains(month),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...59).contains(second),
            let zoneString = capture(8, match: match, input: string),
            let zone = parseTimeZone(zoneString)
        else { return nil }

        let nanosecond: Int
        if let fraction = capture(7, match: match, input: string) {
            let padded = fraction + String(repeating: "0", count: 9 - fraction.count)
            guard let parsed = Int(padded) else { return nil }
            nanosecond = parsed
        } else {
            nanosecond = 0
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        let components = DateComponents(
            calendar: calendar,
            timeZone: zone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: nanosecond
        )
        guard let date = calendar.date(from: components) else { return nil }

        // Calendar can normalize invalid components; require an exact round trip.
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard
            roundTrip.year == year,
            roundTrip.month == month,
            roundTrip.day == day,
            roundTrip.hour == hour,
            roundTrip.minute == minute,
            roundTrip.second == second
        else { return nil }
        return date
    }

    public static func parseLocalDay(_ string: String) -> LocalDay? {
        let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
        guard
            let match = localDayRegex.firstMatch(in: string, range: nsRange),
            match.range == nsRange,
            let year = integerCapture(1, match: match, input: string),
            let month = integerCapture(2, match: match, input: string),
            let day = integerCapture(3, match: match, input: string),
            (1...9999).contains(year),
            (1...12).contains(month)
        else { return nil }

        let localDay = LocalDay(year: year, month: month, day: day)
        guard localDay.date(in: TimeZone(secondsFromGMT: 0)!) != nil else { return nil }
        return localDay
    }

    public static func formatLocalDay(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func parseTimeZone(_ string: String) -> TimeZone? {
        if string == "Z" { return TimeZone(secondsFromGMT: 0) }

        let sign = string.first == "-" ? -1 : 1
        let digits = string.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              (0...14).contains(hours),
              (0...59).contains(minutes),
              hours < 14 || minutes == 0
        else { return nil }

        // RFC 3339 gives -00:00 the special meaning "unknown local offset".
        if sign < 0 && hours == 0 && minutes == 0 { return nil }
        return TimeZone(secondsFromGMT: sign * ((hours * 60 + minutes) * 60))
    }

    private static func integerCapture(
        _ index: Int, match: NSTextCheckingResult, input: String
    ) -> Int? {
        capture(index, match: match, input: input).flatMap(Int.init)
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
}
