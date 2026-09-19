import Foundation

/// Captures one reference instant and local time zone for a command's inputs.
/// Exact occurrence selectors continue to use `DateParsing.parse(_:)` directly.
public struct DateInputContext {
    public let now: Date
    public let timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }

    public func parse(_ string: String) -> Date? {
        if let timestamp = DateParsing.parse(string) { return timestamp }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return RelativeDates.parse(string, now: now, calendar: calendar)
    }
}

/// Human date input grammar, separate from strict timestamp and all-day parsers.
///
/// The grammar, all case-insensitive:
///
///   now                      the current instant
///   +90m  -2h  +3d  +1w      an offset from now (m/min, h/hr, d/day, w/week)
///   today  tomorrow  yesterday
///   fri  friday             the next Friday, today included
///   next fri                the next Friday, today excluded
///   last fri                the most recent Friday, today excluded
///   next week  last week    seven days either side of today
///   2026-02-01              a plain date
///   14:30  3pm  9:15am      a time today
///   noon  midnight
///   tomorrow 3pm            any day above, with any time above
///   next fri at 09:00       "at" is optional filler
///
/// A bare day resolves to the *start* of that day, which is what a range
/// endpoint like `--from tomorrow` should mean. A bare number is deliberately
/// rejected: "9" could be a time or a day of the month, and guessing wrong
/// would book a meeting three weeks out.
///
/// `now` and `calendar` are parameters rather than globals so the whole grammar
/// can be tested against pinned instants and zones.
public enum RelativeDates {

    /// One-line summary folded into `DateParsing.acceptedInputFormats`.
    public static let acceptedFormats =
        "a date (2026-02-01), a shorthand (now, today, tomorrow, fri, 'tomorrow 3pm', 14:30), or an offset (+90m, +2h, +3d, +1w)"

    public static func parse(_ string: String,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> Date? {
        // All documented words, separators, and digits are ASCII. Reject lookalike
        // Unicode input before case folding or numeric conversion can change it.
        guard string.unicodeScalars.allSatisfy({ $0.value < 128 }),
              now.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        gregorian.timeZone = calendar.timeZone
        let calendar = gregorian
        let tokens = string
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        if tokens == ["now"] { return now }
        if tokens.count == 1, let offset = offset(tokens[0], from: now, calendar: calendar) {
            return offset
        }

        // A day on its own resolves to the start of that day.
        if let day = day(tokens, now: now, calendar: calendar) {
            return calendar.startOfDay(for: day)
        }
        // A time on its own is that time today.
        if let token = timeToken(tokens[...]), let minutes = timeOfDay(token) {
            return instant(minutesPastMidnight: minutes, on: now, calendar: calendar)
        }
        // Otherwise: a day phrase followed by a time.
        // Longest day phrase first, so "next friday 3pm" beats "next" alone.
        for split in stride(from: tokens.count - 1, through: 1, by: -1) {
            // "at" belongs only between a complete day phrase and a time.
            // Dropping it everywhere would silently accept "at tomorrow".
            let timeStart = tokens[split] == "at" ? split + 1 : split
            guard let day = day(Array(tokens[0..<split]), now: now, calendar: calendar),
                  let token = timeToken(tokens[timeStart...]),
                  let minutes = timeOfDay(token)
            else { continue }
            return instant(minutesPastMidnight: minutes, on: day, calendar: calendar)
        }
        return nil
    }

    // MARK: - Offsets

    /// `+90m`, `-2h`, `+3d`, `+1w`. Months and years are left out on purpose:
    /// `m` would be ambiguous between minutes and months, and a wrong guess
    /// there is a big miss.
    static func offset(_ token: String, from now: Date, calendar: Calendar) -> Date? {
        guard let sign = token.first, sign == "+" || sign == "-" else { return nil }

        let body = token.dropFirst()
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }

        let unit = String(body.dropFirst(digits.count))
        guard let component = componentFor(unit), magnitude <= maximumMagnitude(for: component)
        else { return nil }

        let value = sign == "-" ? -magnitude : magnitude
        if value == 0 { return now }
        let result: Date?
        if component == .day || component == .weekOfYear {
            // Days/weeks preserve the wall clock. Never let Calendar normalize
            // a nonexistent clock time or select either side of a repeated one.
            let days = component == .weekOfYear ? value * 7 : value
            guard let targetDay = calendar.date(
                byAdding: .day, value: days, to: calendar.startOfDay(for: now))
            else { return nil }
            let clock = calendar.dateComponents([.hour, .minute, .second], from: now)
            guard let hour = clock.hour, let minute = clock.minute, let second = clock.second,
                  let wholeSecond = instant(
                    minutesPastMidnight: hour * 60 + minute, second: second,
                    on: targetDay, calendar: calendar)
            else { return nil }
            let fraction = now.timeIntervalSince1970 - floor(now.timeIntervalSince1970)
            result = wholeSecond.addingTimeInterval(fraction)
        } else {
            // Minute/hour offsets describe elapsed time and remain unambiguous
            // even when they cross a daylight-saving transition.
            result = calendar.date(byAdding: component, value: value, to: now)
        }
        guard let result, result.timeIntervalSinceReferenceDate.isFinite,
              (1...9999).contains(calendar.component(.year, from: result)),
              calendar.component(.era, from: result) == 1
        else { return nil }
        // Foundation hands back an unmoved — or wildly overshot — date when it
        // can't represent the result, so a garbled offset would silently read
        // as "now" or flip its sign. Neither is an acceptable answer for a
        // flag that schedules things.
        guard (value > 0 ? result > now : result < now) else { return nil }
        return result
    }

