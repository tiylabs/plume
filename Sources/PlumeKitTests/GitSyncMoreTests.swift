import Foundation
import PlumeKit

/// The second half of the Git sync suite: the wording, the schedule, the settings file, and the engine
/// at its edges — a remote that changed under it, a folder that vanished, a push that lost a race.
///
/// `GitSyncTests.swift` holds the main paths; this file holds the cases that cost somebody their
/// notes if they regress, which are mostly the unhappy ones.
func runGitSyncMoreTests() {
    runGitSyncPureTests()
    runGitSyncRepositoryTests()
}

// MARK: - Pure logic

private func runGitSyncPureTests() {

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

    runGitSyncWordingTests()
}

private func runGitSyncWordingTests() {
    guard let directory = L10n.bundledDirectory() else {
        Check.suite("Git sync · wording") {
            Check.test("the Locales folder is found") { Check.expect(false, "set PLUME_LOCALES") }
        }
        return
    }
    L10n.configure(directory: directory)
    defer { L10n.setLanguage(L10n.fallbackLanguage) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    Check.suite("Git sync · wording") {

        Check.test("a sync in the last moments reads as just now, in each language") {
            L10n.setLanguage("en")
            Check.equal(GitSyncWording.relative(now.addingTimeInterval(-10), now: now), "just now")
            L10n.setLanguage("zh-Hans")
            Check.equal(GitSyncWording.relative(now.addingTimeInterval(-10), now: now), "刚刚")
            Check.equal(GitSyncWording.relative(now, now: now), "刚刚")
        }

        Check.test("the just-now window ends at forty-five seconds") {
            L10n.setLanguage("zh-Hans")
            Check.equal(GitSyncWording.relative(now.addingTimeInterval(-44), now: now), "刚刚")
            Check.notEqual(GitSyncWording.relative(now.addingTimeInterval(-46), now: now), "刚刚")
        }

        Check.test("older syncs say how long ago") {
            L10n.setLanguage("en")
            Check.expect(GitSyncWording.relative(now.addingTimeInterval(-300), now: now).contains("5"))
            L10n.setLanguage("zh-Hans")
            let text = GitSyncWording.relative(now.addingTimeInterval(-300), now: now)
            Check.expect(text.contains("5") && text.contains("分钟"), text)
        }

        Check.test("the headline for every status") {
            L10n.setLanguage("en")
            Check.equal(GitSyncWording.headline(.idle(lastSync: nil)), "Not synced yet")
            Check.equal(GitSyncWording.headline(.idle(lastSync: now), now: now), "Last synced just now")
            Check.equal(GitSyncWording.headline(.syncing), "Syncing…")
            Check.equal(GitSyncWording.headline(.conflicts(["a.md"])), "Sync conflict in 1 note")
            Check.equal(GitSyncWording.headline(.conflicts(["a.md", "b.md"])), "Sync conflicts in 2 notes")
            Check.equal(GitSyncWording.headline(.failed(.network)), "Sync failed")

            L10n.setLanguage("zh-Hans")
            Check.equal(GitSyncWording.headline(.idle(lastSync: nil)), "尚未同步")
            Check.equal(GitSyncWording.headline(.idle(lastSync: now), now: now), "上次同步 刚刚")
            Check.equal(GitSyncWording.headline(.conflicts(["a.md", "b.md", "c.md"])), "3 篇笔记存在同步冲突")
        }

        Check.test("the detail line exists only when there is more to say") {
            L10n.setLanguage("en")
            Check.equal(GitSyncWording.detail(.idle(lastSync: now)), "")
            Check.equal(GitSyncWording.detail(.syncing), "")
            Check.expect(GitSyncWording.detail(.conflicts(["a.md"])).contains("<<<<<<<"))
            Check.equal(GitSyncWording.detail(.failed(.network)), GitSyncFailure.network.message)
        }

        Check.test("every failure has a sentence in every language, and none is a bare key") {
            let all: [GitSyncFailure] = [
                .gitMissing, .authenticationFailed, .noWriteAccess, .network, .repositoryNotFound,
                .branchMissing, .repositoryState(""), .repositoryState("locked"), .other(""), .other("boom"),
            ]
            var english: [String] = []
            L10n.setLanguage("en")
            for failure in all {
                Check.expect(!failure.message.isEmpty && !failure.message.hasPrefix("sync."), "\(failure) → \(failure.message)")
                english.append(failure.message)
            }
            L10n.setLanguage("zh-Hans")
            for (failure, before) in zip(all, english) {
                Check.expect(!failure.message.isEmpty && !failure.message.hasPrefix("sync."), "\(failure) → \(failure.message)")
                Check.notEqual(failure.message, before, "\(failure) is not translated")
            }
            L10n.setLanguage("en")
            Check.expect(GitSyncFailure.repositoryState("locked").message.contains("locked"))
            Check.expect(GitSyncFailure.other("boom").message.contains("boom"))
        }

        Check.test("every verification step has a label in every language") {
            for language in ["en", "zh-Hans"] {
                L10n.setLanguage(language)
                for step in GitSyncValidation.Step.allCases {
                    Check.expect(!step.label.hasPrefix("sync."), "\(language) \(step.rawValue)")
                }
            }
        }
    }
}

// MARK: - Against real repositories

/// Real git, real repositories on disk, and nothing from the machine running the suite.
private final class Lab {
    let root: URL
    let git: GitRunner
    private var counter = 0

    init(root: URL, executable: URL?) {
        self.root = root
        self.git = GitRunner(executable: executable, fallbackIdentity: ("Tester", "tester@example.com"))
    }

    func folder(_ name: String) -> URL {
        counter += 1
        let url = root.appendingPathComponent("\(name)-\(counter)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remote(head: String = "main") -> URL {
        let url = folder("remote.git")
        git.run(["init", "--bare", "--quiet"], in: url)
        git.run(["symbolic-ref", "HEAD", "refs/heads/\(head)"], in: url)
        return url
    }

    func write(_ text: String, _ name: String, in dir: URL) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func remove(_ name: String, in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func engine(_ dir: URL, _ remote: URL, branch: String = "") -> GitSyncEngine {
        GitSyncEngine(vault: dir, remoteURL: remote.path, branch: branch, runner: git)
    }

    func out(_ arguments: [String], in dir: URL) -> String {
        git.run(arguments, in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commitCount(_ dir: URL) -> Int {
        Int(out(["rev-list", "--count", "HEAD"], in: dir)) ?? -1
    }

    /// Two vaults bound to one remote, both holding `files`.
    func pair(files: [String: String] = ["n.md": "line\n"]) -> (origin: URL, a: URL, b: URL, syncA: GitSyncEngine, syncB: GitSyncEngine) {
        let origin = remote(), a = folder("a"), b = folder("b")
        for (name, text) in files { write(text, name, in: a) }
        let syncA = engine(a, origin), syncB = engine(b, origin)
        _ = syncA.bind()
        _ = syncB.bind()
        return (origin, a, b, syncA, syncB)
    }

    /// `pair`, after both edited every file and B ran into A's edit.
    func conflicted(files: [String] = ["n.md"]) -> (origin: URL, a: URL, b: URL, syncA: GitSyncEngine, syncB: GitSyncEngine) {
        var initial: [String: String] = [:]
        for name in files { initial[name] = "line\n" }
        let lab = pair(files: initial)
        for name in files {
            write("line from A\n", name, in: lab.a)
            write("line from B\n", name, in: lab.b)
        }
        _ = lab.syncA.cycle()
        _ = lab.syncB.cycle()
        return lab
    }
}

private func activity(_ outcome: GitSyncEngine.Outcome) -> GitSyncEngine.Activity? {
    if case .synced(let value) = outcome { return value }
    return nil
}

private func conflicts(_ outcome: GitSyncEngine.Outcome) -> [String]? {
    if case .conflicts(let files) = outcome { return files }
    return nil
}

private func isRepositoryState(_ outcome: GitSyncEngine.Outcome) -> Bool {
    if case .failed(.repositoryState) = outcome { return true }
    return false
}

/// Runs `body` against a scratch directory with the user's own git configuration out of the way, or
/// replaced by `globalConfig`. Without that the suite passes on one machine and fails on the next.
private func withIsolatedGit(globalConfig: String? = nil, _ body: (Lab) -> Void) {
    let probe = GitRunner()
    guard probe.isAvailable else {
        print("note: git not found — skipping the Git sync repository tests")
        return
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plume-gitsync-more-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let configPath: String
    if let globalConfig {
        let file = root.appendingPathComponent("gitconfig")
        try? globalConfig.write(to: file, atomically: true, encoding: .utf8)
        configPath = file.path
    } else {
        configPath = "/dev/null"
    }

    let keys = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"]
    let saved: [(String, String?)] = keys.map { key in (key, getenv(key).map { String(cString: $0) }) }
    setenv("GIT_CONFIG_GLOBAL", configPath, 1)
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    defer {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    body(Lab(root: root, executable: probe.executable))
}

private func runGitSyncRepositoryTests() {

    withIsolatedGit { lab in

        Check.suite("Git sync · running git") {

            Check.test("a command that fails says so, and a missing directory is not a crash") {
                let repo = lab.folder("r")
                lab.git.run(["init", "--quiet"], in: repo)
                let failed = lab.git.run(["rev-parse", "--verify", "nope"], in: repo)
                Check.expect(!failed.succeeded)
                Check.notEqual(failed.status, 0)

                let missing = lab.git.run(["status"], in: lab.root.appendingPathComponent("not-there"))
                Check.expect(!missing.succeeded)
                Check.expect(!missing.stderr.isEmpty)
            }

            Check.test("output larger than a pipe buffer does not deadlock") {
                let repo = lab.folder("big")
                lab.git.run(["init", "--quiet"], in: repo)
                lab.write((1...200_000).map { "line \($0) of a very long note" }.joined(separator: "\n") + "\n", "big.md", in: repo)
                lab.git.run(["add", "-A"], in: repo)
                Check.expect(lab.git.run(["commit", "--quiet", "-m", "big"], in: repo, identity: true).succeeded)
                let shown = lab.git.run(["show", "HEAD"], in: repo)
                Check.expect(shown.succeeded)
                Check.expect(shown.stdout.utf8.count > 1_000_000, "\(shown.stdout.utf8.count) bytes")
            }

            Check.test("without git installed everything fails the same, named way") {
                let none = GitRunner(executable: nil)
                Check.expect(!none.isAvailable)
                let result = none.run(["status"], in: lab.root)
                Check.equal(result.status, 127)
                Check.expect(!result.succeeded)

                let dir = lab.folder("a")
                lab.write("# One\n", "one.md", in: dir)
                let engine = GitSyncEngine(vault: dir, remoteURL: lab.remote().path, runner: none)
                Check.equal(engine.bind(), .failed(.gitMissing))
                Check.equal(engine.cycle(), .failed(.gitMissing))
                Check.expect(!engine.snapshot())
                Check.expect(!lab.exists(".git", in: dir), "nothing was initialised")

                let validation = GitSyncValidation.run(address: "git@x:a/b.git", runner: none)
                Check.equal(validation.entries.count, 1)
                Check.equal(validation.firstFailure?.step, .gitInstalled)
            }
        }

        Check.suite("Git sync · more binding") {

            Check.test("binding twice is the same as binding once") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                let engine = lab.engine(a, origin)
                _ = engine.bind()
                let before = lab.commitCount(a)
                Check.equal(activity(engine.bind()), GitSyncEngine.Activity())
                Check.equal(lab.commitCount(a), before)
            }

            Check.test("an empty folder and an empty remote is a sync with nothing in it") {
                let origin = lab.remote(), a = lab.folder("a")
                let engine = lab.engine(a, origin)
                Check.equal(activity(engine.bind()), GitSyncEngine.Activity())

                lab.write("# First\n", "first.md", in: a)
                let outcome = engine.cycle()
                Check.equal(activity(outcome)?.committed, true)
                Check.equal(activity(outcome)?.pushed, true)
            }

            Check.test("the folder reports its repository and origin") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                let engine = lab.engine(a, origin)
                Check.expect(!engine.isRepository)
                Check.equal(engine.existingOrigin(), nil)
                _ = engine.bind()
                Check.expect(engine.isRepository)
                Check.equal(engine.existingOrigin(), origin.path)
            }

            Check.test("pointing a bound folder at another remote moves it there") {
                let first = lab.remote(), second = lab.remote(), a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                _ = lab.engine(a, first).bind()

                let moved = lab.engine(a, second)
                Check.equal(moved.existingOrigin(), first.path)
                Check.equal(activity(moved.bind())?.pushed, true)
                Check.equal(moved.existingOrigin(), second.path)
                Check.equal(lab.out(["show", "main:one.md"], in: second), "# One")
                Check.expect(lab.exists(".git/plume-sync-initialized", in: a), "the new relationship is initialised")
            }

            Check.test("a configured branch is the one that is pushed, and the one a second Mac follows") {
                let origin = lab.remote(), a = lab.folder("a"), b = lab.folder("b")
                lab.write("# One\n", "one.md", in: a)
                _ = lab.engine(a, origin, branch: "notes").bind()
                Check.equal(lab.out(["for-each-ref", "--format=%(refname)"], in: origin), "refs/heads/notes")

                _ = lab.engine(b, origin, branch: "notes").bind()
                Check.equal(lab.read("one.md", in: b), "# One\n")
            }

            Check.test("with no branch configured the remote's own default is followed") {
                let origin = lab.remote(head: "trunk"), a = lab.folder("a"), b = lab.folder("b")
                lab.write("# One\n", "one.md", in: a)
                _ = lab.engine(a, origin, branch: "trunk").bind()

                Check.equal(activity(lab.engine(b, origin).bind())?.pulled, true)
                Check.equal(lab.read("one.md", in: b), "# One\n")
                Check.equal(lab.out(["symbolic-ref", "--short", "HEAD"], in: b), "trunk")
            }

            Check.test("a repository the user already had is joined, and its own ignore rules survive") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.git.run(["init", "--quiet"], in: a)
                lab.write("custom-ignore\n", ".git/info/exclude", in: a)
                lab.write("# One\n", "one.md", in: a)
                lab.write("x", "custom-ignore", in: a)
                _ = lab.engine(a, origin).bind()

                let exclude = lab.read(".git/info/exclude", in: a) ?? ""
                Check.expect(exclude.contains("custom-ignore"), exclude)
                Check.expect(exclude.contains(".DS_Store"), exclude)
                let tracked = lab.out(["ls-files"], in: a)
                Check.expect(tracked.contains("one.md") && !tracked.contains("custom-ignore"), tracked)
            }

            Check.test("the ignore rules are written once, however often it binds") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                _ = lab.engine(a, origin).bind()
                _ = lab.engine(a, origin).bind()
                let exclude = lab.read(".git/info/exclude", in: a) ?? ""
                Check.equal(exclude.components(separatedBy: ".DS_Store").count - 1, 1, exclude)

                lab.write("x", ".hidden.md.icloud", in: a)
                lab.write("x", ".DS_Store", in: a)
                lab.write("# Two\n", "two.md", in: a)
                _ = lab.engine(a, origin).cycle()
                let tracked = lab.out(["ls-files"], in: a)
                Check.expect(tracked.contains("two.md") && !tracked.contains("icloud") && !tracked.contains("DS_Store"), tracked)
            }
        }

        Check.suite("Git sync · commits") {

            Check.test("a commit says how many notes, from which Mac") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.write("1\n", "one.md", in: a)
                let engine = lab.engine(a, origin)
                _ = engine.bind()
                let first = lab.out(["log", "-1", "--format=%s"], in: a)
                Check.expect(first.hasPrefix("Plume sync · 1 note · "), first)

                lab.write("2\n", "two.md", in: a)
                lab.write("3\n", "three.md", in: a)
                _ = engine.cycle()
                let second = lab.out(["log", "-1", "--format=%s"], in: a)
                Check.expect(second.hasPrefix("Plume sync · 2 notes · "), second)
            }

            Check.test("a machine with no git identity still commits, as Plume") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                _ = lab.engine(a, origin).bind()
                Check.equal(lab.out(["log", "-1", "--format=%an <%ae>"], in: a), "Tester <tester@example.com>")
            }
        }

        Check.suite("Git sync · changes that travel") {

            Check.test("a deletion and a rename reach the other Mac") {
                let lab2 = lab.pair(files: ["one.md": "one\n", "two.md": "two\n"])
                lab.remove("one.md", in: lab2.a)
                try? FileManager.default.moveItem(
                    at: lab2.a.appendingPathComponent("two.md"), to: lab2.a.appendingPathComponent("three.md")
                )
                Check.equal(activity(lab2.syncA.cycle())?.pushed, true)
                Check.equal(activity(lab2.syncB.cycle())?.pulled, true)

                Check.expect(!lab.exists("one.md", in: lab2.b))
                Check.expect(!lab.exists("two.md", in: lab2.b))
                Check.equal(lab.read("three.md", in: lab2.b), "two\n")
            }

            Check.test("a push that loses a race to another Mac is retried, and both edits land") {
                let lab2 = lab.pair(files: ["one.md": "one\n"])
                let racer = lab.folder("racer")
                lab.git.run(["clone", "--quiet", lab2.origin.path, racer.path], in: lab.root)

                // The racer pushes in the instant between this Mac's fetch and its push: a pre-push
                // hook that does it once, which is the only way to land inside that window.
                let flag = lab.root.appendingPathComponent("raced-\(UUID().uuidString)").path
                let hook = """
                    #!/bin/sh
                    if [ ! -f '\(flag)' ]; then
                      touch '\(flag)'
                      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
                      cd '\(racer.path)' || exit 1
                      echo racer > racer.md
                      git add racer.md
                      git -c user.name=r -c user.email=r@example.com commit -qm racer
                      git push -q origin HEAD:main
                    fi
                    exit 0
                    """
                let hookURL = lab2.a.appendingPathComponent(".git/hooks/pre-push")
                try? FileManager.default.createDirectory(
                    at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? hook.write(to: hookURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

                lab.write("mine\n", "mine.md", in: lab2.a)
                let outcome = lab2.syncA.cycle()
                Check.expect(FileManager.default.fileExists(atPath: flag), "the racer ran")
                Check.equal(activity(outcome)?.pushed, true, "\(outcome)")
                Check.equal(activity(outcome)?.pulled, true)
                Check.equal(lab.read("racer.md", in: lab2.a), "racer\n")
                Check.equal(lab.out(["show", "main:mine.md"], in: lab2.origin), "mine")
                Check.equal(lab.out(["show", "main:racer.md"], in: lab2.origin), "racer")
            }
        }

        Check.suite("Git sync · conflicts at the edges") {

            Check.test("every conflicted note is reported, and fixing one leaves the other") {
                let lab2 = lab.conflicted(files: ["a.md", "b.md"])
                Check.equal(Set(lab2.syncB.conflictedFiles()), ["a.md", "b.md"])
                Check.equal(Set(conflicts(lab2.syncB.recheckConflicts()) ?? []), ["a.md", "b.md"])

                lab.write("a, settled\n", "a.md", in: lab2.b)
                Check.equal(conflicts(lab2.syncB.recheckConflicts()), ["b.md"])
                Check.expect(lab2.syncB.isMergeInProgress, "the merge waits for the last one")
            }

            Check.test("a cycle finishes a merge whose markers were removed by hand") {
                let lab2 = lab.conflicted()
                lab.write("both\n", "n.md", in: lab2.b)
                let outcome = lab2.syncB.cycle()
                Check.equal(activity(outcome)?.pushed, true, "\(outcome)")
                Check.expect(!lab2.syncB.isMergeInProgress)

                _ = lab2.syncA.cycle()
                Check.equal(lab.read("n.md", in: lab2.a), "both\n")
            }

            Check.test("deleting a conflicted note is a way of resolving it") {
                let lab2 = lab.conflicted()
                lab.remove("n.md", in: lab2.b)
                Check.expect(activity(lab2.syncB.recheckConflicts()) != nil)
                Check.expect(!lab2.syncB.isMergeInProgress)
                _ = lab2.syncB.cycle()
                _ = lab2.syncA.cycle()
                Check.expect(!lab.exists("n.md", in: lab2.a))
            }

            Check.test("nothing is committed while a conflict stands") {
                let lab2 = lab.conflicted()
                let before = lab.commitCount(lab2.b)
                lab.write("unrelated\n", "other.md", in: lab2.b)
                Check.expect(!lab2.syncB.snapshot())
                Check.equal(lab.commitCount(lab2.b), before)
                Check.equal(conflicts(lab2.syncB.cycle()), ["n.md"])
                Check.equal(lab.commitCount(lab2.b), before)
            }

            Check.test("with no merge under way there is nothing to recheck") {
                let lab2 = lab.pair()
                Check.equal(lab2.syncA.conflictedFiles(), [])
                Check.expect(!lab2.syncA.isMergeInProgress)
                Check.equal(activity(lab2.syncA.recheckConflicts()), GitSyncEngine.Activity())
            }
        }

        Check.suite("Git sync · a folder that is not as it was") {

            Check.test("a cycle on a folder that was never bound fails without creating anything") {
                let a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                let outcome = lab.engine(a, lab.remote()).cycle()
                Check.expect(isRepositoryState(outcome), "\(outcome)")
                Check.expect(!lab.exists(".git", in: a))
            }

            Check.test("a vanished folder is a failure, never a commit that deletes every note") {
                let lab2 = lab.pair(files: ["one.md": "one\n", "two.md": "two\n"])
                let before = lab.commitCount(lab2.origin)
                try? FileManager.default.removeItem(at: lab2.a)
                Check.expect(isRepositoryState(lab2.syncA.cycle()))
                Check.expect(isRepositoryState(lab2.syncA.bind()))
                Check.equal(lab.commitCount(lab2.origin), before)
                Check.equal(lab.out(["show", "main:one.md"], in: lab2.origin), "one")
            }

            Check.test("a rebase in progress is left alone") {
                let lab2 = lab.pair()
                try? FileManager.default.createDirectory(
                    at: lab2.a.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true
                )
                lab.write("edit\n", "n.md", in: lab2.a)
                let before = lab.commitCount(lab2.a)
                Check.expect(isRepositoryState(lab2.syncA.cycle()))
                Check.equal(lab.commitCount(lab2.a), before, "it did not commit into somebody's rebase")
            }

            Check.test("a remote whose history was rewritten is not merged into silently") {
                let lab2 = lab.pair(files: ["one.md": "one\n"])
                let rewriter = lab.folder("rewriter")
                lab.git.run(["clone", "--quiet", lab2.origin.path, rewriter.path], in: lab.root)
                lab.git.run(["checkout", "--quiet", "--orphan", "rewritten"], in: rewriter)
                lab.git.run(["rm", "-rf", "--quiet", "."], in: rewriter)
                lab.write("new\n", "new.md", in: rewriter)
                lab.git.run(["add", "-A"], in: rewriter)
                lab.git.run(["commit", "--quiet", "-m", "rewritten"], in: rewriter, identity: true)
                Check.expect(lab.git.run(["push", "--quiet", "--force", "origin", "HEAD:main"], in: rewriter).succeeded)

                let outcome = lab2.syncA.cycle()
                Check.expect(isRepositoryState(outcome), "\(outcome)")
                Check.equal(lab.read("one.md", in: lab2.a), "one\n", "local notes untouched")
                Check.expect(!lab.exists("new.md", in: lab2.a))
            }
        }

        Check.suite("Git sync · more verification") {

            Check.test("a refused connection is reported as the network, quickly") {
                let started = Date()
                let result = GitSyncValidation.run(address: "http://127.0.0.1:9/notes.git", runner: lab.git)
                Check.expect(!result.passed)
                Check.equal(result.firstFailure?.step, .remoteReachable)
                Check.equal(result.firstFailure?.detail, GitSyncFailure.network.message)
                Check.expect(Date().timeIntervalSince(started) < 30, "did not wait on a prompt")
            }

            Check.test("a password in the address is refused before anything is contacted") {
                let result = GitSyncValidation.run(address: "https://me:secret@github.com/a/b.git", runner: lab.git)
                Check.equal(result.entries.map(\.step), [.gitInstalled, .addressFormat])
                Check.equal(result.firstFailure?.step, .addressFormat)
                Check.expect(result.firstFailure?.detail.isEmpty == false)
            }

            Check.test("a named branch that exists is found, one that does not will be created") {
                let origin = lab.remote(), a = lab.folder("a")
                lab.write("# One\n", "one.md", in: a)
                _ = lab.engine(a, origin).bind()

                let existing = GitSyncValidation.run(address: origin.path, branch: "main", runner: lab.git)
                let missing = GitSyncValidation.run(address: origin.path, branch: "drafts", runner: lab.git)
                Check.expect(existing.passed && missing.passed)
                Check.notEqual(existing.entries.last?.detail, missing.entries.last?.detail)
                Check.expect(missing.entries.last?.detail.contains("drafts") == true)
            }
        }
    }

    // A user who has set up git keeps their own name on their commits.
    withIsolatedGit(globalConfig: "[user]\n\tname = Alice\n\temail = alice@example.com\n") { lab in
        Check.suite("Git sync · identity") {
            Check.test("the user's own git identity wins over Plume's fallback") {
                let origin = lab.remote(), a = lab.folder("a"), b = lab.folder("b")
                lab.write("# One\n", "one.md", in: a)
                lab.write("# Two\n", "two.md", in: b)
                _ = lab.engine(a, origin).bind()
                Check.equal(lab.out(["log", "-1", "--format=%an <%ae>"], in: a), "Alice <alice@example.com>")

                // The merge commit too: the join of two histories is also Alice's.
                _ = lab.engine(b, origin).bind()
                Check.equal(lab.out(["log", "-1", "--format=%an"], in: b), "Alice")
            }
        }
    }
}
