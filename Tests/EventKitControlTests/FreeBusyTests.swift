import Foundation
import XCTest
@testable import EventKitControlCore

/// WorkingHours parsing tests
///
/// Backs `eventkitcontrol free --working-hours`. The parser is deliberately strict:
/// a value it can't read must return nil so the CLI can reject it, rather
/// than silently searching a window the user didn't ask for.
final class WorkingHoursTests: XCTestCase {

    func testParsesPaddedHHMMRange() {
        let hours = WorkingHours.parse("09:00-17:00")
        XCTAssertEqual(hours, WorkingHours(startMinutes: 540, endMinutes: 1020))
    }

    func testParsesBareHourRange() {
        XCTAssertEqual(WorkingHours.parse("9-17"), WorkingHours(startMinutes: 540, endMinutes: 1020))
    }

    func testParsesMinutes() {
        XCTAssertEqual(WorkingHours.parse("8:30-16:45"),
                       WorkingHours(startMinutes: 510, endMinutes: 1005))
    }

    func testParsesSurroundingWhitespace() {
        XCTAssertEqual(WorkingHours.parse("  09:00 - 17:00 "),
                       WorkingHours(startMinutes: 540, endMinutes: 1020))
    }

    func testParsesAllDayKeywords() {
        for keyword in ["all", "ALL", "any", "24h", "24", "always"] {
            XCTAssertEqual(WorkingHours.parse(keyword), .allDay, "keyword: \(keyword)")
            XCTAssertTrue(WorkingHours.parse(keyword)!.isFullDay)
        }
    }

    func testOvernightRangeSpansMidnight() {
        let hours = WorkingHours.parse("22:00-02:00")!
        XCTAssertEqual(hours, WorkingHours(startMinutes: 1320, endMinutes: 120))
        XCTAssertTrue(hours.spansMidnight)
        XCTAssertFalse(hours.isFullDay)
    }

    func testEndOfDayIsNotTreatedAsOvernight() {
        let hours = WorkingHours.parse("18:00-24:00")!
        XCTAssertEqual(hours.endMinutes, 1440)
        XCTAssertFalse(hours.spansMidnight)
        XCTAssertFalse(hours.isFullDay)  // starts at 18:00, not midnight
    }

    func testMidnightToMidnightIsFullDay() {
        XCTAssertTrue(WorkingHours.parse("00:00-24:00")!.isFullDay)
    }

    func testRejectsMalformedValues() {
        for bad in ["", "9", "9-", "-17", "25:00-17:00", "09:60-17:00", "09:00-09:00",
                    "abc-def", "9:00:00-17:00", "09:00-17:00-19:00"] {
            XCTAssertNil(WorkingHours.parse(bad), "should reject: \(bad)")
        }
    }

    func testStandardDefaultIsNineToFive() {
        XCTAssertEqual(WorkingHours.standard, WorkingHours(startMinutes: 540, endMinutes: 1020))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Weekday parsing tests
///
/// Numbers match `Calendar.component(.weekday:)` — 1 = Sunday … 7 = Saturday —
/// so the parsed set can be compared against a date without a lookup table.
final class WeekdaysTests: XCTestCase {

    func testParsesIndividualDays() {
        XCTAssertEqual(Weekdays.parse("mon,wed,fri"), [2, 4, 6])
    }

    func testParsesLongDayNames() {
        XCTAssertEqual(Weekdays.parse("monday,thursday"), [2, 5])
    }

    func testIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(Weekdays.parse(" MON , Tue "), [2, 3])
    }

    func testParsesKeywords() {
        XCTAssertEqual(Weekdays.parse("weekdays"), Weekdays.monToFri)
        XCTAssertEqual(Weekdays.parse("weekends"), Weekdays.weekend)
        XCTAssertEqual(Weekdays.parse("all"), Weekdays.all)
    }

    func testParsesRange() {
        XCTAssertEqual(Weekdays.parse("mon-fri"), Weekdays.monToFri)
    }

    func testRangeWrapsAroundEndOfWeek() {
        // Fri, Sat, Sun, Mon
        XCTAssertEqual(Weekdays.parse("fri-mon"), [6, 7, 1, 2])
    }

    func testSingleDayRangeIsThatDay() {
        XCTAssertEqual(Weekdays.parse("wed-wed"), [4])
    }

    func testMixesKeywordsRangesAndDays() {
        XCTAssertEqual(Weekdays.parse("weekends,mon-tue"), [1, 7, 2, 3])
    }

    func testRejectsUnknownDay() {
        // A typo must not silently widen the search.
        XCTAssertNil(Weekdays.parse("funday"))
        XCTAssertNil(Weekdays.parse("mon,funday"))
        XCTAssertNil(Weekdays.parse("mon-funday"))
        XCTAssertNil(Weekdays.parse(""))
    }

    func testNameForWeekdayNumber() {
        XCTAssertEqual(Weekdays.name(for: 1), "sunday")
        XCTAssertEqual(Weekdays.name(for: 6), "friday")
    }

    /// The numbering has to agree with Foundation's, or the weekday filter
    /// silently selects the wrong days.
    func testNumbersMatchCalendarWeekdayComponent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 9  // a Monday
        let monday = cal.date(from: components)!
        XCTAssertEqual(cal.component(.weekday, from: monday), Weekdays.parse("mon")!.first)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// FreeBusy tests
///
/// The interval algebra behind `eventkitcontrol free`. Everything is pinned to
/// America/New_York and explicit instants so the results don't move with the
/// machine's clock or zone. March 2026 is used throughout because the 8th is
/// the local spring-forward day, which the DST tests need.
final class FreeBusyTests: XCTestCase {

    private func calendar(in tzID: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tzID)!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int,
                      in cal: Calendar) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = h; components.minute = min
        return cal.date(from: components)!
    }