    /// Roughly a century in each unit. Beyond that an offset is a typo, and
    /// resolving it to a date in year 5828963 helps nobody.
    private static func maximumMagnitude(for component: Calendar.Component) -> Int {
        switch component {
        case .minute: return 100 * 366 * 24 * 60
        case .hour: return 100 * 366 * 24
        case .day: return 100 * 366
        case .weekOfYear: return 100 * 53
        default: return 0
        }
    }

    private static func componentFor(_ unit: String) -> Calendar.Component? {
        switch unit {
        case "m", "min", "mins", "minute", "minutes": return .minute
        case "h", "hr", "hrs", "hour", "hours": return .hour
        case "d", "day", "days": return .day
        case "w", "wk", "wks", "week", "weeks": return .weekOfYear
        default: return nil
        }
    }

    // MARK: - Days

    /// Resolves a day phrase to *some* instant on that day; callers take the
    /// start of day or graft a time onto it.
    static func day(_ tokens: [String], now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)

        switch tokens.count {
        case 1:
            switch tokens[0] {
            case "today": return startOfToday
            case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: startOfToday)
            case "yesterday": return calendar.date(byAdding: .day, value: -1, to: startOfToday)
            default: break
            }
            if let weekday = Weekdays.names[tokens[0]] {
                return occurrence(of: weekday, from: startOfToday, calendar: calendar,
                                  direction: .forward, includingToday: true)
            }
            return isoDate(tokens[0], calendar: calendar)

        case 2:
            let (qualifier, subject) = (tokens[0], tokens[1])
            guard qualifier == "next" || qualifier == "last" else { return nil }
            let direction: Direction = qualifier == "next" ? .forward : .backward

            if subject == "week" {
                return calendar.date(byAdding: .day,
                                     value: direction == .forward ? 7 : -7,
                                     to: startOfToday)
            }
            guard let weekday = Weekdays.names[subject] else { return nil }
            // "next friday" said on a Friday means the following one, and
            // "last friday" likewise never means today.
            return occurrence(of: weekday, from: startOfToday, calendar: calendar,
                              direction: direction, includingToday: false)

        default:
            return nil
        }
    }

    enum Direction { case forward, backward }

    private static func occurrence(of weekday: Int,
                                   from startOfToday: Date,
                                   calendar: Calendar,
                                   direction: Direction,
                                   includingToday: Bool) -> Date? {
        let today = calendar.component(.weekday, from: startOfToday)
        var delta = direction == .forward
            ? (weekday - today + 7) % 7
            : (today - weekday + 7) % 7
        if delta == 0 && !includingToday { delta = 7 }
        return calendar.date(byAdding: .day,
                             value: direction == .forward ? delta : -delta,
                             to: startOfToday)
    }

    /// `2026-02-01` — a plain date, which the ISO 8601 formatters reject
    /// because they require a time component.
    ///
    /// Civil dates always use the Gregorian calendar and the captured zone,
    /// independent of the user's preferred region calendar.
    static func isoDate(_ token: String, calendar: Calendar) -> Date? {
        DateParsing.parseLocalDay(token)?.date(in: calendar.timeZone)
    }

    /// ASCII digits only. `Int("+026")` is 26 and `Int("٣")` is 3, so a plain
    /// `Int(_:)` would let `+026-02-01` through as year 26.
    static func isAllDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Times

    /// The tokens that may make up a time. A lone `am`/`pm` is allowed to stand
    /// apart ("3 pm"), but nothing else is glued together: joining freely turned
    /// the fat-fingered "1 4:30" into 14:30 without a word.
    static func timeToken(_ tokens: ArraySlice<String>) -> String? {
        switch tokens.count {
        case 1:
            return tokens.first
        case 2:
            guard let last = tokens.last, last == "am" || last == "pm" else { return nil }
            return tokens.joined()
        default:
            return nil
        }
    }

    /// `14:30`, `3pm`, `9:15am`, `noon`, `midnight` → minutes past midnight.
    /// A bare number is rejected as ambiguous.
    static func timeOfDay(_ token: String) -> Int? {
        if token == "noon" || token == "midday" { return 12 * 60 }
        if token == "midnight" { return 0 }

        var body = token
        var meridiem: String?
        // At most one — looping stripped "am" and then "pm" from "3pmam",
        // accepting it as 3pm.
        if let suffix = ["am", "pm"].first(where: { body.hasSuffix($0) }) {
            meridiem = suffix
            body = String(body.dropLast(2))
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        // Without am/pm, a bare number is ambiguous with a day of the month.
        guard parts.count == 2 || meridiem != nil else { return nil }
        guard (1...2).contains(parts[0].count), isAllDigits(parts[0]),
              let hour = Int(parts[0]) else { return nil }

        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, isAllDigits(parts[1]), let parsed = Int(parts[1])
            else { return nil }
            minute = parsed
        }
        guard (0..<60).contains(minute) else { return nil }

        switch meridiem {
        case "am":
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 0 : hour) * 60 + minute
        case "pm":
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 12 : hour + 12) * 60 + minute
        default:
            guard (0...23).contains(hour) else { return nil }
            return hour * 60 + minute
        }
    }

    /// Grafts a wall-clock time onto a day. Built from date components rather
    /// than by adding seconds, so "09:00" stays 09:00 on a DST-transition day.
    private static func instant(minutesPastMidnight minutes: Int,
                                second: Int = 0,
                                on day: Date,
                                calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = second
        let beforeDay = calendar.startOfDay(for: day).addingTimeInterval(-1)
        guard let first = calendar.nextDate(
            after: beforeDay, matching: components, matchingPolicy: .strict,
            repeatedTimePolicy: .first, direction: .forward),
              let last = calendar.nextDate(
                after: beforeDay, matching: components, matchingPolicy: .strict,
                repeatedTimePolicy: .last, direction: .forward),
              first == last,
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first)
                == components
        else { return nil }
        return first
    }
}
