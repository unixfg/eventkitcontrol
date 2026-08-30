import Foundation
import ArgumentParser

/// JSONOutput provides consistent JSON formatting for all CLI output.
/// All commands output valid JSON for easy scripting and parsing.
public struct JSONOutput {
    private let data: [String: Any]

    public var isError: Bool { data["status"] as? String == "error" }

    public var errorMessage: String? { data["error"] as? String }

    /// The process exit status associated with this result. Successful results
    /// always use zero; errors default to a general operation failure.
    public var exitStatus: Int32 {
        if !isError { return 0 }
        if let number = data["exitCode"] as? NSNumber { return number.int32Value }
        if let number = data["exitCode"] as? Int { return Int32(number) }
        return 1
    }

    private init(_ data: [String: Any]) {
        self.data = data
    }

    /// Creates a success response with the given data
    public static func success(_ data: [String: Any]) -> JSONOutput {
        var output = data
        if output["status"] == nil {
            output["status"] = "success"
        }
        return JSONOutput(output)
    }

    /// Creates a machine-readable error response. `code` is stable for
    /// scripts; `message` remains suitable for humans.
    public static func error(
        _ message: String,
        code: String = "operation_failed",
        exitCode: Int32 = 1
    ) -> JSONOutput {
        return JSONOutput([
            "status": "error",
            "error": message,
            "code": code,
            "exitCode": exitCode
        ])
    }

    /// Converts the output to a JSON string
    public func toJSON() -> String {
        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: OutputFormatter.sanitizeForTerminal(data),
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
            return String(data: jsonData, encoding: .utf8) ?? "{\"error\": \"Failed to encode JSON\"}"
        } catch {
            return "{\"status\": \"error\", \"error\": \"JSON serialization failed: \(error.localizedDescription)\"}"
        }
    }

    /// Converts the JSON output back to a dictionary.
    /// Useful for scripting and testing.
    public func toDictionary() -> [String: Any] {
        guard
            let data = toJSON().data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Serialises the output in the requested format.
    /// CSV and text both *derive* their fields from the same dictionary that
    /// `toJSON()` does, so new fields added to `eventToDict` / `reminderToDict`
    /// / etc. flow through automatically and can't silently lag behind JSON.
    public func format(_ format: OutputFormat) -> String {
        switch format {
        case .json: return toJSON()
        case .csv:  return OutputFormatter.csv(from: data)
        case .text: return OutputFormatter.text(from: data)
        }
    }
}

// MARK: - OutputFormat

public enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json, csv, text

    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }
}

// MARK: - TimeFormat

/// How timestamps are rendered in output (issue #3). The default stays
/// RFC 3339 so existing consumers are untouched; `compact` is the opt-in
/// jq-friendly form, since jq's `strptime` can parse `%z` (`+1100`) but not
/// the colon-separated `%:z` (`+11:00`).
public enum TimeFormat: String, CaseIterable, ExpressibleByArgument {
    /// Colon-separated offset, `Z` for UTC: `2026-03-09T16:00:00+11:00`.
    case rfc3339
    /// Compact offset, never `Z`: `2026-03-09T16:00:00+1100`. UTC renders as
    /// `+0000` so the offset is always numeric for `%z` parsers.
    case compact

    public static var allValueStrings: [String] { Self.allCases.map(\.rawValue) }

    /// `DateFormatter` pattern rendering this form. `XXXXX` emits colon
    /// offsets and `Z`; lowercase `xxxx` emits compact offsets and `+0000`.
    public var dateFormatPattern: String {
        switch self {
        case .rfc3339: return "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        case .compact: return "yyyy-MM-dd'T'HH:mm:ssxxxx"
        }
    }
}

/// Shared options for commands that emit output. Add via `@OptionGroup`.
public struct OutputFormatOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Output format: json (default), csv, or text. CSV and text auto-discover fields from the JSON dictionary, so new fields appear without code changes."
    )
    public var format: OutputFormat = .json

    @Option(
        name: .long,
        help: "Timestamp rendering: rfc3339 (default, +11:00 offsets) or compact (+1100 offsets, parseable by jq strptime's %z)."
    )
    public var timeFormat: TimeFormat = .rfc3339

    public init() {}
}

// MARK: - Formatters (CSV / text)

