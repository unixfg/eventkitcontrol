import Foundation

public enum AlarmParsingError: LocalizedError, Equatable {
    case empty
    case invalid(String)
    case outOfRange(String)
    case duplicate
    case tooMany

    public var errorDescription: String? {
        switch self {
        case .empty: return "Alarm list must not be empty."
        case .invalid: return "Alarm offsets must be finite decimal minute values."
        case .outOfRange: return "Alarm offsets must be within one year of the event."
        case .duplicate: return "Alarm offsets must not contain duplicates."
        case .tooMany: return "At most 64 alarms may be supplied."
        }
    }
}

/// Parses `--alarms` atomically. A malformed component rejects the complete
/// value, so an update can never partially replace or accidentally clear the
/// existing alarms.
public enum AlarmParsing {
    public static let maximumMinutes = 525_600.0
    public static let maximumCount = 64

    private static let decimalRegex = try! NSRegularExpression(
        pattern: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#
    )

    public static func parseRequired(_ string: String) throws -> [Double] {
        guard !string.isEmpty else { throw AlarmParsingError.empty }
        let rawParts = string.split(separator: ",", omittingEmptySubsequences: false)
        guard !rawParts.isEmpty else { throw AlarmParsingError.empty }
        guard rawParts.count <= maximumCount else { throw AlarmParsingError.tooMany }

        var results: [Double] = []
        var seen: Set<Double> = []
        for rawPart in rawParts {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { throw AlarmParsingError.empty }
            let range = NSRange(part.startIndex..<part.endIndex, in: part)
            guard decimalRegex.firstMatch(in: part, range: range)?.range == range,
                  let minutes = Double(part), minutes.isFinite
            else { throw AlarmParsingError.invalid(part) }
            guard abs(minutes) <= maximumMinutes else {
                throw AlarmParsingError.outOfRange(part)
            }

            let seconds: Double
            if part.hasPrefix("+") {
                seconds = minutes * 60
            } else {
                seconds = minutes < 0 ? minutes * 60 : -minutes * 60
            }
            let normalized = seconds == 0 ? 0.0 : seconds
            guard normalized.isFinite else { throw AlarmParsingError.invalid(part) }
            guard seen.insert(normalized).inserted else { throw AlarmParsingError.duplicate }
            results.append(normalized)
        }
        return results
    }
}
