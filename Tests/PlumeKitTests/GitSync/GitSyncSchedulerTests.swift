import Foundation
import PlumeKit

/// A runner that does no Git. It records what it was asked and answers only when the test says so,
/// which is what lets a test hold a cycle "in flight" while it makes more requests.
@MainActor
private final class FakeRunner: GitSyncCycleRunning {
    let target: GitSyncTarget
    private(set) var cycles: [Bool] = []          // the `preparing` flag of each cycle started
    private(set) var rechecks = 0
    private(set) var snapshots: [TimeInterval] = []
    private var waiting: [@MainActor (GitSyncEngine.Outcome) -> Void] = []
    private var recheckWaiting: [@MainActor (GitSyncEngine.Outcome) -> Void] = []

    init(target: GitSyncTarget) { self.target = target }

    var inFlight: Int { waiting.count }

    func runCycle(preparing: Bool, completion: @escaping @MainActor (GitSyncEngine.Outcome) -> Void) {
        cycles.append(preparing)
        waiting.append(completion)
    }

    func recheckConflicts(completion: @escaping @MainActor (GitSyncEngine.Outcome) -> Void) {
        rechecks += 1
        recheckWaiting.append(completion)
    }

    func snapshot(timeout: TimeInterval) { snapshots.append(timeout) }

    /// Answers the oldest cycle that has not been answered.
    func finishCycle(_ outcome: GitSyncEngine.Outcome = .synced(.init())) {
        guard !waiting.isEmpty else { Check.expect(false, "no cycle in flight to finish"); return }
        waiting.removeFirst()(outcome)
    }

    func finishRecheck(_ outcome: GitSyncEngine.Outcome) {
        guard !recheckWaiting.isEmpty else { Check.expect(false, "no recheck in flight"); return }
        recheckWaiting.removeFirst()(outcome)
    }
}

@MainActor
private final class Rig {
    let clock = ManualScheduler()
    var runners: [FakeRunner] = []
    var statuses: [GitSyncStatus?] = []
    var beforeCycleCalls = 0
    /// The scheduler is handed this as "now", so quiet-period arithmetic follows the manual clock.
    let epoch = Date(timeIntervalSince1970: 1_000_000)
    lazy var sync: GitSyncScheduler = {
        let s = GitSyncScheduler(
            scheduler: clock,
            now: { [unowned self] in self.epoch.addingTimeInterval(self.clock.now) },
            makeRunner: { [unowned self] target in
                let r = FakeRunner(target: target)
                self.runners.append(r)
                return r
            }
        )
        s.onStatusChange = { [unowned self] in self.statuses.append($0) }
        s.beforeCycle = { [unowned self] in self.beforeCycleCalls += 1 }
        return s
    }()

    /// When the five-minute timer next fires, as a reading of the manual clock.
    private(set) var nextTick: TimeInterval = 0

    /// Moves to `lead` seconds before the next timer tick, so a test can do something in the gap.
    func advanceToJustBeforeTick(by lead: TimeInterval = 1) {
        let delta = nextTick - lead - clock.now
        Check.expect(delta >= 0, "the tick has already passed")
        clock.advance(by: max(0, delta))
    }

    var runner: FakeRunner { runners.last! }
    var totalCycles: Int { runners.reduce(0) { $0 + $1.cycles.count } }

    func settings(remote: String = "git@example.com:me/notes.git", enabled: Bool = true,
                  branch: String = "", vault: String = "/tmp/vault") -> Settings {
        var s = Settings()
        s.gitSync.enabled = enabled
        s.gitSync.remoteURL = remote
        s.gitSync.branch = branch
        s.vaultPath = vault
        return s
    }

    /// A configured, idle scheduler whose first (preparing) cycle has already completed, and whose
    /// vault has been quiet for long enough that nothing is postponed.
    func started() {
        clock.advance(by: 60)
        sync.configure(with: settings())
        nextTick = clock.now + GitSyncSchedule.interval
        clock.advance(by: GitSyncScheduler.launchDelay)
        runner.finishCycle()
        beforeCycleCalls = 0
        statuses = []
    }
}