enum OutputFormatter {
    /// CSV: pick the primary list/item in the dict, flatten each row (nested
    /// objects → dot notation, nested arrays → JSON-encoded cell), then emit
    /// `header\r\nrow\r\nrow…` with RFC 4180 escaping.
    static func csv(from data: [String: Any]) -> String {
        let rows = primaryRows(in: data).map { flatten($0) }
        guard !rows.isEmpty else { return "" }

        let keys = collectKeys(from: rows)
        let header = keys.map(csvEscape).joined(separator: ",")
        let body = rows.map { row -> String in
            keys.map { csvEscape(csvCell(row[$0])) }.joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\r\n")
    }

    /// Text: same row detection as CSV, but each row emits a block of
    /// `key: value` lines, separated by a blank line. Auto-discovered so it
    /// won't drift either.
    static func text(from data: [String: Any]) -> String {
        let rows = primaryRows(in: data).map { flatten($0) }
        guard !rows.isEmpty else { return "" }

        let blocks = rows.map { row -> String in
            row.keys.sorted().map { key in
                "\(visible(key)): \(visible(stringify(row[key])))"
            }.joined(separator: "\n")
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Row detection

    /// Plural keys → return that list as rows.
    /// Singular keys → wrap in a one-element list.
    /// Otherwise → treat the whole dict as a single row.
    static func primaryRows(in data: [String: Any]) -> [[String: Any]] {
        let listKeys = [
            "events", "reminders", "calendars", "reminderLists", "sources", "aliases",
        ]
        for key in listKeys {
            if let list = data[key] as? [[String: Any]] {
                return rowsByAttachingOperationMetadata(
                    list,
                    from: data,
                    excludingPrimaryKey: key
                )
            }
        }
        let itemKeys = ["event", "reminder", "calendar", "source", "alias"]
        for key in itemKeys {
            if let item = data[key] as? [String: Any] {
                return rowsByAttachingOperationMetadata(
                    [item],
                    from: data,
                    excludingPrimaryKey: key
                )
            }
        }
        return [data]
    }

    /// Mutation previews and results carry safety-critical state at the top
    /// level. Preserve it when CSV/text select a nested primary item, otherwise
    /// `dryRun: true, applied: false` disappears and a preview can resemble a
    /// committed mutation. The namespace avoids collisions with item fields.
    private static func rowsByAttachingOperationMetadata(
        _ rows: [[String: Any]],
        from data: [String: Any],
        excludingPrimaryKey primaryKey: String
    ) -> [[String: Any]] {
        guard data["dryRun"] != nil || data["applied"] != nil else { return rows }

        var metadata = data
        metadata.removeValue(forKey: primaryKey)
        guard !metadata.isEmpty else { return rows }

        let primaryRows = rows.isEmpty ? [[:]] : rows
        return primaryRows.map { row in
            var enriched = row
            enriched["operation"] = metadata
            return enriched
        }
    }

    // MARK: - Flatten

    /// Walks `dict`, lifting nested `[String: Any]` into dot-notated keys.
    /// Nested arrays are JSON-encoded into a single cell — preserves the data
    /// for round-tripping without forcing CSV consumers into a multi-row mess.
    static func flatten(_ dict: [String: Any], prefix: String = "") -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                for (nk, nv) in flatten(nested, prefix: fullKey) {
                    result[nk] = nv
                }
            } else if let array = value as? [Any] {
                result[fullKey] = jsonEncode(array)
            } else {
                result[fullKey] = value
            }
        }
        return result
    }

    static func collectKeys(from rows: [[String: Any]]) -> [String] {
        var keys: Set<String> = []
        for row in rows {
            for key in row.keys { keys.insert(key) }
        }
        return keys.sorted()
    }

    // MARK: - Stringification

    static func stringify(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if value is NSNull { return "" }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // NSNumber sometimes wraps Bool — handle above; otherwise stringify
            // without the trailing `.0` that "\(n)" would produce for whole ints.
            if CFNumberIsFloatType(n) {
                return "\(n.doubleValue)"
            }
            return "\(n.int64Value)"
        }
        return "\(value)"
    }

    /// Neutralise spreadsheet formula prefixes. Quoting a CSV field does not
    /// stop Excel and similar applications from evaluating it.
    static func csvCell(_ value: Any?) -> String {
        let rendered = visible(stringify(value))
        guard value is String, !rendered.isEmpty else { return rendered }

        let candidate = rendered.drop(while: { $0.isWhitespace })
        guard let first = candidate.first, "=+-@".contains(first) else {
            return rendered
        }
        return "'" + rendered
    }

    /// Render control and bidirectional formatting characters visibly so a
    /// calendar title cannot inject terminal commands or disguise later text.
    static func visible(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)

        for scalar in string.unicodeScalars {
            let value = scalar.value
            let isC0 = value < 0x20
            let isControl = isC0 || (0x7f...0x9f).contains(value)
            let isBidi = isBidiControl(value)
            if isControl || isBidi {
                result += String(format: "\\u{%04X}", value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// JSON escaping already renders C0 controls safely. Sanitise only the
    /// raw C1 and bidirectional ranges that JSON permits unescaped, preserving
    /// ordinary strings (including newlines) for machine consumers.
    static func sanitizeForTerminal(_ value: Any) -> Any {
        if let string = value as? String { return jsonVisible(string) }
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map {
                (jsonVisible($0.key), sanitizeForTerminal($0.value))
            })
        }
        if let array = value as? [Any] {
            return array.map(sanitizeForTerminal)
        }
        return value
    }

    private static func jsonVisible(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            let value = scalar.value
            let isC1 = (0x7f...0x9f).contains(value)
            let isBidi = isBidiControl(value)
            if isC1 || isBidi {
                result += String(format: "\\u{%04X}", value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Unicode Bidi_Control is a small closed set. These characters can alter
    /// the display order of otherwise harmless text without being visible.
    private static func isBidiControl(_ value: UInt32) -> Bool {
        value == 0x061c
            || value == 0x200e
            || value == 0x200f
            || (0x202a...0x202e).contains(value)
            || (0x2066...0x2069).contains(value)
    }

    static func jsonEncode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return str
    }

    // MARK: - CSV escaping (RFC 4180)

    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - ExitCode Extension

public extension ExitCode {
    static let permissionDenied = ExitCode(rawValue: 2)
}
