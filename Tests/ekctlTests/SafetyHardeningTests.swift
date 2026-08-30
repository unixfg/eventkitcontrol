import Foundation
import EventKit
import XCTest
@testable import ekctlCore

final class StrictDateParsingSafetyTests: XCTestCase {
    func testRejectsCalendarNormalisationAndTrailingInput() {
        XCTAssertNil(DateParsing.parse("2026-02-29T12:00:00Z"))
        XCTAssertNil(DateParsing.parse("2026-04-31T12:00:00Z"))
        XCTAssertNil(DateParsing.parse("2026-01-01T24:00:00Z"))
        XCTAssertNil(DateParsing.parse("2026-01-01T00:60:00Z"))
        XCTAssertNil(DateParsing.parse("2026-01-01T00:00:00Zjunk"))
    }

    func testRejectsInvalidOrUnknownOffsets() {
        XCTAssertNil(DateParsing.parse("2026-01-01T00:00:00+14:01"))
        XCTAssertNil(DateParsing.parse("2026-01-01T00:00:00+99:00"))
        XCTAssertNil(DateParsing.parse("2026-01-01T00:00:00-00:00"))
        XCTAssertNotNil(DateParsing.parse("2026-01-01T00:00:00+14:00"))
    }

    func testFractionPrecisionIsBounded() {
        XCTAssertNotNil(DateParsing.parse("2026-01-01T00:00:00.123456789Z"))
        XCTAssertNil(DateParsing.parse("2026-01-01T00:00:00.1234567890Z"))
    }

    func testLocalDaysAreStrictAndDateOnly() {
        XCTAssertEqual(DateParsing.parseLocalDay("2024-02-29")?.description, "2024-02-29")
        XCTAssertNil(DateParsing.parseLocalDay("2026-02-29"))
        XCTAssertNil(DateParsing.parseLocalDay("2026-1-01"))
        XCTAssertNil(DateParsing.parseLocalDay("2026-01-01T00:00:00Z"))
    }
}

final class AlarmParsingSafetyTests: XCTestCase {
    func testMalformedListFailsAtomically() {
        XCTAssertThrowsError(try AlarmParsing.parseRequired("abc,10"))
        XCTAssertThrowsError(try AlarmParsing.parseRequired("10,,20"))
        XCTAssertNil(AlarmParsing.parse("abc,10"))
    }

    func testRejectsEmptyNonFiniteExponentDuplicateAndExcessiveValues() {
        XCTAssertThrowsError(try AlarmParsing.parseRequired(""))
        XCTAssertThrowsError(try AlarmParsing.parseRequired("NaN"))
        XCTAssertThrowsError(try AlarmParsing.parseRequired("1e3"))
        XCTAssertThrowsError(try AlarmParsing.parseRequired("10,-10"))
        XCTAssertThrowsError(try AlarmParsing.parseRequired("525601"))
    }

    func testCountIsBounded() {
        let value = (0...AlarmParsing.maximumCount).map(String.init).joined(separator: ",")
        XCTAssertThrowsError(try AlarmParsing.parseRequired(value))
    }

    func testSignSemanticsAreExplicit() throws {
        XCTAssertEqual(try AlarmParsing.parseRequired("10,+5,-15"), [-600, 300, -900])
    }

    func testAlarmOutputNamesRawEventKitUnitsAsSeconds() throws {
        let parsed = try AlarmParsing.parseRequired("10")
        let seconds = try XCTUnwrap(parsed.first)
        XCTAssertEqual(seconds, -600)

        let dictionary = EventKitManager().alarmToDict(
            EKAlarm(relativeOffset: seconds)
        )
        XCTAssertEqual(dictionary["offsetSeconds"] as? Double, -600)
        XCTAssertNil(dictionary["offset"])
    }

    func testAlarmReplacementPreviewDisclosesCompleteObjectReplacement() throws {
        let absolute = EKAlarm(
            absoluteDate: Date(timeIntervalSince1970: 1_800_000_000))
        let custom = EKAlarm(relativeOffset: -300)
        custom.soundName = "Ping"
        custom.structuredLocation = EKStructuredLocation(title: "Office")
        custom.proximity = .enter

        let preview = EventKitManager().alarmReplacementPreview(
            existing: [absolute, custom],
            replacementOffsets: [])

        XCTAssertEqual(preview["replacesAllExistingAlarmObjects"] as? Bool, true)
        XCTAssertEqual(preview["existingAlarmCount"] as? Int, 2)
        XCTAssertEqual(preview["replacementAlarmCount"] as? Int, 0)
        XCTAssertEqual((preview["after"] as? [[String: Any]])?.count, 0)

        let before = try XCTUnwrap(preview["before"] as? [[String: Any]])
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before[0]["type"] as? String, "absolute")
        XCTAssertNotNil(before[1]["actionType"] as? String)
        XCTAssertEqual(before[1]["proximity"] as? String, "enter")
        XCTAssertEqual(before[1]["hasStructuredLocation"] as? Bool, true)
        XCTAssertEqual(before[1]["hasSoundActionMetadata"] as? Bool, true)

