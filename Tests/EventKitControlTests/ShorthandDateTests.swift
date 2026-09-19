import Foundation
import XCTest
@testable import EventKitControlCore

final class RelativeDatesTests: XCTestCase {

    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// Wednesday 2026-03-11, 14:23 local.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 11
        components.hour = 14; components.minute = 23
        return cal.date(from: components)!
    }

    private func parse(_ input: String) -> Date? {
        RelativeDates.parse(input, now: now, calendar: cal)
    }

    /// Full "yyyy-MM-dd HH:mm:ss" in the pinned zone. The year and seconds are
    /// deliberately included: a narrower format let a result two thousand years
    /// off, or one carrying stray seconds, match the expected string.
    private func stamp(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = cal.timeZone
        return formatter.string(from: date)
    }

    // MARK: - now and offsets

    func testNow() {
        XCTAssertEqual(parse("now"), now)
    }

    func testMinuteHourDayAndWeekOffsets() {
        XCTAssertEqual(stamp(parse("+90m")), "2026-03-11 15:53:00")
        XCTAssertEqual(stamp(parse("+2h")), "2026-03-11 16:23:00")
        XCTAssertEqual(stamp(parse("+3d")), "2026-03-14 14:23:00")
        XCTAssertEqual(stamp(parse("+1w")), "2026-03-18 14:23:00")
    }

    func testNegativeOffsets() {
        XCTAssertEqual(stamp(parse("-30m")), "2026-03-11 13:53:00")
        XCTAssertEqual(stamp(parse("-1d")), "2026-03-10 14:23:00")
    }

    func testLongFormOffsetUnits() {
        XCTAssertEqual(stamp(parse("+45minutes")), "2026-03-11 15:08:00")
        XCTAssertEqual(stamp(parse("+2hours")), "2026-03-11 16:23:00")
        XCTAssertEqual(stamp(parse("+2weeks")), "2026-03-25 14:23:00")
    }

    /// Day offsets move the wall clock; hour offsets move real time. On a
    /// fall-back day the two deliberately diverge, and that contract is what
    /// keeps a repeated `--from -1d` walk from drifting an hour. 2026-11-01 in
    /// America/New_York is 25 hours long.
    func testDayAndHourOffsetsDivergeAcrossFallBack() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 1
        components.hour = 0; components.minute = 30
        let duringLongDay = cal.date(from: components)!

        let plusDay = RelativeDates.parse("+1d", now: duringLongDay, calendar: cal)!
        XCTAssertEqual(cal.component(.hour, from: plusDay), 0)
        XCTAssertEqual(cal.component(.minute, from: plusDay), 30)
        XCTAssertEqual(cal.component(.day, from: plusDay), 2)
        XCTAssertEqual(plusDay.timeIntervalSince(duringLongDay), 25 * 3600, accuracy: 1)

        let plusHours = RelativeDates.parse("+24h", now: duringLongDay, calendar: cal)!
        XCTAssertEqual(plusHours.timeIntervalSince(duringLongDay), 24 * 3600, accuracy: 1)
        XCTAssertEqual(cal.component(.day, from: plusHours), 1)
        XCTAssertEqual(cal.component(.hour, from: plusHours), 23)
    }

    func testOffsetsKeepTheClockAcrossDST() {
        // 2026-03-08 is the local spring-forward day. Adding days must move the
        // wall clock by whole days, not by 86 400-second blocks.
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 7
        components.hour = 14; components.minute = 0
        let beforeTransition = cal.date(from: components)!
        let parsed = RelativeDates.parse("+2d", now: beforeTransition, calendar: cal)
        XCTAssertEqual(stamp(parsed), "2026-03-09 14:00:00")
    }

    func testRejectsMalformedOffsets() {
        XCTAssertNil(parse("+3"))       // no unit
        XCTAssertNil(parse("+d"))       // no magnitude
        XCTAssertNil(parse("3d"))       // no sign — could be a time or a date
        XCTAssertNil(parse("+3x"))      // unknown unit
        XCTAssertNil(parse("+3mo"))     // months are deliberately unsupported
    }

    // MARK: - Named days

    func testTodayTomorrowYesterday() {
        XCTAssertEqual(stamp(parse("today")), "2026-03-11 00:00:00")
        XCTAssertEqual(stamp(parse("tomorrow")), "2026-03-12 00:00:00")
        XCTAssertEqual(stamp(parse("yesterday")), "2026-03-10 00:00:00")
    }

    func testBareWeekdayIsTheNextOccurrence() {
        XCTAssertEqual(stamp(parse("fri")), "2026-03-13 00:00:00")
        XCTAssertEqual(stamp(parse("friday")), "2026-03-13 00:00:00")
        // Monday has already passed this week, so it's next week's.
        XCTAssertEqual(stamp(parse("mon")), "2026-03-16 00:00:00")
    }

    /// Said on a Wednesday, a bare "wed" means today — you don't mean a week
    /// away when you say "let's do it Wednesday" on Wednesday morning.
    func testBareWeekdayIncludesToday() {
        XCTAssertEqual(stamp(parse("wed")), "2026-03-11 00:00:00")
    }

    /// "next wednesday" on a Wednesday is the following one, though.
    func testNextWeekdayExcludesToday() {
        XCTAssertEqual(stamp(parse("next wed")), "2026-03-18 00:00:00")
        XCTAssertEqual(stamp(parse("next fri")), "2026-03-13 00:00:00")
    }

    func testLastWeekdayLooksBackwards() {
        XCTAssertEqual(stamp(parse("last fri")), "2026-03-06 00:00:00")
        XCTAssertEqual(stamp(parse("last wed")), "2026-03-04 00:00:00")
    }

    func testNextAndLastWeek() {
        XCTAssertEqual(stamp(parse("next week")), "2026-03-18 00:00:00")
        XCTAssertEqual(stamp(parse("last week")), "2026-03-04 00:00:00")
    }

    // MARK: - Plain dates

    func testPlainDateIsLocalMidnight() {
        XCTAssertEqual(stamp(parse("2026-02-01")), "2026-02-01 00:00:00")
    }

    func testRejectsImpossibleDates() {
        XCTAssertNil(parse("2026-02-31"))
        XCTAssertNil(parse("2026-13-01"))
        XCTAssertNil(parse("2026-00-10"))
        XCTAssertNil(parse("26-02-01"))    // two-digit year
        XCTAssertNil(parse("2026-2-1"))    // unpadded
    }

    // MARK: - Times

    func testTwentyFourHourTimes() {
        XCTAssertEqual(stamp(parse("14:30")), "2026-03-11 14:30:00")
        XCTAssertEqual(stamp(parse("09:00")), "2026-03-11 09:00:00")
        XCTAssertEqual(stamp(parse("00:00")), "2026-03-11 00:00:00")
    }

    func testTwelveHourTimes() {
        XCTAssertEqual(stamp(parse("3pm")), "2026-03-11 15:00:00")
        XCTAssertEqual(stamp(parse("9am")), "2026-03-11 09:00:00")
        XCTAssertEqual(stamp(parse("9:15am")), "2026-03-11 09:15:00")
        XCTAssertEqual(stamp(parse("12pm")), "2026-03-11 12:00:00")
        XCTAssertEqual(stamp(parse("12am")), "2026-03-11 00:00:00")
    }

    func testNoonAndMidnight() {
        XCTAssertEqual(stamp(parse("noon")), "2026-03-11 12:00:00")
        XCTAssertEqual(stamp(parse("midnight")), "2026-03-11 00:00:00")
    }

    /// A bare number could be a time or a day of the month, and guessing wrong
    /// books a meeting three weeks out. It must be rejected, not guessed.
    func testRejectsBareNumberAsTime() {
        XCTAssertNil(parse("9"))
        XCTAssertNil(parse("14"))
    }

    /// Both sides of each guard, not just values well past them: widening
    /// either bound by one would otherwise go unnoticed, and "14:60" would
    /// silently mean 15:00 while "24:00" would mean midnight *tomorrow*.
    func testRejectsOutOfRangeTimes() {
        XCTAssertNil(parse("25:00"))
        XCTAssertNil(parse("24:00"))
        XCTAssertNil(parse("14:75"))
        XCTAssertNil(parse("14:60"))
        XCTAssertNil(parse("13pm"))
        XCTAssertNil(parse("0am"))
        XCTAssertNil(parse("9:5"))  // minutes must be two digits
    }

    func testAcceptsTheTopOfTheRange() {
        XCTAssertEqual(stamp(parse("23:59")), "2026-03-11 23:59:00")
        XCTAssertEqual(stamp(parse("12:59am")), "2026-03-11 00:59:00")
    }

    // MARK: - Day plus time

    func testDayAndTimeCombinations() {
        XCTAssertEqual(stamp(parse("tomorrow 3pm")), "2026-03-12 15:00:00")
        XCTAssertEqual(stamp(parse("today 09:30")), "2026-03-11 09:30:00")
        XCTAssertEqual(stamp(parse("fri 17:00")), "2026-03-13 17:00:00")
        XCTAssertEqual(stamp(parse("2026-02-01 14:30")), "2026-02-01 14:30:00")
        XCTAssertEqual(stamp(parse("yesterday noon")), "2026-03-10 12:00:00")
    }

    func testQualifiedDayAndTime() {
        XCTAssertEqual(stamp(parse("next wed 08:00")), "2026-03-18 08:00:00")
        XCTAssertEqual(stamp(parse("last fri 5pm")), "2026-03-06 17:00:00")
    }

    func testAtIsOptionalFiller() {
        XCTAssertEqual(stamp(parse("tomorrow at 3pm")), "2026-03-12 15:00:00")
        XCTAssertEqual(stamp(parse("next fri at 09:00")), "2026-03-13 09:00:00")
    }

    func testIsCaseInsensitiveAndWhitespaceTolerant() {
        XCTAssertEqual(stamp(parse("TOMORROW 3PM")), "2026-03-12 15:00:00")
        XCTAssertEqual(stamp(parse("Next   Fri")), "2026-03-13 00:00:00")
    }

    /// A time grafted onto a day is built from date components, so it means the
    /// wall clock even on the day the clocks move.
    func testTimeOnADSTTransitionDayIsWallClock() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 7
        components.hour = 10
        let dayBeforeTransition = cal.date(from: components)!
        let parsed = RelativeDates.parse("tomorrow 09:00",
                                         now: dayBeforeTransition, calendar: cal)
        XCTAssertEqual(stamp(parsed), "2026-03-08 09:00:00")
        XCTAssertEqual(cal.component(.hour, from: parsed!), 9)
    }

    // MARK: - Strictness

    /// The meridiem is stripped once, not in a loop — "3pmam" used to lose
    /// "am", then "pm", and parse as 3pm.
    func testRejectsDoubledMeridiem() {
        XCTAssertNil(parse("3pmam"))
        XCTAssertNil(parse("3ampm"))
        XCTAssertNil(parse("12pmam"))
        XCTAssertNil(parse("tomorrow 3pmam"))
    }

    /// A lone am/pm may stand apart, but nothing else is glued together: the
    /// fat-fingered "1 4:30" must not quietly become 14:30.
    func testRejectsWhitespaceInsideATime() {
        XCTAssertNil(parse("1 4:30"))
        XCTAssertNil(parse("9 : 05"))
        XCTAssertNil(parse("tomorrow 1 4:30"))
    }

    func testAllowsMeridiemAsItsOwnToken() {
        XCTAssertEqual(stamp(parse("3 pm")), "2026-03-11 15:00:00")
        XCTAssertEqual(stamp(parse("tomorrow 3 pm")), "2026-03-12 15:00:00")
    }

    /// `Int(_:)` accepts a leading sign and non-ASCII digits, so the components
    /// are checked to be plain ASCII digits first.
    func testRejectsSignedAndNonASCIITimeComponents() {
        XCTAssertNil(parse("+3:30"))
        XCTAssertNil(parse("-3:30"))
        XCTAssertNil(parse("3:+0"))
    }

    /// A garbled magnitude must error rather than resolve to a date in year
    /// 5828963 — or, when Foundation gives up, silently to "now".
    func testRejectsAbsurdOffsetMagnitudes() {
        XCTAssertNil(parse("+9223372036854775807d"))
        XCTAssertNil(parse("+99999999999999999999d"))  // beyond Int
        XCTAssertNil(parse("-10000000d"))
        XCTAssertNil(parse("+99999w"))
    }

    func testAcceptsGenerousButSaneOffsets() {
        XCTAssertNotNil(parse("+3650d"))   // ten years
        XCTAssertNotNil(parse("+520w"))    // ten years
        XCTAssertNotNil(parse("-3650d"))
    }

    // MARK: - Rejections

    func testRejectsUnknownWords() {
        XCTAssertNil(parse("someday"))
        XCTAssertNil(parse("next someday"))
        XCTAssertNil(parse("soon 3pm"))
        XCTAssertNil(parse("march 5 2026"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("tomorrow 3pm extra"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The shorthand must not disturb ISO 8601 parsing: `DateParsing` tries the
/// strict timestamp parser first, so every string that parsed before still parses to
/// exactly the same instant.
final class DateParsingShorthandIntegrationTests: XCTestCase {

    private func fixedNow() -> Date { Date(timeIntervalSince1970: 1_773_246_180) }

    func testISOInputStillWinsAndIsUnchanged() {
        for iso in ["2026-03-09T16:00:00Z", "2026-03-09T16:00:00+11:00",
                    "2026-03-09T16:00:00-0400", "2026-03-09T16:00:00.123Z"] {
            let viaShorthandAwareParser = DateInputContext(now: fixedNow()).parse(iso)
            XCTAssertNotNil(viaShorthandAwareParser, "should still parse: \(iso)")

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let strict = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
            XCTAssertEqual(viaShorthandAwareParser, strict, "instant changed for: \(iso)")
        }
    }

    func testShorthandReachesTheSharedParser() {
        XCTAssertNotNil(DateInputContext(now: fixedNow()).parse("tomorrow"))
        XCTAssertNotNil(DateInputContext(now: fixedNow()).parse("+2h"))
        XCTAssertNotNil(DateInputContext(now: fixedNow()).parse("fri 3pm"))
    }

    func testAcceptedFormatsMentionsBothStyles() {
        XCTAssertTrue(DateParsing.acceptedInputFormats.contains("ISO 8601"))
        XCTAssertTrue(DateParsing.acceptedInputFormats.contains("tomorrow"))
    }

    func testContextReusesOneReferenceInstantForMultipleInputs() throws {
        let now = try XCTUnwrap(DateParsing.parse("2026-03-11T23:59:59.125Z"))
        let context = DateInputContext(now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(context.parse("now"), now)
        XCTAssertEqual(context.parse("+90m"), now.addingTimeInterval(90 * 60))
        XCTAssertEqual(context.parse("today"), DateParsing.parse("2026-03-11T00:00:00Z"))
        XCTAssertEqual(context.parse("tomorrow"), DateParsing.parse("2026-03-12T00:00:00Z"))
    }

    func testContextUsesItsCapturedTimeZone() {
        let context = DateInputContext(
            now: fixedNow(), timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        XCTAssertEqual(context.parse("2026-03-11 9am"),
                       DateParsing.parse("2026-03-11T09:00:00+05:30"))
    }

    func testStrictSelectorsAndAllDayParserStillRejectShorthand() {
        for input in ["now", "today", "tomorrow 3pm", "+2h", "2026-03-11"] {
            XCTAssertNil(DateParsing.parse(input), input)
        }
        for input in ["now", "today", "tomorrow 3pm", "+1d", "2026-03-11T00:00:00Z"] {
            XCTAssertNil(DateParsing.parseLocalDay(input), input)
        }
    }

    func testShorthandDoesNotRescueMalformedTimestamps() {
        let context = DateInputContext(now: fixedNow())
        for input in [
            "2026-02-30T09:00:00Z", "2026-03-11T24:00:00Z",
            "2026-03-11T09:00:00", "2026-03-11T09:00:00Zjunk",
            "2026-03-11T09:00:00-00:00", "2026-03-11T09:00:00+14:01",
            "2026-03-11T09:00:00+1500", " 2026-03-11T09:00:00Z",
        ] {
            XCTAssertNil(context.parse(input), input)
        }
    }
}

final class ShorthandSafetyTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!

    private func context(_ now: String = "2026-03-07T10:00:00-05:00") -> DateInputContext {
        DateInputContext(now: DateParsing.parse(now)!, timeZone: zone)
    }

    func testOnlyAcceptsAtBetweenDayAndTime() {
        for input in [
            "at tomorrow", "tomorrow at", "at now", "now at", "at 3pm",
            "tomorrow at at 3pm", "next at fri 3pm", "tomorrow 3 at pm",
            "tomorrow 3pm at", "at +2h", "at",
        ] {
            XCTAssertNil(context().parse(input), input)
        }
        XCTAssertEqual(context().parse("next fri at 3 pm"),
                       DateParsing.parse("2026-03-13T15:00:00-04:00"))
    }

    func testRejectsNonASCIIDigitsAndLookalikes() {
        for input in ["+٣h", "+３h", "٣pm", "０９:００", "２０２６-03-11", "tomorrow\u{00a0}3pm"] {
            XCTAssertNil(context().parse(input), input)
        }
    }

    func testRejectsNewlinesAndClockTypos() {
        for input in ["tomorrow\n3pm", "tomorrow\r3pm", "009am", "000:00", "14:30:00",
                      "3.5pm", "3:3pm", "3pmam", "3ampm", "3:30 pm extra"] {
            XCTAssertNil(context().parse(input), input)
        }
    }

    func testRejectsNonexistentClockTimes() {
        XCTAssertNil(context().parse("tomorrow 2:30am"))
        XCTAssertNil(context().parse("2026-03-08 02:00"))
        XCTAssertEqual(context().parse("2026-03-08 03:00"),
                       DateParsing.parse("2026-03-08T03:00:00-04:00"))
    }

    func testRejectsRepeatedClockTimesAndAcceptsExplicitOffsets() {
        let context = context("2026-10-31T10:00:00-04:00")
        XCTAssertNil(context.parse("tomorrow 1:30am"))
        XCTAssertNil(context.parse("2026-11-01 01:00"))
        XCTAssertEqual(context.parse("2026-11-01 02:00"),
                       DateParsing.parse("2026-11-01T02:00:00-05:00"))
        XCTAssertEqual(context.parse("2026-11-01T01:30:00-04:00"),
                       DateParsing.parse("2026-11-01T05:30:00Z"))
        XCTAssertEqual(context.parse("2026-11-01T01:30:00-05:00"),
                       DateParsing.parse("2026-11-01T06:30:00Z"))
    }

    func testDayAndWeekOffsetsRejectNonexistentAndRepeatedTargetClocks() {
        XCTAssertNil(context("2026-03-07T02:30:00-05:00").parse("+1d"))
        XCTAssertNil(context("2026-03-01T02:30:00-05:00").parse("+1w"))
        XCTAssertNil(context("2026-03-09T02:30:00-04:00").parse("-1d"))
        XCTAssertNil(context("2026-10-31T01:30:00-04:00").parse("+1d"))
        XCTAssertNil(context("2026-11-08T01:30:00-05:00").parse("-1w"))
    }

    func testElapsedOffsetsCanCrossDSTTransitions() {
        XCTAssertEqual(context("2026-03-08T01:30:00-05:00").parse("+1h"),
                       DateParsing.parse("2026-03-08T03:30:00-04:00"))
        XCTAssertEqual(context("2026-11-01T01:30:00-04:00").parse("+1h"),
                       DateParsing.parse("2026-11-01T01:30:00-05:00"))
    }

    func testDayOffsetsPreserveSecondsAndFraction() {
        XCTAssertEqual(context("2026-03-07T14:23:17.125-05:00").parse("+2d"),
                       DateParsing.parse("2026-03-09T14:23:17.125-04:00"))
    }

    func testHalfHourDSTTransitionsAreAlsoStrict() {
        let context = DateInputContext(
            now: DateParsing.parse("2026-04-01T00:00:00Z")!,
            timeZone: TimeZone(identifier: "Australia/Lord_Howe")!)
        XCTAssertNil(context.parse("2026-04-05 01:45"))
        XCTAssertNil(context.parse("2026-10-04 02:15"))
        XCTAssertEqual(context.parse("2026-10-04 02:30"),
                       DateParsing.parse("2026-10-04T02:30:00+11:00"))
    }

    func testSkippedCivilDateIsRejected() {
        let context = DateInputContext(
            now: DateParsing.parse("2011-12-29T00:00:00-10:00")!,
            timeZone: TimeZone(identifier: "Pacific/Apia")!)
        XCTAssertNil(context.parse("2011-12-30"))
        XCTAssertNil(context.parse("2011-12-30 9am"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Non-Gregorian region calendars
///
/// Every other test in `RelativeDatesTests` injects a Gregorian calendar, but
/// the shipped entry point — `DateInputContext.parse(_:)` — uses
/// a captured time zone independent of the system region calendar. A `yyyy-MM-dd` string always means a *Gregorian* year, so it must
/// resolve to the same instant no matter what the region calendar is.
final class NonGregorianCalendarTests: XCTestCase {

    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    private var now: Date { Date(timeIntervalSince1970: 1_773_246_180) }

    func testPlainDateIsTheSameInstantInEveryRegionCalendar() {
        let reference = RelativeDates.parse("2026-02-01", now: now, calendar: calendar(.gregorian))
        XCTAssertNotNil(reference)

        for identifier in [Calendar.Identifier.buddhist, .japanese, .hebrew, .persian,
                           .islamicUmmAlQura, .republicOfChina, .iso8601, .coptic] {
            XCTAssertEqual(
                RelativeDates.parse("2026-02-01", now: now, calendar: calendar(identifier)),
                reference,
                "plain date drifted under the \(identifier) calendar")
        }
    }

    func testPlainDateWithATimeIsAlsoStable() {
        let reference = RelativeDates.parse("2026-02-01 14:30", now: now,
                                            calendar: calendar(.gregorian))
        XCTAssertNotNil(reference)
        XCTAssertEqual(
            RelativeDates.parse("2026-02-01 14:30", now: now, calendar: calendar(.buddhist)),
            reference)
    }

    /// A plain date must also agree with the ISO 8601 spelling of the same
    /// instant — the README calls the two interchangeable.
    func testPlainDateAgreesWithTheISOSpelling() {
        var sydney = Calendar(identifier: .buddhist)
        sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        XCTAssertEqual(
            RelativeDates.parse("2026-02-01", now: now, calendar: sydney),
            DateParsing.parse("2026-02-01T00:00:00+11:00"))
    }

    func testImpossibleAndSignedDatesAreStillRejected() {
        for bad in ["2026-02-31", "2026-13-01", "0000-01-01", "+026-02-01",
                    "2026-+2-01", "2026-02-+1"] {
            XCTAssertNil(RelativeDates.parse(bad, now: now, calendar: calendar(.gregorian)),
                         "should reject: \(bad)")
        }
    }
}