    /// A slot on 2026-03-11 (a Wednesday), from wallclock hour:minute pairs.
    private func slot(_ startHour: Int, _ startMinute: Int,
                      _ endHour: Int, _ endMinute: Int,
                      day: Int = 11, in cal: Calendar) -> TimeSlot {
        TimeSlot(start: date(2026, 3, day, startHour, startMinute, in: cal),
                 end: date(2026, 3, day, endHour, endMinute, in: cal))
    }

    /// "HH:mm" rendering of a slot's edges, so assertions read like a diary.
    private func wallclock(_ slot: TimeSlot, in cal: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = cal.timeZone
        return "\(formatter.string(from: slot.start))–\(formatter.string(from: slot.end))"
    }

    // MARK: - TimeSlot

    func testDurationMinutesRoundsDown() {
        let cal = calendar()
        let start = date(2026, 3, 11, 9, 0, in: cal)
        XCTAssertEqual(TimeSlot(start: start, end: start.addingTimeInterval(1799)).durationMinutes, 29)
        XCTAssertEqual(TimeSlot(start: start, end: start.addingTimeInterval(1800)).durationMinutes, 30)
    }

    func testIsEmptyForZeroAndNegativeLength() {
        let cal = calendar()
        let instant = date(2026, 3, 11, 9, 0, in: cal)
        XCTAssertTrue(TimeSlot(start: instant, end: instant).isEmpty)
        XCTAssertTrue(TimeSlot(start: instant, end: instant.addingTimeInterval(-60)).isEmpty)
        XCTAssertFalse(TimeSlot(start: instant, end: instant.addingTimeInterval(60)).isEmpty)
    }

    // MARK: - merge