        let message = try XCTUnwrap(preview["message"] as? String)
        XCTAssertTrue(message.contains("All existing alarm objects"))
        XCTAssertTrue(message.contains("structured-location metadata"))
    }
}

final class InputValidationSafetyTests: XCTestCase {
    private let start = DateParsing.parse("2026-01-01T10:00:00Z")!

    private func parseRecurrence(
        frequency: String? = "weekly",
        interval: String? = nil,
        endCount: String? = nil,
        endDate: String? = nil,
        noEnd: Bool = false,
        days: String? = nil,
        months: String? = nil,
        daysOfMonth: String? = nil,
        weeksOfYear: String? = nil,
        daysOfYear: String? = nil,
        positions: String? = nil
    ) throws -> ParsedRecurrence? {
        try InputValidation.parseRecurrence(
            frequency: frequency,
            interval: interval,
            endCount: endCount,
            endDate: endDate,
            noEnd: noEnd,
            days: days,
            months: months,
            daysOfMonth: daysOfMonth,
            weeksOfYear: weeksOfYear,
            daysOfYear: daysOfYear,
            setPositions: positions,
            allDay: false,
            eventStart: start,
            timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func testRecurrenceRequiresExactlyOneExplicitEndMode() {
        XCTAssertThrowsError(try parseRecurrence())
        XCTAssertThrowsError(try parseRecurrence(endCount: "4", noEnd: true))
        XCTAssertNoThrow(try parseRecurrence(noEnd: true))
    }

    func testMalformedNumericFieldsNeverFallBack() {
        XCTAssertThrowsError(try parseRecurrence(interval: "garbage", noEnd: true))
        XCTAssertThrowsError(try parseRecurrence(interval: "0", noEnd: true))
        XCTAssertThrowsError(try parseRecurrence(endCount: "1x"))
    }

    func testSelectorListsRejectPartialInvalidityAndSemanticDuplicates() {
        XCTAssertThrowsError(try parseRecurrence(noEnd: true, days: ""))
        XCTAssertThrowsError(try parseRecurrence(
            frequency: "yearly", noEnd: true, months: ""))
        XCTAssertThrowsError(try parseRecurrence(noEnd: true, days: "mon,bogus"))
        XCTAssertThrowsError(try parseRecurrence(noEnd: true, days: "mon,monday"))
        XCTAssertThrowsError(try parseRecurrence(
            frequency: "monthly",
            noEnd: true,
            days: "-9223372036854775808mon"
        ))
        XCTAssertThrowsError(try parseRecurrence(
            frequency: "monthly",
            noEnd: true,
            days: "999999999999999999999999mon"
        ))
        XCTAssertThrowsError(
            try parseRecurrence(
                frequency: "yearly", noEnd: true, months: "jan,13"))
    }

    func testIncompatibleSelectorsAreRejected() {
        XCTAssertThrowsError(
            try parseRecurrence(frequency: "daily", noEnd: true, days: "mon"))
        XCTAssertThrowsError(
            try parseRecurrence(
                frequency: "monthly", noEnd: true, days: "mon", daysOfMonth: "1"))
    }

    func testPriorityAndColorAreCanonical() throws {
        XCTAssertEqual(try InputValidation.parsePriority("9"), 9)
        XCTAssertThrowsError(try InputValidation.parsePriority("10"))
        XCTAssertThrowsError(try InputValidation.parsePriority("+1"))
        XCTAssertEqual(try InputValidation.validateHexColor("#aBc123"), "#aBc123")
        XCTAssertThrowsError(try InputValidation.validateHexColor("abc123"))
        XCTAssertThrowsError(try InputValidation.validateHexColor("#abcd"))
    }

    func testIdentifiersRejectEmptyWhitespaceControlsCommasAndExcessiveLength() throws {
        XCTAssertEqual(try InputValidation.validateIdentifier("ABC:123"), "ABC:123")
        for value in ["", " ", " ABC", "ABC ", "ABC,DEF", "ABC\nDEF"] {
            XCTAssertThrowsError(try InputValidation.validateIdentifier(value))
        }
        XCTAssertThrowsError(try InputValidation.validateIdentifier(
            String(repeating: "A", count: 1_025)
        ))
    }
}

final class SafeOutputRenderingTests: XCTestCase {
    func testErrorsCarryStableCodeAndExitStatus() {
        let output = JSONOutput.error("bad input", code: "invalid_input", exitCode: 64)
        let dict = output.toDictionary()
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.exitStatus, 64)
        XCTAssertEqual(dict["code"] as? String, "invalid_input")
        XCTAssertEqual(dict["exitCode"] as? Int, 64)
    }

    func testCSVNeutralisesFormulaStringsButNotNumbers() {
        let output = JSONOutput.success([
            "events": [[
                "a": "=HYPERLINK(\"https://example.invalid\")",
                "b": "  +SUM(1,2)",
                "c": "@cmd",
                "d": "-1",
                "number": -1,
            ]]
        ])
        let csv = output.format(.csv)
        XCTAssertTrue(csv.contains("'=HYPERLINK"))
        XCTAssertTrue(csv.contains("'  +SUM"))
        XCTAssertTrue(csv.contains("'@cmd"))
        XCTAssertTrue(csv.contains("'-1"))
        XCTAssertTrue(csv.contains(",-1") || csv.hasSuffix("-1"))
    }

    func testTextMakesTerminalControlsAndNewlinesVisible() {
        let output = JSONOutput.success([
            "event": ["title": "safe\u{001B}[31m\nnext\u{202E}line\u{200F}\u{061C}"]
        ])
        let text = output.format(.text)
        XCTAssertTrue(text.contains("\\u{001B}"))
        XCTAssertTrue(text.contains("\\u{000A}"))
        XCTAssertTrue(text.contains("\\u{202E}"))
        XCTAssertTrue(text.contains("\\u{200F}"))
        XCTAssertTrue(text.contains("\\u{061C}"))
        XCTAssertFalse(text.contains("\u{001B}"))
    }

    func testJSONPreservesOrdinaryNewlinesAndNeutralisesBidiFormatting() {
        let output = JSONOutput.success(["value": "one\ntwo\u{202E}\u{200F}\u{061C}"])
        let dict = output.toDictionary()
        XCTAssertEqual(
            dict["value"] as? String,
            "one\ntwo\\u{202E}\\u{200F}\\u{061C}"
        )
    }

    func testSourcesAndReminderListsBecomeCSVRows() {
        let sources = JSONOutput.success([
            "sources": [["id": "one"], ["id": "two"]]
        ]).format(.csv)
        XCTAssertEqual(sources.components(separatedBy: "\r\n").count, 3)

        let lists = JSONOutput.success([
            "reminderLists": [["id": "one"], ["id": "two"]]
        ]).format(.csv)
        XCTAssertEqual(lists.components(separatedBy: "\r\n").count, 3)
    }

    func testCSVAndTextPreserveNestedMutationDryRunMetadata() {
        let preview = JSONOutput.success([
            "event": ["id": "EVENT-1", "title": "Preview"],
            "dryRun": true,
            "applied": false,
            "message": "No event was saved.",
            "geocodingWouldRun": true,
            "changes": [
                "title": ["before": "Old", "after": "New"],
            ],
        ])

        let csv = preview.format(.csv)
        XCTAssertTrue(csv.contains("operation.applied"))
        XCTAssertTrue(csv.contains("operation.dryRun"))
        XCTAssertTrue(csv.contains("operation.changes.title.after"))
        XCTAssertTrue(csv.contains("operation.geocodingWouldRun"))
        XCTAssertTrue(csv.contains("false"))
        XCTAssertTrue(csv.contains("true"))

        let text = preview.format(.text)
        XCTAssertTrue(text.contains("operation.applied: false"))
        XCTAssertTrue(text.contains("operation.dryRun: true"))
        XCTAssertTrue(text.contains("operation.message: No event was saved."))
        XCTAssertTrue(text.contains("operation.status: success"))
        XCTAssertTrue(text.contains("operation.changes.title.before: Old"))
        XCTAssertTrue(text.contains("operation.changes.title.after: New"))
        XCTAssertTrue(text.contains("operation.geocodingWouldRun: true"))
    }
}

final class EventKitSafetyModelTests: XCTestCase {
    func testPermissionErrorsHaveStableClassification() {
        let denied = EventKitAccessError.denied(store: "Calendar")
        XCTAssertEqual(denied.errorCode, "eventkit_permission_denied")
        XCTAssertEqual(denied.exitStatus, 2)

        let timeout = EventKitAccessError.timedOut(store: "Calendar")
        XCTAssertEqual(timeout.errorCode, "eventkit_access_timeout")
        XCTAssertEqual(timeout.exitStatus, 1)
    }

