import Foundation

/// What the sync is doing, as the app shows it.
public enum GitSyncStatus: Equatable, Sendable {
    /// Between cycles. `lastSync` is nil until the first one completes in this process.
    case idle(lastSync: Date?)
    case syncing
    /// A merge stopped on files that need a person. Sync is paused until they are resolved.
    case conflicts([String])
    case failed(GitSyncFailure)

    public var isSyncing: Bool { self == .syncing }
}

/// Decides when a failure is worth a red dot.
///
/// A laptop lid closing mid-cycle, a train tunnel, a captive portal: network trouble is the commonest
/// failure by far and the one that fixes itself, so lighting the menu bar for the first one would
/// make the dot mean nothing. Everything else — a revoked key, a missing repository, a locked index —
/// will not fix itself and surfaces on the first occurrence.
public struct GitSyncFailureTracker: Equatable, Sendable {

    /// Three five-minute cycles: about a quarter of an hour offline before it is called a failure.
    public static let transientThreshold = 3

    public private(set) var consecutiveTransient = 0

    public init() {}

    /// Records a cycle's result and returns the failure to show, if any.
    public mutating func record(_ failure: GitSyncFailure?) -> GitSyncFailure? {
        guard let failure else {
            consecutiveTransient = 0
            return nil
        }
        guard failure.isTransient else {
            consecutiveTransient = 0
            return failure
        }
        consecutiveTransient += 1
        return consecutiveTransient >= Self.transientThreshold ? failure : nil
    }

    public mutating func reset() { consecutiveTransient = 0 }
}
