import Foundation

/// Identifies one concrete occurrence in an EventKit recurring series.
///
/// EventKit's `event(withIdentifier:)` returns the first occurrence of a
/// recurring event, so an identifier alone is never sufficient for a safe
/// occurrence-specific mutation. `occurrenceDate` is EventKit's original
/// scheduled occurrence date; `expectedStart` is the start observed by the
/// caller and also finds detached occurrences that have moved.
public struct EventOccurrenceSelector: Equatable, Sendable {
    public let occurrenceDate: Date
    public let expectedStart: Date

    public init(occurrenceDate: Date, expectedStart: Date) {
        self.occurrenceDate = occurrenceDate
        self.expectedStart = expectedStart
    }
}

/// Stable access failures thrown before any EventKit read or mutation.
/// Rendering belongs to the CLI; the core never prints these errors.
public enum EventKitAccessError: LocalizedError, Sendable {
    case timedOut(store: String)
    case system(store: String, message: String)
    case denied(store: String)

    /// Process status expected by the CLI integration: ordinary/system
    /// failures use 1, while a user-denied TCC grant uses 2.
    public var exitStatus: Int32 {
        switch self {
        case .denied: return 2
        case .timedOut, .system: return 1
        }
    }

    public var errorCode: String {
        switch self {
        case .timedOut: return "eventkit_access_timeout"
        case .system: return "eventkit_access_failed"
        case .denied: return "eventkit_permission_denied"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .timedOut(let store):
            return "Timed out waiting for \(store) access."
        case .system(let store, let message):
            return "\(store) access error: \(message)"
        case .denied(let store):
            return "Permission denied for \(store). Please grant access in System Settings > Privacy & Security."
        }
    }
}