    func testEventKitNotAuthorizedNSErrorIsPermissionDenial() {
        let denied = NSError(
            domain: EKErrorDomain,
            code: EKError.Code.eventStoreNotAuthorized.rawValue)
        XCTAssertTrue(EventKitManager.isEventKitPermissionError(denied))

        let unrelated = NSError(
            domain: EKErrorDomain,
            code: EKError.Code.internalFailure.rawValue)
        XCTAssertFalse(EventKitManager.isEventKitPermissionError(unrelated))
        XCTAssertFalse(EventKitManager.isEventKitPermissionError(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
    }

    func testOccurrenceSelectorRequiresBothExactDatesInItsType() {
        let occurrence = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = occurrence.addingTimeInterval(3_600)
        let selector = EventOccurrenceSelector(
            occurrenceDate: occurrence,
            expectedStart: expected)
        XCTAssertEqual(selector.occurrenceDate, occurrence)
        XCTAssertEqual(selector.expectedStart, expected)
    }

    func testAllDayDetachedSelectorRetainsOriginalOccurrenceTimestamp() throws {
        let occurrence = try XCTUnwrap(
            DateParsing.parse("2026-02-12T18:00:00Z"))
        let expectedStart = try XCTUnwrap(
            DateParsing.parse("2026-02-15T00:00:00Z"))

        let dictionary = EventKitManager().occurrenceSelectorToDict(
            occurrenceDate: occurrence,
            expectedStart: expectedStart,
            allDay: true)

        let renderedOccurrence = try XCTUnwrap(dictionary["occurrenceDate"])
        XCTAssertTrue(renderedOccurrence.contains("T"))
        XCTAssertEqual(DateParsing.parse(renderedOccurrence), occurrence)

        let renderedExpectedStart = try XCTUnwrap(dictionary["expectedStart"])
        XCTAssertFalse(renderedExpectedStart.contains("T"))
        XCTAssertNotNil(DateParsing.parseLocalDay(renderedExpectedStart))
    }

    func testRecurringSelectorMisuseIsClassifiedAsInvalidInput() {
        let output = eventKitFailureOutput(
            EventKitManagerError(
                message: "selector misuse",
                classification: .invalidInput
            )
        ).toDictionary()

        XCTAssertEqual(output["status"] as? String, "error")
        XCTAssertEqual(output["code"] as? String, "invalid_input")
        XCTAssertEqual(output["exitCode"] as? Int, 64)
    }

    func testOrdinaryEventKitManagerFailureRemainsOperationFailure() {
        let output = eventKitFailureOutput(
            EventKitManagerError(message: "save failed")
        ).toDictionary()

        XCTAssertEqual(output["code"] as? String, "operation_failed")
        XCTAssertEqual(output["exitCode"] as? Int, 1)
    }

    func testReminderDueComponentsAreGregorianOnNonGregorianSystems() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let instant = try XCTUnwrap(gregorian.date(from: DateComponents(
            year: 2026, month: 8, day: 29, hour: 13, minute: 45, second: 12
        )))

        var islamic = Calendar(identifier: .islamicCivil)
        islamic.timeZone = timeZone
        XCTAssertNotEqual(islamic.component(.year, from: instant), 2026)

        let components = EventKitManager.reminderDueComponents(
            from: instant,
            timeZone: timeZone
        )
        XCTAssertEqual(components.calendar?.identifier, .gregorian)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.timeZone, timeZone)
        XCTAssertEqual(
            try XCTUnwrap(EventKitManager.date(fromReminderDueComponents: components)),
            instant
        )
    }

    func testManagerSelectorBoundsDoNotTrapOnIntMin() {
        XCTAssertFalse(EventKitManager.isValidSignedSelector(
            Int.min,
            absoluteRange: 1...53,
            allowsNegative: true
        ))
        XCTAssertTrue(EventKitManager.isValidSignedSelector(
            -53,
            absoluteRange: 1...53,
            allowsNegative: true
        ))
        XCTAssertFalse(EventKitManager.isValidSignedSelector(
            -1,
            absoluteRange: 1...53,
            allowsNegative: false
        ))
    }
}
