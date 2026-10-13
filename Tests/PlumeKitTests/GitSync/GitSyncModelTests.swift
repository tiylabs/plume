import Foundation
import PlumeKit

/// The Git sync types that need no repository: how a failure is classified, the tracker and the menu bar
/// dot, conflict markers and remote addresses, the settings block in `settings.json`, and the schedule.
///
/// `GitSyncTests.swift` holds the main paths of the engine; these are the unhappy-path rules that cost
/// somebody their notes if they regress.
func runGitSyncModelTests() {

    Check.suite("Git sync · more classification") {
        func classify(_ text: String, pushing: Bool = false) -> GitSyncFailure {
            GitSyncFailure.classify(output: text, pushing: pushing)
        }

        Check.test("host key and credential problems are authentication") {
            Check.equal(classify("Host key verification failed."), .authenticationFailed)
            Check.equal(classify("fatal: unable to access 'https://x/': The requested URL returned error: 401"), .authenticationFailed)
            Check.equal(classify("remote: Invalid credentials"), .authenticationFailed)
        }

        Check.test("a server-side refusal on push is a permission problem, not a login one") {
            Check.equal(classify("remote: error: GH006: Protected branch update failed", pushing: true), .noWriteAccess)
            Check.equal(classify(" ! [remote rejected] main -> main (pre-receive hook declined)", pushing: true), .noWriteAccess)
        }

        Check.test("a dropped connection and a TLS failure are network trouble") {
            Check.equal(classify("fatal: the remote end hung up unexpectedly"), .network)
            Check.equal(classify("fatal: unable to access 'https://x/': SSL certificate problem"), .network)
            Check.equal(classify("fatal: unable to access 'https://x/': Failed to connect to x port 443"), .network)
        }

        Check.test("a 404 is a missing repository even though it also says 'unable to access'") {
            Check.equal(
                classify("fatal: unable to access 'https://x/y.git/': The requested URL returned error: 404"),
                .repositoryNotFound
            )
        }

        Check.test("an unfinished merge is a repository-state problem") {
            if case .repositoryState = classify("error: You have not concluded your merge (MERGE_HEAD exists).") {
            } else {
                Check.expect(false, "expected repositoryState")
            }
        }

        Check.test("only network trouble is transient") {
            let all: [GitSyncFailure] = [
                .gitMissing, .authenticationFailed, .noWriteAccess, .network, .repositoryNotFound,
                .branchMissing, .repositoryState("x"), .other("x"),
            ]
            Check.equal(all.filter(\.isTransient), [.network])
        }
    }

    Check.suite("Git sync · more failure tracker and dot") {
        Check.test("a failure that will not cure itself resets the network count") {
            var tracker = GitSyncFailureTracker()
            _ = tracker.record(.network)
            _ = tracker.record(.network)
            Check.equal(tracker.record(.authenticationFailed), .authenticationFailed)
            Check.equal(tracker.consecutiveTransient, 0)
            Check.equal(tracker.record(.network), nil, "the count starts again from one")
        }

        Check.test("reset forgets what has been seen") {
            var tracker = GitSyncFailureTracker()
            _ = tracker.record(.network)
            _ = tracker.record(.network)
            tracker.reset()
            Check.equal(tracker.record(.network), nil)
        }

        Check.test("the dot is clear when nothing is wrong, and says what is") {
            Check.equal(MenuBarDot.resolve(sync: .idle(lastSync: Date()), updateAvailable: false), MenuBarDot.none)
            Check.equal(MenuBarDot.resolve(sync: .syncing, updateAvailable: false), MenuBarDot.none)
            Check.equal(MenuBarDot.resolve(sync: .failed(.network), updateAvailable: false), .failure)
            Check.equal(MenuBarDot.resolve(sync: .conflicts(["a.md"]), updateAvailable: false), .conflict)
            Check.equal(MenuBarDot.resolve(sync: nil, updateAvailable: true), .update)
        }

        Check.test("only the syncing status is syncing") {
            Check.expect(GitSyncStatus.syncing.isSyncing)
            Check.expect(!GitSyncStatus.idle(lastSync: nil).isSyncing)
            Check.expect(!GitSyncStatus.conflicts(["a.md"]).isSyncing)
            Check.expect(!GitSyncStatus.failed(.network).isSyncing)
        }
    }

    Check.suite("Git sync · more conflict markers and addresses") {
        Check.test("Windows line endings do not hide a marker") {
            Check.expect(ConflictMarkers.isPresent(in: "a\r\n<<<<<<<\r\nx\r\n=======\r\ny\r\n>>>>>>>\r\n"))
            Check.expect(!ConflictMarkers.isPresent(in: "Title\r\n=======\r\nbody\r\n"))
            Check.expect(!ConflictMarkers.isPresent(in: ""))
        }

        Check.test("a file is read from disk, and a missing one has no markers") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("plume-markers-\(UUID().uuidString).md")
            defer { try? FileManager.default.removeItem(at: url) }
            Check.expect(!ConflictMarkers.isPresent(inFileAt: url))
            try? "x\n<<<<<<< HEAD\ny\n".write(to: url, atomically: true, encoding: .utf8)
            Check.expect(ConflictMarkers.isPresent(inFileAt: url))
            try? "x\ny\n".write(to: url, atomically: true, encoding: .utf8)
            Check.expect(!ConflictMarkers.isPresent(inFileAt: url))
        }

        Check.test("addresses that look usable but are not") {
            func problem(_ s: String) -> GitRemoteAddress.Problem? { GitRemoteAddress.problem(with: s) }
            Check.equal(problem("git@github.com:"), .unsupported, "no path")
            Check.equal(problem("http://"), .unsupported, "no host")
            Check.equal(problem("-oProxyCommand=evil"), .unsupported)
            Check.equal(problem("relative/path.git"), .unsupported)
            Check.equal(problem("https://me:secret@github.com/a/b.git"), .embeddedCredentials)
            Check.equal(problem("http://me:secret@host/a.git"), .embeddedCredentials)
        }

        Check.test("a user name without a password is fine") {
            Check.equal(GitRemoteAddress.problem(with: "https://me@github.com/a/b.git"), nil)
            Check.equal(GitRemoteAddress.problem(with: " git@github.com:a/b.git \n"), nil, "trimmed")
        }
    }

    Check.suite("Git sync · more settings") {
        func decode(_ json: String) -> Settings {
            (try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))) ?? Settings()
        }

        Check.test("sync is off by default, and for a file written before it existed") {
            Check.equal(Settings().gitSync, GitSyncSettings())
            Check.expect(!Settings().gitSync.isActive)
            Check.equal(decode(#"{"recentlyDeletedDays": 7}"#).gitSync, GitSyncSettings())
        }

        Check.test("addresses and branches are trimmed on the way in") {
            let loaded = decode(#"{"gitSync": {"enabled": true, "remoteURL": "  git@x:a/b.git \n", "branch": " notes "}}"#)
            Check.equal(loaded.gitSync.remoteURL, "git@x:a/b.git")
            Check.equal(loaded.gitSync.branch, "notes")
            Check.expect(loaded.gitSync.isActive)
        }

        Check.test("missing keys take their defaults, unknown ones are ignored") {
            let loaded = decode(#"{"gitSync": {"remoteURL": "x", "interval": 1}}"#)
            Check.equal(loaded.gitSync, GitSyncSettings(enabled: false, remoteURL: "x", branch: ""))
        }

        Check.test("a block with the wrong type costs the block, not the file") {
            let loaded = decode(#"{"recentlyDeletedDays": 9, "gitSync": {"enabled": "yes", "remoteURL": "x"}}"#)
            Check.equal(loaded.gitSync, GitSyncSettings())
            Check.equal(loaded.recentlyDeletedDays, 9)
        }

        Check.test("there is nowhere in the file to put a password") {
            // Authentication is the system git's. If a credential field ever appears here, this is
            // the test that should make somebody stop and ask why.
            var settings = Settings()
            settings.gitSync = GitSyncSettings(enabled: true, remoteURL: "git@x:a/b.git", branch: "main")
            let data = (try? JSONEncoder().encode(settings)) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let block = object?["gitSync"] as? [String: Any]
            Check.equal(Set(block?.keys.map { $0 } ?? []), ["enabled", "remoteURL", "branch"])
        }
    }

    Check.suite("Git sync · schedule") {
        Check.test("a vault that is still being written is put off") {
            Check.equal(
                GitSyncSchedule.decide(sinceLastActivity: 0, postponements: 0),
                .postpone(after: GitSyncSchedule.quietPeriod)
            )
            Check.equal(
                GitSyncSchedule.decide(sinceLastActivity: GitSyncSchedule.quietPeriod - 0.1, postponements: 3),
                .postpone(after: GitSyncSchedule.quietPeriod)
            )
        }

        Check.test("a quiet vault syncs") {
            Check.equal(GitSyncSchedule.decide(sinceLastActivity: GitSyncSchedule.quietPeriod, postponements: 0), .run)
            Check.equal(GitSyncSchedule.decide(sinceLastActivity: 3600, postponements: 0), .run)
        }

        Check.test("a vault that never goes quiet is still synced, eventually") {
            var postponements = 0
            var runs = 0
            while runs == 0 && postponements < 100 {
                if GitSyncSchedule.decide(sinceLastActivity: 0, postponements: postponements) == .run {
                    runs += 1
                } else {
                    postponements += 1
                }
            }
            Check.equal(postponements, GitSyncSchedule.maxPostponements)
            Check.equal(runs, 1)
        }

        Check.test("the cadence is five minutes") {
            Check.equal(GitSyncSchedule.interval, 300)
        }
    }

}
