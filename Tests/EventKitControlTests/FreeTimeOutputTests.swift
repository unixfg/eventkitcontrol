import EventKit
import Foundation
import XCTest
@testable import EventKitControlCore

final class FreeTimeOutputTests: XCTestCase {
    private let start = DateParsing.parse("2026-09-21T09:00:00Z")!
    private let end = DateParsing.parse("2026-09-21T17:00:00Z")!

    private func query() throws -> FreeBusyQuery {
        try FreeBusyQuery(
            from: start, to: end, workingHours: .standard, weekdays: Weekdays.monToFri,
            minimumDurationMinutes: 30, bufferMinutes: 15, roundToMinutes: 15, limit: 20)
    }

    func testAvailabilityAndInvitationStatusDetermineBlocking() {
        for availability in [EKEventAvailability.busy, .tentative, .unavailable, .notSupported] {
            XCTAssertTrue(EventKitManager.blocksTime(
                availability: availability, isAllDay: false, status: .confirmed,
                currentUserDeclined: false, ignoreAllDay: false))
        }
        XCTAssertFalse(EventKitManager.blocksTime(
            availability: .free, isAllDay: false, status: .confirmed,
            currentUserDeclined: false, ignoreAllDay: false))
        XCTAssertFalse(EventKitManager.blocksTime(
            availability: .busy, isAllDay: false, status: .canceled,
            currentUserDeclined: false, ignoreAllDay: false))
        XCTAssertFalse(EventKitManager.blocksTime(
            availability: .busy, isAllDay: false, status: .confirmed,
            currentUserDeclined: true, ignoreAllDay: false))
        XCTAssertTrue(EventKitManager.blocksTime(
            availability: .busy, isAllDay: false, status: .tentative,
            currentUserDeclined: false, ignoreAllDay: false))
    }

    func testAllDayEventsFollowAvailabilityUnlessExplicitlyIgnored() {
        XCTAssertTrue(EventKitManager.blocksTime(
            availability: .busy, isAllDay: true, status: .confirmed,
            currentUserDeclined: false, ignoreAllDay: false))
        XCTAssertFalse(EventKitManager.blocksTime(
            availability: .free, isAllDay: true, status: .confirmed,
            currentUserDeclined: false, ignoreAllDay: false))
        XCTAssertFalse(EventKitManager.blocksTime(
            availability: .busy, isAllDay: true, status: .confirmed,
            currentUserDeclined: false, ignoreAllDay: true))
        XCTAssertTrue(EventKitManager.blocksTime(
            availability: .busy, isAllDay: false, status: .confirmed,
            currentUserDeclined: false, ignoreAllDay: true))
    }

    func testEmptyCalendarSelectionFailsBeforeStoreLookup() throws {
        let selections: [[String]] = [[], [""]]
        for identifiers in selections {
            let result = EventKitManager().findFreeSlots(calendarIDs: identifiers, query: try query())
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.exitStatus, 64)
            XCTAssertEqual(result.toDictionary()["code"] as? String, "invalid_input")
        }
    }

    func testSlotOutputCarriesQueryAndExactBoundariesInBothTimeFormats() throws {
        let slot = TimeSlot(start: start, end: start.addingTimeInterval(90 * 60))
        for format in [TimeFormat.rfc3339, .compact] {
            let output = EventKitManager(timeFormat: format).freeSlotsOutput(
                slots: [slot], query: try query(), busyEventCount: 3, ignoreAllDay: true)
            let result = output.toDictionary()
            XCTAssertEqual(result["status"] as? String, "success")
            XCTAssertEqual(result["count"] as? Int, 1)
            XCTAssertEqual(result["minimumDurationMinutes"] as? Int, 30)
            XCTAssertEqual(result["bufferMinutes"] as? Int, 15)
            XCTAssertEqual(result["roundToMinutes"] as? Int, 15)
            XCTAssertEqual(result["busyEventCount"] as? Int, 3)
            XCTAssertEqual(result["ignoreAllDay"] as? Bool, true)
            XCTAssertEqual(DateParsing.parse(try XCTUnwrap(result["searchedFrom"] as? String)), start)
            XCTAssertEqual(DateParsing.parse(try XCTUnwrap(result["searchedTo"] as? String)), end)
            let rows = try XCTUnwrap(result["slots"] as? [[String: Any]])
            XCTAssertEqual(rows[0]["durationMinutes"] as? Int, 90)
            let renderedStart = try XCTUnwrap(rows[0]["startDate"] as? String)
            XCTAssertEqual(DateParsing.parse(renderedStart), slot.start)
            XCTAssertEqual(DateParsing.parse(try XCTUnwrap(rows[0]["endDate"] as? String)), slot.end)
            XCTAssertNotNil(DateParsing.parseLocalDay(try XCTUnwrap(rows[0]["date"] as? String)))
            if format == .compact {
                XCTAssertNotNil(renderedStart.range(of: #"[+-][0-9]{4}$"#, options: .regularExpression))
            }
        }
    }

    func testCSVAndTextRenderSlotRowsInsteadOfAnEncodedSlotsArray() throws {
        let output = EventKitManager().freeSlotsOutput(
            slots: [TimeSlot(start: start, end: start.addingTimeInterval(3600)),
                    TimeSlot(start: end.addingTimeInterval(-1800), end: end)],
            query: try query(), busyEventCount: 1, ignoreAllDay: false)
        let csv = output.format(.csv)
        XCTAssertEqual(csv.split(separator: "\n").count, 3)
        XCTAssertTrue(csv.contains("durationMinutes"))
        XCTAssertTrue(csv.contains("startDate"))
        XCTAssertFalse(csv.contains("slots"))
        let text = output.format(.text)
        XCTAssertTrue(text.contains("durationMinutes: 60"))
        XCTAssertTrue(text.contains("durationMinutes: 30"))
        XCTAssertFalse(text.contains("slots:"))
    }

    func testNoSlotsIsSuccessfulEmptyOutput() throws {
        let output = EventKitManager().freeSlotsOutput(
            slots: [], query: try query(), busyEventCount: 2, ignoreAllDay: false)
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.toDictionary()["count"] as? Int, 0)
        XCTAssertEqual((output.toDictionary()["slots"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(output.format(.csv), "")
        XCTAssertEqual(output.format(.text), "")
    }
}
