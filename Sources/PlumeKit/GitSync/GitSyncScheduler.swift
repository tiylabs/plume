import Foundation

/// Decides when Git sync runs, and turns what comes back into the one status the menu bar and the
/// Storage tab both show.
///
/// The engine (`GitSyncEngine`, behind `GitSyncCycleRunning`) knows how to do one cycle; this decides
/// *when*.
///
/// **When:** every five minutes, shortly after launch, shortly after the Mac wakes, when asked
/// (*Sync Now*), and on quit — the last of those only commits, because quit must not wait on a
/// network. Cycles never overlap: a request that arrives while one is running is remembered and run
/// right after it, once however many arrived.
///
/// **Quietly:** a timed cycle waits while notes are still being written, so a half-typed sentence is
/// not what gets committed (`GitSyncSchedule`). A person pressing *Sync Now* is not made to wait.
@MainActor
public final class GitSyncScheduler {

    /// Soon after a new target is configured.
    public static let launchDelay: TimeInterval = 3
    /// The network takes a few seconds to come back after wake; asking at once would record a
    /// failure that is no failure.
    public static let wakeDelay: TimeInterval = 8
    /// How long after the vault changes a conflicted vault is re-read, so the dot clears as soon as
    /// the last marker goes without re-reading on every file event.
    public static let conflictRecheckDelay: TimeInterval = 2
    /// How long quit waits for the local commit.
    public static let shutdownTimeout: TimeInterval = 5

    /// The status as it should be shown. `nil` while sync is off.
    public private(set) var status: GitSyncStatus?

    /// Called on the main thread whenever `status` changes.
    public var onStatusChange: ((GitSyncStatus?) -> Void)?

    /// Writes the open note to disk before a cycle reads the folder, so what is committed is what is
    /// on screen — and so a pull never lands on a buffer with unsaved edits.
    public var beforeCycle: (() -> Void)?

    private let scheduler: any Scheduling
    private let makeRunner: (GitSyncTarget) -> any GitSyncCycleRunning
    private let now: () -> Date

    private var target: GitSyncTarget?
    private var runner: (any GitSyncCycleRunning)?
    /// Whether this runner has set up the repository in this process. A fresh target binds first, so
    /// a hand-edited `settings.json` — or a moved vault — works exactly like the Enable button.
    private var prepared = false

    private var tracker = GitSyncFailureTracker()
    private var lastSync: Date?
    private var running = false
    private var requestedWhileRunning = false

    private var ticker: (any Cancellable)?
    private var lastVaultActivity = Date.distantPast
    private var postponements = 0
    private var recheck: (any Cancellable)?

    public init(
        scheduler: any Scheduling = MainQueueScheduler(),
        now: @escaping () -> Date = { Date() },
        makeRunner: @escaping (GitSyncTarget) -> any GitSyncCycleRunning = { GitSyncEngineRunner(target: $0) }
    ) {
        self.scheduler = scheduler
        self.now = now
        self.makeRunner = makeRunner
    }

    // MARK: - Configuration

    /// Applies the current settings: starts, restarts or stops.
    public func configure(with settings: Settings) {
        guard settings.gitSync.isActive else {
            stop()
            return
        }
        let wanted = GitSyncTarget(
            vault: settings.vaultURL,
            remoteURL: settings.gitSync.remoteURL,
            branch: settings.gitSync.branch
        )
        guard wanted != target else { return }

        target = wanted
        runner = makeRunner(wanted)
        prepared = false
        tracker.reset()
        lastSync = nil
        setStatus(.idle(lastSync: nil))

        ticker?.cancel()
        ticker = scheduler.repeating(every: GitSyncSchedule.interval, tolerance: 30) { [weak self] in
            self?.timedCycle()
        }

        timedCycleSoon(after: Self.launchDelay)
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
        recheck?.cancel()
        target = nil
        runner = nil
        prepared = false
        tracker.reset()
        lastSync = nil
        setStatus(nil)
    }

    // MARK: - Triggers

    /// *Sync Now*, from the menu or the Storage tab. Never postponed.
    public func syncNow() {
        guard runner != nil else { return }
        run()
    }

    /// The Mac woke from sleep.
    public func systemDidWake() {
        timedCycleSoon(after: Self.wakeDelay)
    }

    /// The watcher saw the vault change. Two things hang on it: a timed cycle waits for quiet, and a
    /// vault that is waiting on conflicts is re-read so the dot clears as soon as the last marker
    /// goes.
    public func vaultDidChange() {
        lastVaultActivity = now()
        guard case .conflicts = status else { return }
        recheck?.cancel()
        recheck = scheduler.schedule(after: Self.conflictRecheckDelay) { [weak self] in
            self?.recheckConflicts()
        }
    }

    /// On quit: commit what is there, locally, and leave the push for the next launch.
    public func shutdown() {
        ticker?.cancel()
        guard let runner, prepared else { return }
        runner.snapshot(timeout: Self.shutdownTimeout)
    }

    private func timedCycleSoon(after delay: TimeInterval) {
        scheduler.schedule(after: delay) { [weak self] in self?.timedCycle() }
    }

    private func timedCycle() {
        guard runner != nil else { return }
        // Still being written? Try again in a few seconds — see `GitSyncSchedule`.
        if case .postpone(let delay) = GitSyncSchedule.decide(
            sinceLastActivity: now().timeIntervalSince(lastVaultActivity),
            postponements: postponements
        ) {
            postponements += 1
            timedCycleSoon(after: delay)
            return
        }
        postponements = 0
        run()
    }

    // MARK: - Running

    private func run() {
        guard let runner else { return }
        guard !running else {
            requestedWhileRunning = true
            return
        }
        running = true
        setStatus(.syncing)
        beforeCycle?()

        runner.runCycle(preparing: !prepared) { [weak self] outcome in
            self?.finished(outcome, by: runner)
        }
    }

    private func finished(_ outcome: GitSyncEngine.Outcome, by finishedRunner: any GitSyncCycleRunning) {
        running = false
        // The target changed or sync was switched off while this was running.
        guard finishedRunner === runner else {
            if runner != nil { run() }
            return
        }
        prepared = true

        switch outcome {
        case .synced:
            _ = tracker.record(nil)
            lastSync = now()
            setStatus(.idle(lastSync: lastSync))

        case .conflicts(let files):
            // Not a failure, so the failure count starts over: the network demonstrably works.
            _ = tracker.record(nil)
            setStatus(.conflicts(files))

        case .failed(let failure):
            NSLog("Plume: git sync failed — %@", String(describing: failure))
            if let shown = tracker.record(failure) {
                setStatus(.failed(shown))
            } else {
                // Offline for a cycle or two: stay as we were, and try again at the next tick.
                setStatus(.idle(lastSync: lastSync))
            }
        }

        if requestedWhileRunning {
            requestedWhileRunning = false
            run()
        }
    }

    /// Re-reads conflicted notes without the network. If the last one was just fixed, the merge is
    /// completed and a full cycle pushes it.
    private func recheckConflicts() {
        guard let runner, !running else { return }
        runner.recheckConflicts { [weak self] outcome in
            guard let self, runner === self.runner, !self.running else { return }
            switch outcome {
            case .conflicts(let files): self.setStatus(.conflicts(files))
            case .synced: self.run()
            case .failed(let failure): self.setStatus(.failed(failure))
            }
        }
    }

    private func setStatus(_ new: GitSyncStatus?) {
        guard new != status else { return }
        status = new
        onStatusChange?(new)
    }
}