    func testMergeCoalescesOverlappingIntervals() {
        let cal = calendar()
        let merged = FreeBusy.merge([slot(9, 0, 10, 30, in: cal), slot(10, 0, 11, 0, in: cal)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(wallclock(merged[0], in: cal), "03-11 09:00–03-11 11:00")
    }

    func testMergeCoalescesTouchingIntervals() {
        let cal = calendar()
        let merged = FreeBusy.merge([slot(9, 0, 10, 0, in: cal), slot(10, 0, 11, 0, in: cal)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(wallclock(merged[0], in: cal), "03-11 09:00–03-11 11:00")
    }

    func testMergeKeepsDisjointIntervals() {
        let cal = calendar()
        let merged = FreeBusy.merge([slot(9, 0, 10, 0, in: cal), slot(11, 0, 12, 0, in: cal)])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeSortsUnorderedInput() {
        let cal = calendar()
        let merged = FreeBusy.merge([slot(14, 0, 15, 0, in: cal), slot(9, 0, 10, 0, in: cal)])
        XCTAssertEqual(merged.map { wallclock($0, in: cal) },
                       ["03-11 09:00–03-11 10:00", "03-11 14:00–03-11 15:00"])
    }

    /// A short meeting fully inside a long one must not extend it — the naive
    /// "take the latest end" bug would shrink the busy block.
    func testMergeAbsorbsFullyContainedInterval() {
        let cal = calendar()
        let merged = FreeBusy.merge([slot(9, 0, 17, 0, in: cal), slot(10, 0, 11, 0, in: cal)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(wallclock(merged[0], in: cal), "03-11 09:00–03-11 17:00")
    }

    func testMergeDropsZeroLengthIntervals() {
        let cal = calendar()
        XCTAssertEqual(FreeBusy.merge([slot(9, 0, 9, 0, in: cal)]).count, 0)
    }

    func testMergeOfEmptyInputIsEmpty() {
        XCTAssertTrue(FreeBusy.merge([]).isEmpty)
    }

    // MARK: - expand (buffer)

    func testExpandPadsBothSides() {
        let cal = calendar()
        let expanded = FreeBusy.expand([slot(10, 0, 11, 0, in: cal)], byMinutes: 15)
        XCTAssertEqual(wallclock(expanded[0], in: cal), "03-11 09:45–03-11 11:15")
    }

    func testExpandByZeroIsIdentity() {
        let cal = calendar()
        let original = [slot(10, 0, 11, 0, in: cal)]
        XCTAssertEqual(FreeBusy.expand(original, byMinutes: 0), original)
        XCTAssertEqual(FreeBusy.expand(original, byMinutes: -5), original)
    }

    // MARK: - subtract

    func testSubtractNothingReturnsWholeWindow() {
        let cal = calendar()
        let window = slot(9, 0, 17, 0, in: cal)
        XCTAssertEqual(FreeBusy.subtract([], from: window), [window])
    }

    func testSubtractCarvesGapsAroundMeetings() {
        let cal = calendar()
        let free = FreeBusy.subtract(
            FreeBusy.merge([slot(10, 0, 11, 0, in: cal), slot(13, 0, 14, 0, in: cal)]),
            from: slot(9, 0, 17, 0, in: cal))
        XCTAssertEqual(free.map { wallclock($0, in: cal) }, [
            "03-11 09:00–03-11 10:00",
            "03-11 11:00–03-11 13:00",
            "03-11 14:00–03-11 17:00",
        ])
    }

    func testSubtractFullyBookedWindowLeavesNothing() {
        let cal = calendar()
        XCTAssertTrue(FreeBusy.subtract([slot(8, 0, 18, 0, in: cal)],
                                        from: slot(9, 0, 17, 0, in: cal)).isEmpty)
    }

    func testSubtractClipsMeetingsOverhangingTheWindow() {
        let cal = calendar()
        let free = FreeBusy.subtract([slot(8, 0, 10, 0, in: cal), slot(16, 0, 18, 0, in: cal)],
                                     from: slot(9, 0, 17, 0, in: cal))
        XCTAssertEqual(free.map { wallclock($0, in: cal) }, ["03-11 10:00–03-11 16:00"])
    }

    func testSubtractIgnoresMeetingsOutsideTheWindow() {
        let cal = calendar()
        let window = slot(9, 0, 17, 0, in: cal)
        let free = FreeBusy.subtract([slot(6, 0, 7, 0, in: cal), slot(19, 0, 20, 0, in: cal)],
                                     from: window)
        XCTAssertEqual(free, [window])
    }

    func testSubtractFromEmptyWindowIsEmpty() {
        let cal = calendar()
        XCTAssertTrue(FreeBusy.subtract([], from: slot(9, 0, 9, 0, in: cal)).isEmpty)
    }

    // MARK: - windows

    func testWindowsProduceOneWindowPerMatchingDay() {
        let cal = calendar()
        // Mon 2026-03-09 through Sun 2026-03-15.
        let windows = FreeBusy.windows(from: date(2026, 3, 9, 0, 0, in: cal),
                                       to: date(2026, 3, 16, 0, 0, in: cal),
                                       workingHours: .standard,
                                       weekdays: Weekdays.monToFri,
                                       calendar: cal)
        XCTAssertEqual(windows.count, 5)
        XCTAssertEqual(wallclock(windows[0], in: cal), "03-09 09:00–03-09 17:00")
        XCTAssertEqual(wallclock(windows[4], in: cal), "03-13 09:00–03-13 17:00")
    }

    func testWindowsClipToTheSearchRange() {
        let cal = calendar()
        // Starting mid-morning: the first window opens at "now", not 09:00.
        let windows = FreeBusy.windows(from: date(2026, 3, 11, 11, 30, in: cal),
                                       to: date(2026, 3, 11, 15, 0, in: cal),
                                       workingHours: .standard,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.map { wallclock($0, in: cal) }, ["03-11 11:30–03-11 15:00"])
    }

    func testWindowsSkipDaysAlreadyPastTheirWorkingHours() {
        let cal = calendar()
        let windows = FreeBusy.windows(from: date(2026, 3, 11, 19, 0, in: cal),
                                       to: date(2026, 3, 12, 12, 0, in: cal),
                                       workingHours: .standard,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.map { wallclock($0, in: cal) }, ["03-12 09:00–03-12 12:00"])
    }

    func testWindowsForFullDayHoursCoverWholeDays() {
        let cal = calendar()
        let windows = FreeBusy.windows(from: date(2026, 3, 11, 0, 0, in: cal),
                                       to: date(2026, 3, 13, 0, 0, in: cal),
                                       workingHours: .allDay,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.map { wallclock($0, in: cal) },
                       ["03-11 00:00–03-12 00:00", "03-12 00:00–03-13 00:00"])
    }

    /// An overnight window that opened *before* the search range still counts
    /// for the part that falls inside it.
    func testWindowsHandleOvernightHours() {
        let cal = calendar()
        let windows = FreeBusy.windows(from: date(2026, 3, 2, 0, 0, in: cal),
                                       to: date(2026, 3, 4, 0, 0, in: cal),
                                       workingHours: WorkingHours.parse("22:00-02:00")!,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.map { wallclock($0, in: cal) }, [
            "03-02 00:00–03-02 02:00",  // tail of Sunday night's window
            "03-02 22:00–03-03 02:00",
            "03-03 22:00–03-04 00:00",  // clipped by the range end
        ])
    }

    func testWindowsAreEmptyForInvertedRange() {
        let cal = calendar()
        XCTAssertTrue(FreeBusy.windows(from: date(2026, 3, 12, 0, 0, in: cal),
                                       to: date(2026, 3, 11, 0, 0, in: cal),
                                       calendar: cal).isEmpty)
    }

    func testWindowsAreEmptyWhenNoWeekdaysSelected() {
        let cal = calendar()
        XCTAssertTrue(FreeBusy.windows(from: date(2026, 3, 9, 0, 0, in: cal),
                                       to: date(2026, 3, 16, 0, 0, in: cal),
                                       weekdays: [],
                                       calendar: cal).isEmpty)
    }

    /// 2026-03-08 is the local spring-forward day (02:00 → 03:00). Building the
    /// window by adding 540 minutes to midnight would land at 10:00; wall-clock
    /// resolution keeps it at 09:00.
    func testWindowsHonourWallClockAcrossSpringForward() {
        let cal = calendar()
        let windows = FreeBusy.windows(from: date(2026, 3, 8, 0, 0, in: cal),
                                       to: date(2026, 3, 9, 0, 0, in: cal),
                                       workingHours: .standard,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(cal.component(.hour, from: windows[0].start), 9)
        XCTAssertEqual(cal.component(.hour, from: windows[0].end), 17)
    }

    /// The short day really is 23 hours long — a full-day window must reflect
    /// that rather than assuming 86 400 seconds.
    func testFullDayWindowIsShortOnSpringForward() {
        let cal = calendar()
        let windows = FreeBusy.windows(from: date(2026, 3, 8, 0, 0, in: cal),
                                       to: date(2026, 3, 9, 0, 0, in: cal),
                                       workingHours: .allDay,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows[0].end.timeIntervalSince(windows[0].start), 23 * 3600, accuracy: 1)
    }

    // MARK: - roundStartUp

    func testRoundStartUpMovesToNextQuarterHour() {
        let cal = calendar()
        let rounded = FreeBusy.roundStartUp(slot(10, 7, 12, 0, in: cal),
                                            toMultipleOfMinutes: 15, calendar: cal)
        XCTAssertEqual(wallclock(rounded!, in: cal), "03-11 10:15–03-11 12:00")
    }

    func testRoundStartUpLeavesAlignedStartsAlone() {
        let cal = calendar()
        let aligned = slot(10, 30, 12, 0, in: cal)
        XCTAssertEqual(FreeBusy.roundStartUp(aligned, toMultipleOfMinutes: 30, calendar: cal), aligned)
    }

    func testRoundStartUpByZeroIsIdentity() {
        let cal = calendar()
        let original = slot(10, 7, 12, 0, in: cal)
        XCTAssertEqual(FreeBusy.roundStartUp(original, toMultipleOfMinutes: 0, calendar: cal), original)
    }

    func testRoundStartUpDropsSlotItWouldConsume() {
        let cal = calendar()
        XCTAssertNil(FreeBusy.roundStartUp(slot(10, 50, 10, 55, in: cal),
                                           toMultipleOfMinutes: 60, calendar: cal))
    }

    // MARK: - slots (end to end)

    func testSlotsFindsGapsAroundADayOfMeetings() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(10, 0, 11, 0, in: cal), slot(13, 0, 14, 0, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            minimumDurationMinutes: 30,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-11 09:00–03-11 10:00",
            "03-11 11:00–03-11 13:00",
            "03-11 14:00–03-11 17:00",
        ])
        XCTAssertEqual(found.map(\.durationMinutes), [60, 120, 180])
    }

    func testSlotsDropsGapsShorterThanTheRequestedDuration() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(10, 0, 11, 0, in: cal), slot(13, 0, 14, 0, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            minimumDurationMinutes: 90,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-11 11:00–03-11 13:00",
            "03-11 14:00–03-11 17:00",
        ])
    }

    func testSlotsAppliesBufferAroundMeetings() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(10, 0, 11, 0, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            minimumDurationMinutes: 15,
            bufferMinutes: 15,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-11 09:00–03-11 09:45",
            "03-11 11:15–03-11 17:00",
        ])
    }

    func testSlotsRoundsStartsWhenAsked() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(10, 0, 10, 20, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            minimumDurationMinutes: 30,
            roundToMinutes: 30,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-11 09:00–03-11 10:00",
            "03-11 10:30–03-11 17:00",
        ])
    }

