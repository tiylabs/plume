import Foundation

/// Mutual exclusion between the agent API's writes and Git sync's work on the working tree.
///
/// A Git cycle commits, then merges — and a merge rewrites note files in place, conflict markers
/// and all. An API write lands through `NSFileCoordinator`, which Git does not take part in, so
/// without this the two could interleave: the API checks the hash, Git's merge replaces the file,
/// the API's atomic replace then discards the merge. The serial vault queue does not help; Git runs
/// on its own queue and as a subprocess.
///
/// So both sides hold this gate around the steps that touch the tree: the API around its check and
/// replace, Git around commit and merge. Fetch and push talk to the network and touch nothing in
/// the tree, so they do not hold it — a slow remote must not stall a save.
///
/// The API side waits a bounded time (`AgentLimits.worktreeGateTimeout`) and answers `NOTE_BUSY`
/// (`syncing`) rather than block the vault queue behind a long merge. Git waits as long as it takes,
/// because an API write is one small file replace.
///
/// Edits typed into the panel do not take the gate: they already pause Git through the scheduler's
/// quiet period and the pre-cycle flush, and adding a lock to the typing path would add latency to
/// the one thing that must never feel slow.
public final class VaultWriteGate: @unchecked Sendable {

    /// The app's one gate. Engines and the vault service take it by default; tests make their own.
    public static let shared = VaultWriteGate()

    private let semaphore = DispatchSemaphore(value: 1)

    public init() {}

    /// Runs `body` holding the gate, waiting at most `timeout`. Returns nil if the wait ran out.
    public func withGate<T>(timeout: TimeInterval, _ body: () throws -> T) rethrows -> T? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        defer { semaphore.signal() }
        return try body()
    }

    /// Runs `body` holding the gate, however long that takes to get.
    public func withGate<T>(_ body: () throws -> T) rethrows -> T {
        semaphore.wait()
        defer { semaphore.signal() }
        return try body()
    }
}
