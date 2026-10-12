import AppKit
import PlumeKit

/// Runs Git sync in the background and says how it is going.
///
/// The engine (`GitSyncEngine`) knows how to do one cycle; this decides *when*, and turns what comes
/// back into the one status the menu bar and the Storage tab both show.
///
/// **When:** every five minutes, shortly after launch, shortly after the Mac wakes, when asked
/// (*Sync Now*), and on quit — the last of those only commits, because quit must not wait on a
/// network. Cycles never overlap: a request that arrives while one is running is remembered and run
/// right after it.
///
/// **Quietly:** a timed cycle waits while notes are still being written, so a half-typed sentence is
/// not what gets committed. A person pressing *Sync Now* is not made to wait.
@MainActor
final class GitSyncController {

    private static let interval = GitSyncSchedule.interval

    private let queue = DispatchQueue(label: "com.tiylabs.plume.git-sync", qos: .utility)

    /// The status as it should be shown. `nil` while sync is off.
    private(set) var status: GitSyncStatus?

    /// Called on the main thread whenever `status` changes.
    var onStatusChange: ((GitSyncStatus?) -> Void)?

    /// Writes the open note to disk before a cycle reads the folder, so what is committed is what is
    /// on screen — and so a pull never lands on a buffer with unsaved edits.
    var beforeCycle: (() -> Void)?

    private struct Target: Equatable {
        var vault: URL
        var remoteURL: String
        var branch: String
    }

    private var target: Target?
    private var engine: GitSyncEngine?
    /// Whether this engine has set up the repository in this process. A fresh target binds first, so
    /// a hand-edited `settings.json` — or a moved vault — works exactly like the Enable button.
    private var prepared = false

    private var tracker = GitSyncFailureTracker()
    private var lastSync: Date?
    private var running = false
    private var requestedWhileRunning = false

    private var timer: Timer?
    private var lastVaultActivity = Date.distantPast
    private var postponements = 0
    private var recheckWork: DispatchWorkItem?
    /// Held for the life of the process, which is the life of this object.
    private var wakeObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network takes a few seconds to come back after wake; asking at once would record a
            // failure that is no failure.
            MainActor.assumeIsolated { self?.schedule(after: 8) }
        }
    }

    // MARK: - Configuration

    /// Applies the current settings: starts, restarts or stops.
    func configure(with settings: Settings) {
        guard settings.gitSync.isActive else {
            stop()
            return
        }
        let wanted = Target(
            vault: settings.vaultURL,
            remoteURL: settings.gitSync.remoteURL,
            branch: settings.gitSync.branch
        )
        guard wanted != target else { return }

        target = wanted
        engine = GitSyncEngine(vault: wanted.vault, remoteURL: wanted.remoteURL, branch: wanted.branch)
        prepared = false
        tracker.reset()
        lastSync = nil
        setStatus(.idle(lastSync: nil))

        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timedCycle() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        schedule(after: 3)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        recheckWork?.cancel()
        target = nil
        engine = nil
        prepared = false
        tracker.reset()
        lastSync = nil
        setStatus(nil)
    }

    // MARK: - Triggers

    /// *Sync Now*, from the menu or the Storage tab.
    func syncNow() {
        guard engine != nil else { return }
        run()
    }

    /// The watcher saw the vault change. Two things hang on it: a timed cycle waits for quiet, and a
    /// vault that is waiting on conflicts is re-read so the dot clears as soon as the last marker
    /// goes.
    func vaultDidChange() {
        lastVaultActivity = Date()
        guard case .conflicts = status else { return }
        recheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.recheckConflicts() }
        }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// On quit: commit what is there, locally, and leave the push for the next launch.
    func shutdown() {
        timer?.invalidate()
        guard let engine, prepared else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            engine.snapshot()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }

    private func schedule(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.timedCycle() }
        }
    }

    private func timedCycle() {
        guard engine != nil else { return }
        // Still being written? Try again in a few seconds — see `GitSyncSchedule`.
        if case .postpone(let delay) = GitSyncSchedule.decide(
            sinceLastActivity: Date().timeIntervalSince(lastVaultActivity),
            postponements: postponements
        ) {
            postponements += 1
            schedule(after: delay)
            return
        }
        postponements = 0
        run()
    }

    // MARK: - Running

    private func run() {
        guard let engine else { return }
        guard !running else {
            requestedWhileRunning = true
            return
        }
        running = true
        setStatus(.syncing)
        beforeCycle?()

        let needsPreparation = !prepared
        queue.async { [weak self] in
            // A new target — first launch with sync on, a hand edit, a moved folder — is set up the
            // way the Enable button would: init if needed, point `origin` at the address, merge.
            let outcome: GitSyncEngine.Outcome
            if needsPreparation, !engine.isRepository || engine.existingOrigin() != engine.remoteURL {
                outcome = engine.bind()
            } else {
                outcome = engine.cycle()
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(outcome, engine: engine) }
            }
        }
    }

    private func finished(_ outcome: GitSyncEngine.Outcome, engine finishedEngine: GitSyncEngine) {
        running = false
        // The target changed or sync was switched off while this was running.
        guard finishedEngine === engine else {
            if engine != nil { run() }
            return
        }
        prepared = true

        switch outcome {
        case .synced:
            _ = tracker.record(nil)
            lastSync = Date()
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
        guard let engine, !running else { return }
        queue.async { [weak self] in
            let outcome = engine.recheckConflicts()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, engine === self.engine, !self.running else { return }
                    switch outcome {
                    case .conflicts(let files): self.setStatus(.conflicts(files))
                    case .synced: self.run()
                    case .failed(let failure): self.setStatus(.failed(failure))
                    }
                }
            }
        }
    }

    private func setStatus(_ new: GitSyncStatus?) {
        guard new != status else { return }
        status = new
        onStatusChange?(new)
    }
}