func runGitSyncSchedulerTests() {
    Check.mainSuite("GitSyncScheduler") {

        Check.mainTest("sync off: configure does nothing and no status is shown") {
            let rig = Rig()
            rig.sync.configure(with: rig.settings(enabled: false))
            rig.sync.configure(with: rig.settings(remote: ""))
            rig.clock.advance(by: 3600)
            Check.equal(rig.runners.count, 0)
            Check.equal(rig.sync.status, nil)
        }

        Check.mainTest("the first cycle starts a few seconds after configuring, and prepares the repository") {
            let rig = Rig()
            rig.clock.advance(by: 60)
            rig.sync.configure(with: rig.settings())
            Check.equal(rig.sync.status, .idle(lastSync: nil))
            Check.equal(rig.runner.cycles, [], "nothing runs the instant sync is switched on")
            rig.clock.advance(by: GitSyncScheduler.launchDelay - 0.1)
            Check.equal(rig.runner.cycles, [])
            rig.clock.advance(by: 0.2)
            Check.equal(rig.runner.cycles, [true], "the first cycle for a target binds it")
            Check.equal(rig.sync.status, .syncing)
            Check.equal(rig.beforeCycleCalls, 1, "the open note is flushed before Git reads the folder")
        }

        Check.mainTest("after the first cycle, later ones no longer prepare") {
            let rig = Rig()
            rig.started()
            rig.clock.advance(by: GitSyncSchedule.interval)
            Check.equal(rig.runner.cycles, [true, false])
        }

        Check.mainTest("a cycle runs every five minutes") {
            let rig = Rig()
            rig.started()
            for expected in 2...4 {
                rig.clock.advance(by: GitSyncSchedule.interval)
                Check.equal(rig.runner.cycles.count, expected)
                rig.runner.finishCycle()
            }
        }

        Check.mainTest("a successful cycle records the time and goes back to idle") {
            let rig = Rig()
            rig.clock.advance(by: 60)
            rig.sync.configure(with: rig.settings())
            rig.clock.advance(by: GitSyncScheduler.launchDelay)
            let at = rig.clock.now
            rig.runner.finishCycle()
            Check.equal(rig.sync.status, .idle(lastSync: rig.epoch.addingTimeInterval(at)))
        }

        Check.mainTest("a request while a cycle runs is remembered and run once, right after it") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            Check.equal(rig.runner.cycles.count, 2)
            // Three more requests while that one is running...
            rig.sync.syncNow(); rig.sync.syncNow(); rig.sync.syncNow()
            Check.equal(rig.runner.cycles.count, 2, "cycles never overlap")
            Check.equal(rig.runner.inFlight, 1)
            // ...are one more cycle, not three.
            rig.runner.finishCycle()
            Check.equal(rig.runner.cycles.count, 3)
            rig.runner.finishCycle()
            Check.equal(rig.runner.cycles.count, 3, "and nothing is left over")
        }

        Check.mainTest("a timed cycle waits while notes are being written; Sync Now does not") {
            let rig = Rig()
            rig.started()
            rig.advanceToJustBeforeTick()
            rig.sync.vaultDidChange()                      // just typed
            rig.clock.advance(by: 1)                       // the tick
            Check.equal(rig.runner.cycles.count, 1, "the tick found the vault busy and put the cycle off")
            rig.sync.syncNow()
            Check.equal(rig.runner.cycles.count, 2, "a person pressing Sync Now is not made to wait")
        }

        Check.mainTest("a busy vault postpones a timed cycle by the quiet period, then runs it once quiet") {
            let rig = Rig()
            rig.started()
            rig.advanceToJustBeforeTick()
            rig.sync.vaultDidChange()
            rig.clock.advance(by: 1)                               // the tick
            Check.equal(rig.runner.cycles.count, 1, "postponed")
            rig.clock.advance(by: GitSyncSchedule.quietPeriod)
            Check.equal(rig.runner.cycles.count, 2, "ran once the vault had been still for the quiet period")
        }

        Check.mainTest("a vault that never goes quiet still syncs, after the postponement limit") {
            let rig = Rig()
            rig.started()
            rig.advanceToJustBeforeTick(by: 0.5)
            var elapsed = 0.0
            // Something writes every second, for far longer than the limit allows waiting.
            while rig.runner.cycles.count < 2, elapsed < 600 {
                rig.sync.vaultDidChange()
                rig.clock.advance(by: 1)
                elapsed += 1
            }
            Check.equal(rig.runner.cycles.count, 2, "it ran despite constant activity")
            Check.expect(elapsed <= GitSyncSchedule.quietPeriod * Double(GitSyncSchedule.maxPostponements) + 2,
                         "and within the postponement budget, not after \(elapsed)s")
        }

        Check.mainTest("waking from sleep schedules a cycle after the network has had time to return") {
            let rig = Rig()
            rig.started()
            rig.sync.systemDidWake()
            rig.clock.advance(by: GitSyncScheduler.wakeDelay - 0.1)
            Check.equal(rig.runner.cycles.count, 1)
            rig.clock.advance(by: 0.2)
            Check.equal(rig.runner.cycles.count, 2)
        }

        Check.mainTest("conflicts are shown, not counted as failures, and stop the failure count") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            rig.runner.finishCycle(.failed(.network))
            rig.sync.syncNow()
            rig.runner.finishCycle(.conflicts(["a.md"]))
            Check.equal(rig.sync.status, .conflicts(["a.md"]))
            // Two more offline cycles must not reach the threshold: the conflict reset the count.
            for _ in 0..<(GitSyncFailureTracker.transientThreshold - 1) {
                rig.sync.syncNow()
                rig.runner.finishCycle(.failed(.network))
            }
            Check.expect(rig.sync.status != .failed(.network), "the count started over after the conflict")
        }

        Check.mainTest("being offline is quiet until the third cycle, then it is a failure") {
            let rig = Rig()
            rig.started()
            for cycle in 1...GitSyncFailureTracker.transientThreshold {
                rig.sync.syncNow()
                rig.runner.finishCycle(.failed(.network))
                if cycle < GitSyncFailureTracker.transientThreshold {
                    Check.equal(rig.sync.status, .idle(lastSync: rig.sync.status.flatMap { s in
                        if case .idle(let t) = s { return t } else { return nil } }),
                        "cycle \(cycle): still idle, not red")
                } else {
                    Check.equal(rig.sync.status, .failed(.network))
                }
            }
        }

        Check.mainTest("a failure that will not fix itself is shown at once") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            rig.runner.finishCycle(.failed(.authenticationFailed))
            Check.equal(rig.sync.status, .failed(.authenticationFailed))
        }

        Check.mainTest("the conflict dot clears when the last marker is fixed, and sync resumes with a full cycle") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            rig.runner.finishCycle(.conflicts(["a.md", "b.md"]))

            rig.sync.vaultDidChange()
            rig.clock.advance(by: GitSyncScheduler.conflictRecheckDelay - 0.1)
            Check.equal(rig.runner.rechecks, 0, "re-reading waits for the burst of file events to settle")
            rig.clock.advance(by: 0.2)
            Check.equal(rig.runner.rechecks, 1)
            rig.runner.finishRecheck(.conflicts(["b.md"]))
            Check.equal(rig.sync.status, .conflicts(["b.md"]), "one file fixed, one to go")

            rig.sync.vaultDidChange()
            rig.clock.advance(by: GitSyncScheduler.conflictRecheckDelay)
            let before = rig.runner.cycles.count
            rig.runner.finishRecheck(.synced(.init()))
            Check.equal(rig.runner.cycles.count, before + 1, "no conflicts left: a full cycle pushes the merge")
        }

        Check.mainTest("vault changes only trigger a recheck while there are conflicts") {
            let rig = Rig()
            rig.started()
            rig.sync.vaultDidChange()
            rig.clock.advance(by: 10)
            Check.equal(rig.runner.rechecks, 0)
        }

        Check.mainTest("quit commits locally, without a network cycle, and only once the repository is set up") {
            let rig = Rig()
            rig.clock.advance(by: 60)
            rig.sync.configure(with: rig.settings())
            rig.sync.shutdown()
            Check.equal(rig.runner.snapshots, [], "no cycle has set the repository up yet: nothing to commit")

            let rig2 = Rig()
            rig2.started()
            rig2.sync.shutdown()
            Check.equal(rig2.runner.snapshots, [GitSyncScheduler.shutdownTimeout])
            Check.equal(rig2.runner.cycles.count, 1, "quit must not start a cycle, which would wait on the network")
            rig2.clock.advance(by: GitSyncSchedule.interval * 2)
            Check.equal(rig2.runner.cycles.count, 1, "and the timer is stopped")
        }

        Check.mainTest("pointing sync somewhere else starts over with a fresh, preparing runner") {
            let rig = Rig()
            rig.started()
            rig.sync.configure(with: rig.settings(remote: "git@example.com:me/other.git"))
            Check.equal(rig.runners.count, 2)
            Check.equal(rig.sync.status, .idle(lastSync: nil), "last sync belonged to the old target")
            rig.clock.advance(by: GitSyncScheduler.launchDelay)
            Check.equal(rig.runner.cycles, [true])
        }

        Check.mainTest("configuring the same target again changes nothing") {
            let rig = Rig()
            rig.started()
            rig.sync.configure(with: rig.settings())
            Check.equal(rig.runners.count, 1)
            rig.clock.advance(by: 30)
            Check.equal(rig.runner.cycles.count, 1)
        }

        Check.mainTest("a cycle that finishes after the target changed is ignored, and the new target runs") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            let old = rig.runner
            rig.sync.configure(with: rig.settings(remote: "git@example.com:me/other.git"))
            let statusBefore = rig.sync.status
            old.finishCycle(.failed(.authenticationFailed))
            Check.expect(rig.sync.status != .failed(.authenticationFailed),
                         "the old target's failure must not show against the new one")
            Check.equal(rig.sync.status, .syncing, "the new target's own cycle started instead")
            Check.equal(rig.runners.last?.cycles.count, 1, "the new target's cycle ran once the old one let go")
            Check.expect(statusBefore != .syncing)
        }

        Check.mainTest("switching sync off while a cycle runs clears the status and ignores the late answer") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            rig.sync.configure(with: rig.settings(enabled: false))
            Check.equal(rig.sync.status, nil)
            rig.runner.finishCycle(.synced(.init()))
            Check.equal(rig.sync.status, nil, "a late result must not bring the status back")
            rig.clock.advance(by: GitSyncSchedule.interval * 2)
            Check.equal(rig.runner.cycles.count, 2, "and the timer stopped")
        }

        Check.mainTest("Sync Now with sync off does nothing") {
            let rig = Rig()
            rig.sync.syncNow()
            Check.equal(rig.runners.count, 0)
        }

        Check.mainTest("status changes are announced once each, never repeated") {
            let rig = Rig()
            rig.started()
            rig.sync.syncNow()
            rig.runner.finishCycle()
            rig.sync.syncNow()
            rig.runner.finishCycle()
            var previous: GitSyncStatus??
            for s in rig.statuses {
                Check.expect(previous == nil || previous! != s, "announced the same status twice")
                previous = .some(s)
            }
        }
    }
}