    /// The limit counts *returned* slots, and it has to bite inside a day. With
    /// an empty busy list every day yields exactly one slot, so such a test
    /// couldn't tell a per-slot limit from a per-day or per-window one; the
    /// gaps here are all within one day, and the sub-minimum first gap must not
    /// count towards the limit.
    func testSlotsStopsAtTheLimitWithinASingleDay() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(9, 20, 10, 0, in: cal), slot(11, 0, 11, 20, in: cal), slot(13, 0, 13, 30, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            minimumDurationMinutes: 30,
            limit: 2,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-11 10:00–03-11 11:00",
            "03-11 11:20–03-11 13:00",
        ])
    }

    func testSlotsStopsAtTheLimitAcrossDays() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [],
            from: date(2026, 3, 9, 0, 0, in: cal),
            to: date(2026, 3, 16, 0, 0, in: cal),
            weekdays: Weekdays.monToFri,
            minimumDurationMinutes: 30,
            limit: 2,
            calendar: cal)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-09 09:00–03-09 17:00",
            "03-10 09:00–03-10 17:00",
        ])
    }

    func testSlotsIgnoresMeetingsOutsideWorkingHours() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(6, 0, 8, 0, in: cal), slot(19, 0, 21, 0, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, ["03-11 09:00–03-11 17:00"])
    }

    func testSlotsSkipsNonSelectedWeekdays() {
        let cal = calendar()
        // Sat 2026-03-14 and Sun 2026-03-15 only.
        let found = FreeBusy.slots(
            busy: [],
            from: date(2026, 3, 14, 0, 0, in: cal),
            to: date(2026, 3, 16, 0, 0, in: cal),
            weekdays: Weekdays.monToFri,
            calendar: cal)
        XCTAssertTrue(found.isEmpty)
    }

    /// Overlapping meetings across two calendars must not produce a phantom
    /// gap between them.
    func testSlotsHandlesOverlappingMeetingsFromSeveralCalendars() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(10, 0, 12, 0, in: cal), slot(11, 0, 13, 0, in: cal), slot(10, 30, 11, 30, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            minimumDurationMinutes: 30,
            calendar: cal)
        XCTAssertEqual(found.map { wallclock($0, in: cal) }, [
            "03-11 09:00–03-11 10:00",
            "03-11 13:00–03-11 17:00",
        ])
    }

    func testSlotsAreEmptyWhenEveryDayIsFullyBooked() {
        let cal = calendar()
        let found = FreeBusy.slots(
            busy: [slot(0, 0, 23, 59, in: cal)],
            from: date(2026, 3, 11, 0, 0, in: cal),
            to: date(2026, 3, 12, 0, 0, in: cal),
            weekdays: Weekdays.all,
            calendar: cal)
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Zones whose DST transition lands on midnight

    /// Chile moves the clock at midnight (2026-09-06 00:00 → 01:00), so that
    /// day has no midnight at all. Stepping the day cursor by plain day
    /// addition parks it at 01:00 and leaves it there for every later day,
    /// producing 25-hour full-day windows that overlap their neighbours.
    /// Each window must still be exactly one local day, back to back.
    func testFullDayWindowsDoNotDriftAcrossAMidnightDSTTransition() {
        let cal = calendar(in: "America/Santiago")
        let windows = FreeBusy.windows(from: date(2026, 9, 4, 0, 0, in: cal),
                                       to: date(2026, 9, 10, 0, 0, in: cal),
                                       workingHours: .allDay,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.count, 6)

        for (index, window) in windows.enumerated() {
            // Every window starts at the first instant of its local day — 01:00
            // on the transition day, which has no 00:00.
            XCTAssertEqual(window.start, cal.startOfDay(for: window.start),
                           "window \(index) does not start at local midnight")
            // And runs exactly to the start of the next local day, with no gap
            // or overlap against the following window.
            if index + 1 < windows.count {
                XCTAssertEqual(window.end, windows[index + 1].start,
                               "window \(index) does not abut the next one")
            }
        }

        // The transition day itself is 23 hours long.
        XCTAssertEqual(windows[2].end.timeIntervalSince(windows[2].start), 23 * 3600, accuracy: 1)
    }

    /// The working-hours edges must survive the same transition: 09:00 stays
    /// 09:00 on the day with no midnight.
    func testWorkingHoursSurviveAMidnightDSTTransition() {
        let cal = calendar(in: "America/Santiago")
        let windows = FreeBusy.windows(from: date(2026, 9, 6, 3, 0, in: cal),
                                       to: date(2026, 9, 8, 0, 0, in: cal),
                                       workingHours: .standard,
                                       weekdays: Weekdays.all,
                                       calendar: cal)
        XCTAssertEqual(windows.map { wallclock($0, in: cal) }, [
            "09-06 09:00–09-06 17:00",
            "09-07 09:00–09-07 17:00",
        ])
    }

    // MARK: - Rounding across DST

    /// Rounding on elapsed seconds since midnight rather than the wall clock
    /// puts the start an hour off on a spring-forward day: 09:07 with --round
    /// 45 would come back as 09:15, which isn't a multiple of 45 minutes past
    /// midnight at all.
    func testRoundStartUpUsesWallClockOnSpringForwardDay() {
        let cal = calendar(in: "America/New_York")
        let gap = TimeSlot(start: date(2026, 3, 8, 9, 7, in: cal),
                           end: date(2026, 3, 8, 17, 0, in: cal))
        let rounded = FreeBusy.roundStartUp(gap, toMultipleOfMinutes: 45, calendar: cal)
        XCTAssertEqual(wallclock(rounded!, in: cal), "03-08 09:45–03-08 17:00")
    }

    /// Lord Howe Island shifts by half an hour on 2026-10-04, so after the
    /// transition the elapsed time since midnight trails the wall clock by 30
    /// minutes. Rounding on elapsed seconds would return 10:30 for --round 60
    /// — not a whole hour at all. (A --round of 15 or 30 divides the shift and
    /// so hides the bug; 60 is where the two disagree.)
    func testRoundStartUpHoldsTheGridInAHalfHourDSTZone() {
        let cal = calendar(in: "Australia/Lord_Howe")
        let gap = TimeSlot(start: date(2026, 10, 4, 10, 7, in: cal),
                           end: date(2026, 10, 4, 17, 0, in: cal))
        let rounded = FreeBusy.roundStartUp(gap, toMultipleOfMinutes: 60, calendar: cal)!
        XCTAssertEqual(cal.component(.minute, from: rounded.start), 0)
        XCTAssertEqual(wallclock(rounded, in: cal), "10-04 11:00–10-04 17:00")
    }

    /// A start already on the grid but carrying seconds still has to move up to
    /// the next boundary — otherwise a slot would be reported starting at
    /// 10:00:30.
    func testRoundStartUpAdvancesPastStrayScondsOnAnAlignedStart() {
        let cal = calendar()
        let gap = TimeSlot(start: date(2026, 3, 11, 10, 0, in: cal).addingTimeInterval(30),
                           end: date(2026, 3, 11, 12, 0, in: cal))
        let rounded = FreeBusy.roundStartUp(gap, toMultipleOfMinutes: 15, calendar: cal)
        XCTAssertEqual(wallclock(rounded!, in: cal), "03-11 10:15–03-11 12:00")
    }

    /// Rounding forward out of the day drops the slot rather than wrapping.
    func testRoundStartUpDropsASlotThatRoundsPastMidnight() {
        let cal = calendar()
        let gap = TimeSlot(start: date(2026, 3, 11, 23, 50, in: cal),
                           end: date(2026, 3, 11, 23, 55, in: cal))
        XCTAssertNil(FreeBusy.roundStartUp(gap, toMultipleOfMinutes: 30, calendar: cal))
    }
}

