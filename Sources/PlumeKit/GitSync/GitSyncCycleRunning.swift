import Foundation

/// Where a sync points: the folder, the remote, the branch. Two settings that name the same place
/// are the same target, which is how the scheduler tells "settings changed" from "nothing to do".
public struct GitSyncTarget: Equatable, Sendable {
    public var vault: URL
    public var remoteURL: String
    public var branch: String

    public init(vault: URL, remoteURL: String, branch: String) {
        self.vault = vault
        self.remoteURL = remoteURL
        self.branch = branch
    }
}

/// One sync target's worth of Git work, as the scheduler sees it.
///
/// The scheduler decides *when*; this does the work, off the main thread, and answers on it. That
/// split is what lets the scheduler be tested without a repository: a test supplies a runner that
/// records what it was asked and answers when told to.
///
/// A runner is made per target and thrown away with it, so the scheduler can tell a result that
/// belongs to the target it is on from one that arrives late from a target it has left, by identity.
@MainActor
public protocol GitSyncCycleRunning: AnyObject {

    /// One cycle. When `preparing`, the repository may not be set up for this target yet — the
    /// first run in this process — and the runner binds it first, the way the Enable button would:
    /// init if needed, point `origin` at the address, merge. Otherwise it is an ordinary cycle.
    func runCycle(preparing: Bool, completion: @escaping @MainActor (GitSyncEngine.Outcome) -> Void)

    /// Re-reads conflicted notes without touching the network.
    func recheckConflicts(completion: @escaping @MainActor (GitSyncEngine.Outcome) -> Void)

    /// Commits what is there, locally, and returns. Blocks, up to `timeout`, because it is for quit.
    func snapshot(timeout: TimeInterval)
}

/// The real runner: a `GitSyncEngine` on a serial utility queue.
@MainActor
public final class GitSyncEngineRunner: GitSyncCycleRunning {

    /// One queue for every runner, so two engines — an old target and its replacement — never run
    /// Git against the same folder at once.
    private static let queue = DispatchQueue(label: "com.tiylabs.plume.git-sync", qos: .utility)

    private let engine: GitSyncEngine

    public init(target: GitSyncTarget) {
        engine = GitSyncEngine(vault: target.vault, remoteURL: target.remoteURL, branch: target.branch)
    }

    public func runCycle(preparing: Bool, completion: @escaping @MainActor (GitSyncEngine.Outcome) -> Void) {
        let engine = engine
        Self.queue.async {
            let outcome: GitSyncEngine.Outcome
            if preparing, !engine.isRepository || engine.existingOrigin() != engine.remoteURL {
                outcome = engine.bind()
            } else {
                outcome = engine.cycle()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
    }

    public func recheckConflicts(completion: @escaping @MainActor (GitSyncEngine.Outcome) -> Void) {
        let engine = engine
        Self.queue.async {
            let outcome = engine.recheckConflicts()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
    }

    public func snapshot(timeout: TimeInterval) {
        let engine = engine
        let done = DispatchSemaphore(value: 0)
        Self.queue.async {
            engine.snapshot()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }
}
