import CryptoKit
import Foundation

/// When bytes are allowed to hit the disk.
///
/// Decision 10: 500 ms after typing stops, and immediately on dismiss, blur and quit. The debounce
/// keeps a sync daemon from seeing a write per keystroke; the three immediate flushes are the moments
/// that actually matter, because a panel that is summoned and banished constantly is a panel whose
/// content must be safe the instant it goes away.
public enum WritePolicy {

    public static let debounce: TimeInterval = 0.5

    public enum Trigger: Equatable, Sendable {
        case typingStopped
        case dismissed
        case lostFocus
        case quitting
        case noteSwitched
        /// The vault watcher wants a clean file before it reloads.
        case reloadPending

        /// Whether this trigger waits out the debounce or writes now.
        public var isImmediate: Bool {
            switch self {
            case .typingStopped: return false
            case .dismissed, .lostFocus, .quitting, .noteSwitched, .reloadPending: return true
            }
        }
    }

    /// How long to wait before writing, given what prompted it.
    public static func delay(for trigger: Trigger) -> TimeInterval {
        trigger.isImmediate ? 0 : debounce
    }
}