// ─────────────────────────────────────────────────────────────────────────────


final class FreeBusySafetyTests: XCTestCase {
    private func instant(_ value: String) -> Date {
        DateParsing.parse(value)!
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    func testQueryFetchesMeetingsWhoseBuffersCrossBothRangeEdges() throws {
        let query = try FreeBusyQuery(
            from: instant("2026-03-11T09:00:00Z"), to: instant("2026-03-11T10:00:00Z"),
            workingHours: .allDay, weekdays: Weekdays.all, bufferMinutes: 15)
        XCTAssertEqual(query.fetchStart, instant("2026-03-11T08:45:00Z"))
        XCTAssertEqual(query.fetchEnd, instant("2026-03-11T10:15:00Z"))
        let meetings = [
            TimeSlot(start: instant("2026-03-11T08:00:00Z"), end: instant("2026-03-11T08:55:00Z")),
            TimeSlot(start: instant("2026-03-11T10:05:00Z"), end: instant("2026-03-11T11:00:00Z")),
        ]
        let fetched = meetings.filter { $0.start < query.fetchEnd && $0.end > query.fetchStart }
        XCTAssertEqual(fetched.count, 2)
        let slots = FreeBusy.slots(busy: fetched, query: query, calendar: calendar())
        XCTAssertEqual(slots, [TimeSlot(
            start: instant("2026-03-11T09:10:00Z"), end: instant("2026-03-11T09:50:00Z"))])
        XCTAssertEqual(slots.first?.durationMinutes, 40)
    }

    func testFourYearCapAppliesToExpandedFetch() throws {
        let from = instant("2026-01-01T00:00:00Z")
        let maximumSeconds = Double(DateRanges.maximumNextWindowDays) * 86_400
        let to = from.addingTimeInterval(maximumSeconds)
        XCTAssertNoThrow(try FreeBusyQuery(from: from, to: to))
        XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to, bufferMinutes: 1))
        XCTAssertNoThrow(try FreeBusyQuery(
            from: from, to: to.addingTimeInterval(-120), bufferMinutes: 1))
        XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to.addingTimeInterval(1)))
    }

    func testZeroDurationBusyEventStillReceivesRequestedBuffer() throws {
        let from = instant("2026-03-11T09:00:00Z")
        let to = instant("2026-03-11T11:00:00Z")
        let start = instant("2026-03-11T10:00:00Z")
        let busy = [TimeSlot(start: start, end: start)]
        let buffered = try FreeBusyQuery(
            from: from, to: to, workingHours: .allDay, weekdays: Weekdays.all, bufferMinutes: 15)
        XCTAssertEqual(FreeBusy.slots(busy: busy, query: buffered, calendar: calendar()), [
            TimeSlot(start: from, end: instant("2026-03-11T09:45:00Z")),
            TimeSlot(start: instant("2026-03-11T10:15:00Z"), end: to),
        ])
        let unbuffered = try FreeBusyQuery(
            from: from, to: to, workingHours: .allDay, weekdays: Weekdays.all)
        XCTAssertEqual(FreeBusy.slots(busy: busy, query: unbuffered, calendar: calendar()), [
            TimeSlot(start: from, end: to),
        ])
    }

    func testMalformedBusyDataCannotProduceFreeSuggestions() throws {
        let from = instant("2026-03-11T09:00:00Z")
        let to = instant("2026-03-11T11:00:00Z")
        let malformed = [
            TimeSlot(start: to, end: from),
            TimeSlot(start: from, end: Date(timeIntervalSince1970: .infinity)),
            TimeSlot(start: Date(timeIntervalSince1970: .nan), end: to),
        ]
        XCTAssertTrue(FreeBusy.expand(malformed, byMinutes: 15).isEmpty)
        for buffer in [0, 15] {
            let query = try FreeBusyQuery(
                from: from, to: to, workingHours: .allDay, weekdays: Weekdays.all, bufferMinutes: buffer)
            for interval in malformed {
                XCTAssertTrue(FreeBusy.slots(busy: [interval], query: query, calendar: calendar()).isEmpty)
            }
        }
    }

    func testQueryRejectsNumericExtremesAndInvalidValues() {
        let from = instant("2026-03-11T09:00:00Z")
        let to = from.addingTimeInterval(3600)
        for duration in [Int.min, -1, 0, FreeBusyQuery.maximumMinutes + 1, Int.max] {
            XCTAssertThrowsError(try FreeBusyQuery(
                from: from, to: to, minimumDurationMinutes: duration))
        }
        for buffer in [Int.min, -1, FreeBusyQuery.maximumMinutes + 1, Int.max] {
            XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to, bufferMinutes: buffer))
        }
        for rounding in [Int.min, -1, 1441, Int.max] {
            XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to, roundToMinutes: rounding))
        }
        for limit in [Int.min, -1, 0] {
            XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to, limit: limit))
        }
        XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to, weekdays: []))
        XCTAssertThrowsError(try FreeBusyQuery(from: from, to: to, weekdays: [0, 2]))
        XCTAssertThrowsError(try FreeBusyQuery(
            from: from, to: to, workingHours: WorkingHours(startMinutes: Int.min, endMinutes: Int.max)))
        XCTAssertThrowsError(try FreeBusyQuery(from: to, to: from))
        XCTAssertThrowsError(try FreeBusyQuery(from: from, to: from))
    }

    func testQueryRejectsUnsupportedDatesBeforeCalendarArithmetic() {
        let from = instant("2026-03-11T09:00:00Z")
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let unsupported = Date(timeIntervalSince1970: seconds)
            XCTAssertThrowsError(try FreeBusyQuery(from: unsupported, to: from))
            XCTAssertThrowsError(try FreeBusyQuery(from: from, to: unsupported))
            XCTAssertTrue(FreeBusy.windows(from: from, to: unsupported).isEmpty)
        }
        let firstDay = instant("0001-01-01T00:00:00Z")
        XCTAssertThrowsError(try FreeBusyQuery(
            from: firstDay, to: firstDay.addingTimeInterval(3600), bufferMinutes: 1))
    }

    func testMalformedWeekdayTokensAndHoursFailAtomically() {
        for value in ["mon,", ",mon", "mon,,tue", "mon, ,tue", ",", " "] {
            XCTAssertNil(Weekdays.parse(value), value)
        }
        for value in ["24:00-02:00", "24-24", "+9-17", "9-+17", "9:00-17:99",
                      "999999999999999999999-17", "09:00-17:00junk"] {
            XCTAssertNil(WorkingHours.parse(value), value)
        }
    }

    func testFractionalSecondsMoveForwardEvenWhenMinuteIsOnGrid() throws {
        let from = instant("2026-03-11T10:00:00.5Z")
        let gap = TimeSlot(start: from, end: instant("2026-03-11T11:00:00Z"))
        let rounded = try XCTUnwrap(FreeBusy.roundStartUp(
            gap, toMultipleOfMinutes: 15, calendar: calendar()))
        XCTAssertEqual(rounded.start, instant("2026-03-11T10:15:00Z"))
        XCTAssertEqual(rounded.durationMinutes, 45)
    }

    func testRoundingStaysInSecondOccurrenceOfRepeatedHour() throws {
        let gap = TimeSlot(
            start: instant("2026-11-01T01:07:00-05:00"),
            end: instant("2026-11-01T02:00:00-05:00"))
        let rounded = try XCTUnwrap(FreeBusy.roundStartUp(
            gap, toMultipleOfMinutes: 15, calendar: calendar("America/New_York")))
        XCTAssertEqual(rounded.start, instant("2026-11-01T01:15:00-05:00"))
        XCTAssertGreaterThan(rounded.start, gap.start)
    }

    func testRoundingCanReachEarlierWallTimeInRepeatedHour() throws {
        let gap = TimeSlot(
            start: instant("2026-11-01T01:50:00-04:00"),
            end: instant("2026-11-01T02:00:00-05:00"))
        let rounded = try XCTUnwrap(FreeBusy.roundStartUp(
            gap, toMultipleOfMinutes: 30, calendar: calendar("America/New_York")))
        XCTAssertEqual(rounded.start, instant("2026-11-01T01:00:00-05:00"))
        XCTAssertEqual(rounded.durationMinutes, 60)
    }

    func testRoundingSkipsNonexistentSpringForwardTimes() throws {
        let gap = TimeSlot(
            start: instant("2026-03-08T01:50:00-05:00"),
            end: instant("2026-03-08T04:00:00-04:00"))
        let rounded = try XCTUnwrap(FreeBusy.roundStartUp(
            gap, toMultipleOfMinutes: 30, calendar: calendar("America/New_York")))
        XCTAssertEqual(rounded.start, instant("2026-03-08T03:00:00-04:00"))
    }

    func testFullDayWindowIncludesBothOccurrencesOfFallBackHour() throws {
        let from = instant("2026-11-01T00:00:00-04:00")
        let to = instant("2026-11-02T00:00:00-05:00")
        let query = try FreeBusyQuery(from: from, to: to, workingHours: .allDay, weekdays: Weekdays.all)
        let slots = FreeBusy.slots(busy: [], query: query, calendar: calendar("America/New_York"))
        XCTAssertEqual(slots, [TimeSlot(start: from, end: to)])
        XCTAssertEqual(slots.first?.durationMinutes, 25 * 60)
    }

    func testOvernightWindowUsesWeekdayItOpensOn() throws {
        let query = try FreeBusyQuery(
            from: instant("2026-03-14T00:00:00Z"), to: instant("2026-03-14T03:00:00Z"),
            workingHours: try XCTUnwrap(WorkingHours.parse("22:00-02:00")), weekdays: [6])
        XCTAssertEqual(FreeBusy.slots(busy: [], query: query, calendar: calendar()), [TimeSlot(
            start: instant("2026-03-14T00:00:00Z"), end: instant("2026-03-14T02:00:00Z"))])
    }

    func testInvalidPureInputsDoNotTrapOrCreateFreeSlots() {
        let from = instant("2026-03-11T09:00:00Z")
        let to = from.addingTimeInterval(3600)
        let invalid = TimeSlot(start: from, end: Date(timeIntervalSince1970: .infinity))
        XCTAssertTrue(invalid.isEmpty)
        XCTAssertEqual(invalid.durationMinutes, 0)
        XCTAssertTrue(FreeBusy.merge([invalid]).isEmpty)
        XCTAssertNil(FreeBusy.roundStartUp(
            TimeSlot(start: from, end: to), toMultipleOfMinutes: Int.max))
        XCTAssertTrue(FreeBusy.slots(busy: [], from: from, to: to, bufferMinutes: Int.max).isEmpty)
        XCTAssertTrue(FreeBusy.slots(busy: [], from: from, to: to, limit: 0).isEmpty)
    }
}
