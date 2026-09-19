import Darwin
import Foundation
import XCTest

/// Exercise the executable's flag wiring and validation order without requesting
/// Calendar/Reminders access. Every mutation also uses --dry-run as a second
/// guard against a validation regression reaching a live store.
final class FeatureCLITests: XCTestCase {
    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ arguments: [String]) throws -> Result {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            Bundle(for: FeatureCLITests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("eventkitcontrol"),
            root.appendingPathComponent(".build/debug/eventkitcontrol"),
        ]
        let executable = try XCTUnwrap(
            candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
            "Build the CLI with swift build --product eventkitcontrol before running CLI tests."
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkitcontrol-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        // Files avoid pipe-buffer deadlocks when displaying the command's help.
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["EVENTKITCONTROL_CONFIG_DIR"] = temporaryDirectory
            .appendingPathComponent("config", isDirectory: true).path
        environment["TZ"] = "UTC"
        process.environment = environment
        try process.run()

        // A regression that reaches a permission prompt must fail promptly.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("CLI exceeded its validation-only timeout: \(arguments)")
        } else {
            process.waitUntilExit()
        }
        return Result(
            status: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8))
    }

    @discardableResult
    private func assertInvalid(
        _ arguments: [String],
        contains expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let result = try run(arguments)
        XCTAssertEqual(result.status, 64, result.stderr, file: file, line: line)
        XCTAssertEqual(result.stdout, "", file: file, line: line)
        let dictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any],
            file: file, line: line)
        XCTAssertEqual(dictionary["status"] as? String, "error", file: file, line: line)
        XCTAssertEqual(dictionary["code"] as? String, "invalid_input", file: file, line: line)
        XCTAssertEqual(dictionary["exitCode"] as? Int, 64, file: file, line: line)
        let message = try XCTUnwrap(dictionary["error"] as? String, file: file, line: line)
        XCTAssertTrue(message.contains(expectedMessage), message, file: file, line: line)
        return message
    }

    private let freeRange = [
        "free", "--calendar", "TEST-CALENDAR", "--duration", "30",
        "--from", "2026-09-21T09:00:00Z", "--to", "2026-09-21T17:00:00Z",
    ]

    private let addEvent = [
        "add", "event", "--calendar", "TEST-CALENDAR", "--title", "Test",
        "--dry-run",
    ]

    func testFreeHelpIsAvailableWithoutCalendarPermission() throws {
        let result = try run(["free", "--help"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        for flag in [
            "--calendar", "--duration", "--from", "--to", "--days", "--working-hours",
            "--weekdays", "--buffer", "--round", "--limit", "--ignore-all-day", "--format",
        ] {
            XCTAssertTrue(result.stdout.contains(flag), "Help is missing \(flag)")
        }
    }

    func testFreeRejectsMalformedAndNonPositiveDurationBeforePermissions() throws {
        for duration in ["0", "-1", "NaN", "999999999999999999999999"] {
            try assertInvalid([
                "free", "--calendar", "TEST-CALENDAR", "--duration=\(duration)",
            ], contains: ["0", "-1"].contains(duration) ? "Duration" : "--duration")
        }
    }

    func testFreeRejectsInvalidSchedulingConstraintsBeforePermissions() throws {
        for (flag, value, message) in [
            ("--buffer", "-1", "Buffer"),
            ("--round", "-1", "Rounding"),
            ("--limit", "0", "Limit"),
            ("--working-hours", "25:00-26:00", "--working-hours"),
            ("--working-hours", "09:00-09:00", "--working-hours"),
            ("--weekdays", "mon,bogus", "--weekdays"),
        ] {
            try assertInvalid(freeRange + ["\(flag)=\(value)"], contains: message)
        }
    }

    func testFreeRejectsInvalidDayCountsBeforePermissions() throws {
        for days in ["0", "-1", "999999999999999999999999"] {
            try assertInvalid([
                "free", "--calendar", "TEST-CALENDAR", "--duration", "30", "--days=\(days)",
            ], contains: "--days")
        }
    }

    func testFreeRequiresNonemptyCalendarSelectionBeforePermissions() throws {
        for selection in ["", " ", ",", "first,,second"] {
            try assertInvalid([
                "free", "--calendar", selection, "--duration", "30",
                "--from", "2026-09-21T09:00:00Z", "--to", "2026-09-21T17:00:00Z",
            ], contains: "calendar")
        }
    }

    func testFreeAndListKeepTheFourYearQueryLimit() throws {
        for command in [["free", "--duration", "30"], ["list", "events"]] {
            try assertInvalid(command + [
                "--calendar", "TEST-CALENDAR", "--from", "2026-01-01T00:00:00Z",
                "--to", "2031-01-01T00:00:00Z",
            ], contains: "days")
        }
    }

    func testFreeAndListResolveRelativeBoundsAgainstTheSameNow() throws {
        for command in [["free", "--duration", "30"], ["list", "events"]] {
            try assertInvalid(command + [
                "--calendar", "TEST-CALENDAR", "--from", "+90m", "--to", "+90m",
            ], contains: "later than --from")
        }
    }

    func testAddAndUpdateResolveRelativeBoundsAgainstTheSameNow() throws {
        let update = ["update", "event", "TEST-EVENT", "--all-day", "false", "--dry-run"]
        for command in [addEvent, update] {
            try assertInvalid(command + [
                "--start", "+90m", "--end", "+90m",
            ], contains: "--end must be later than --start")
        }
    }

    func testTimedEventCommandsAcceptShorthandBeforeLaterValidation() throws {
        let update = ["update", "event", "TEST-EVENT", "--all-day", "false", "--dry-run"]
        for command in [addEvent, update] {
            for (start, end) in [("tomorrow 9am", "tomorrow 10am"), ("+1h", "+2h")] {
                try assertInvalid(command + [
                    "--start", start, "--end", end, "--alarms", "invalid",
                ], contains: "Invalid --alarms")
            }
        }
    }

    func testReminderCommandsAcceptShorthandBeforeLaterValidation() throws {
        for command in [
            ["add", "reminder", "--list", "TEST-LIST", "--title", "Test", "--dry-run"],
            ["update", "reminder", "TEST-REMINDER", "--dry-run"],
        ] {
            try assertInvalid(command + [
                "--due", "tomorrow 9am", "--priority", "10",
            ], contains: "Invalid --priority")
        }
    }

    func testTimedRecurrenceEndAcceptsShorthandAndRetainsOrderingValidation() throws {
        try assertInvalid(addEvent + [
            "--start", "+2h", "--end", "+3h", "--recurrence-frequency", "daily",
            "--recurrence-end-date", "+1h",
        ], contains: "Recurrence end date must not precede the first event")
    }

    func testValidTimedRecurrenceShorthandReachesCalendarValidation() throws {
        try assertInvalid([
            "add", "event", "--calendar", "", "--title", "Test", "--dry-run",
            "--start", "+1h", "--end", "+2h", "--recurrence-frequency", "daily",
            "--recurrence-end-date", "+1w",
        ], contains: "Invalid --calendar")
    }

    func testNegativeOffsetsWorkWithEqualsSyntaxBeforeLaterValidation() throws {
        try assertInvalid(addEvent + [
            "--start=-2h", "--end=-1h", "--alarms", "invalid",
        ], contains: "Invalid --alarms")
        for command in [["free", "--duration", "30"], ["list", "events"]] {
            try assertInvalid(command + [
                "--calendar", "", "--from=-2h", "--to=-1h",
            ], contains: "calendar")
        }
    }

    func testAllDayDatesAndRecurrenceEndStillRequireDateOnlyInput() throws {
        try assertInvalid(addEvent + [
            "--all-day", "--start", "today", "--end", "tomorrow",
        ], contains: "YYYY-MM-DD")
        try assertInvalid([
            "update", "event", "TEST-EVENT", "--dry-run", "--all-day", "true",
            "--start", "today", "--end", "tomorrow",
        ], contains: "YYYY-MM-DD")
        try assertInvalid(addEvent + [
            "--all-day", "--start", "2026-09-21", "--end", "2026-09-22",
            "--recurrence-frequency", "daily", "--recurrence-end-date", "tomorrow",
        ], contains: "YYYY-MM-DD")
    }

    func testOccurrenceSelectorsRejectShorthandInEveryEventCommand() throws {
        let exact = "2026-09-21T09:00:00Z"
        for command in [
            ["show", "event", "TEST-EVENT"],
            ["update", "event", "TEST-EVENT", "--title", "New title", "--dry-run"],
            ["delete", "event", "TEST-EVENT", "--dry-run"],
        ] {
            try assertInvalid(command + [
                "--occurrence", "tomorrow 9am", "--expected-start", exact,
            ], contains: "Invalid --occurrence")
            try assertInvalid(command + [
                "--occurrence", exact, "--expected-start", "+1h",
            ], contains: "Invalid --expected-start")
        }
    }

    func testShorthandFallbackDoesNotRelaxStrictTimestampValidation() throws {
        for value in ["2026-02-29T09:00:00Z", "2026-09-21T09:00:00Zjunk"] {
            try assertInvalid(addEvent + [
                "--start", value, "--end", "2027-09-21T10:00:00Z",
            ], contains: "Invalid --start")
        }
    }

    func testFreeValidationErrorsRespectEveryOutputFormat() throws {
        for format in ["csv", "text"] {
            let result = try run([
                "free", "--calendar", "TEST-CALENDAR", "--duration", "0", "--format", format,
            ])
            XCTAssertEqual(result.status, 64, result.stderr)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.contains("invalid_input"), result.stderr)
            XCTAssertTrue(result.stderr.contains("Duration"), result.stderr)
            XCTAssertTrue(result.stderr.contains("64"), result.stderr)
        }
    }
}
