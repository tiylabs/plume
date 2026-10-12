import Foundation
import PlumeKit

func runGitSyncTests() {
    Check.suite("Git sync · failure classification") {
        func classify(_ text: String, pushing: Bool = false) -> GitSyncFailure {
            GitSyncFailure.classify(output: text, pushing: pushing)
        }

        Check.test("an ssh key problem is an authentication failure") {
            Check.equal(
                classify("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."),
                .authenticationFailed
            )
            Check.equal(classify("fatal: could not read Username for 'https://github.com': terminal prompts disabled"), .authenticationFailed)
            Check.equal(classify("fatal: Authentication failed for 'https://github.com/a/b.git/'"), .authenticationFailed)
        }

        Check.test("a 403 is an authentication failure on read and a permission failure on push") {
            let text = "fatal: unable to access 'https://x/y.git/': The requested URL returned error: 403"
            Check.equal(classify(text), .authenticationFailed)
            Check.equal(classify(text, pushing: true), .noWriteAccess)
            Check.equal(classify("remote: Permission to a/b.git denied to someone.", pushing: true), .noWriteAccess)
        }

        Check.test("connectivity problems are network failures, and a timeout always is") {
            Check.equal(classify("fatal: unable to access 'https://x/': Could not resolve host: x"), .network)
            Check.equal(classify("ssh: connect to host github.com port 22: Operation timed out"), .network)
            Check.equal(GitSyncFailure.classify(output: "", timedOut: true), .network)
            Check.expect(GitSyncFailure.network.isTransient)
            Check.expect(!GitSyncFailure.authenticationFailed.isTransient)
        }

        Check.test("a missing repository and a missing branch are told apart") {
            Check.equal(classify("remote: Repository not found.\nfatal: repository 'https://x/y.git/' not found"), .repositoryNotFound)
            Check.equal(classify("fatal: couldn't find remote ref refs/heads/nope"), .branchMissing)
            Check.equal(classify("fatal: '/nowhere' does not appear to be a git repository"), .repositoryNotFound)
        }

        Check.test("a lock file is a repository-state problem") {
            if case .repositoryState = classify("fatal: Unable to create '/n/.git/index.lock': File exists.") {
            } else {
                Check.expect(false, "expected repositoryState")
            }
        }

        Check.test("anything else keeps git's first line") {
            Check.equal(classify("\nerror: something odd\nmore"), .other("error: something odd"))
        }
    }

    Check.suite("Git sync · failure tracker") {
        Check.test("network trouble surfaces only on the third cycle in a row") {
            var tracker = GitSyncFailureTracker()
            Check.equal(tracker.record(.network), nil)
            Check.equal(tracker.record(.network), nil)
            Check.equal(tracker.record(.network), .network)
            Check.equal(tracker.record(.network), .network)
        }

        Check.test("a success starts the count again") {
            var tracker = GitSyncFailureTracker()
            _ = tracker.record(.network)
            _ = tracker.record(.network)
            Check.equal(tracker.record(nil), nil)
            Check.equal(tracker.record(.network), nil)
        }

        Check.test("anything that will not cure itself surfaces at once") {
            var tracker = GitSyncFailureTracker()
            Check.equal(tracker.record(.authenticationFailed), .authenticationFailed)
            Check.equal(tracker.record(.repositoryNotFound), .repositoryNotFound)
        }
    }

    Check.suite("Git sync · menu bar dot") {
        Check.test("failure outranks conflict outranks update") {
            Check.equal(MenuBarDot.resolve(sync: .failed(.network), updateAvailable: true), .failure)
            Check.equal(MenuBarDot.resolve(sync: .conflicts(["a.md"]), updateAvailable: true), .conflict)
            Check.equal(MenuBarDot.resolve(sync: .idle(lastSync: nil), updateAvailable: true), .update)
            Check.equal(MenuBarDot.resolve(sync: .syncing, updateAvailable: true), .update)
            Check.equal(MenuBarDot.resolve(sync: nil, updateAvailable: false), MenuBarDot.none)
        }
    }

    Check.suite("Git sync · conflict markers") {
        Check.test("either end of a block counts, a setext underline does not") {
            Check.expect(ConflictMarkers.isPresent(in: "a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> origin/main\n"))
            Check.expect(ConflictMarkers.isPresent(in: "a\n<<<<<<< HEAD\nx\n"))
            Check.expect(ConflictMarkers.isPresent(in: "x\n>>>>>>> origin/main"))
            Check.expect(!ConflictMarkers.isPresent(in: "Title\n=======\nbody\n"))
        }

        Check.test("a marker that is not at the start of a line is prose") {
            Check.expect(!ConflictMarkers.isPresent(in: "git writes `<<<<<<< HEAD` here\n"))
            Check.expect(!ConflictMarkers.isPresent(in: "    <<<<<<< HEAD\n"))
            Check.expect(!ConflictMarkers.isPresent(in: "<<<<<<<<< eight\n"))
        }
    }

    Check.suite("Git sync · remote addresses") {
        func problem(_ s: String) -> GitRemoteAddress.Problem? { GitRemoteAddress.problem(with: s) }

        Check.test("the usual forms are accepted") {
            for ok in ["https://github.com/a/b.git", "git@github.com:a/b.git", "ssh://git@host:2222/a/b.git",
                       "file:///tmp/x.git", "/srv/notes.git", "git://host/a.git"] {
                Check.equal(problem(ok), nil, ok)
            }
        }

        Check.test("nothing git could mistake for an option, a command or a password") {
            Check.equal(problem(""), .empty)
            Check.equal(problem("   "), .empty)
            Check.equal(problem("--upload-pack=evil"), .unsupported)
            Check.equal(problem("ext::sh -c touch% /tmp/x"), .unsupported)
            Check.equal(problem("not an address"), .unsupported)
            Check.equal(problem("ftp://host/a.git"), .unsupported)
            Check.equal(problem("https://me:token@github.com/a/b.git"), .embeddedCredentials)
        }
    }

    Check.suite("Git sync · settings") {
        Check.test("round-trips, and a damaged block costs only itself") {
            var settings = Settings()
            settings.gitSync = GitSyncSettings(enabled: true, remoteURL: "git@x:a/b.git", branch: "notes")
            let data = try! JSONEncoder().encode(settings)
            let back = try! JSONDecoder().decode(Settings.self, from: data)
            Check.equal(back.gitSync, settings.gitSync)
            Check.expect(back.gitSync.isActive)

            let damaged = #"{"recentlyDeletedDays": 7, "gitSync": "nope"}"#
            let loaded = try! JSONDecoder().decode(Settings.self, from: Data(damaged.utf8))
            Check.equal(loaded.recentlyDeletedDays, 7)
            Check.equal(loaded.gitSync, GitSyncSettings())
        }

        Check.test("enabled with no address is not a sync") {
            Check.expect(!GitSyncSettings(enabled: true, remoteURL: "").isActive)
            Check.expect(!GitSyncSettings(enabled: false, remoteURL: "x").isActive)
        }
    }

    runGitSyncEngineTests()
}

// MARK: - Against real repositories

private func runGitSyncEngineTests() {
    let runner = GitRunner()
    guard runner.isAvailable else {
        print("note: git not found — skipping the Git sync engine tests")
        return
    }

    // The user's own configuration must not leak into the fixtures, or the suite passes on one
    // machine and fails on the next.
    let saved: [(String, String?)] = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"].map { key in
        (key, getenv(key).map { String(cString: $0) })
    }
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    defer {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    let git = GitRunner(executable: runner.executable, fallbackIdentity: ("Tester", "tester@example.com"))

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plume-gitsync-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var counter = 0
    func folder(_ name: String) -> URL {
        counter += 1
        let url = root.appendingPathComponent("\(name)-\(counter)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func remote() -> URL {
        let url = folder("remote.git")
        git.run(["init", "--bare", "--quiet"], in: url)
        git.run(["symbolic-ref", "HEAD", "refs/heads/main"], in: url)
        return url
    }
    func write(_ text: String, _ name: String, in dir: URL) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }
    func engine(_ dir: URL, _ remote: URL, branch: String = "") -> GitSyncEngine {
        GitSyncEngine(vault: dir, remoteURL: remote.path, branch: branch, runner: git)
    }
    func activity(_ outcome: GitSyncEngine.Outcome) -> GitSyncEngine.Activity? {
        if case .synced(let a) = outcome { return a }
        return nil
    }
    func conflicts(_ outcome: GitSyncEngine.Outcome) -> [String]? {
        if case .conflicts(let files) = outcome { return files }
        return nil
    }
    func commitCount(_ dir: URL) -> Int {
        Int(git.run(["rev-list", "--count", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    Check.suite("Git sync · binding") {

        Check.test("an empty remote receives the notes") {
            let origin = remote(), a = folder("a")
            write("# One\n", "one.md", in: a)
            let outcome = engine(a, origin).bind()
            Check.equal(activity(outcome)?.committed, true)
            Check.equal(activity(outcome)?.pushed, true)

            let check = folder("check")
            git.run(["clone", "--quiet", origin.path, check.path], in: root)
            Check.equal(read("one.md", in: check), "# One\n")
        }

        Check.test("a fresh folder takes the remote's notes") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("# One\n", "one.md", in: a)
            _ = engine(a, origin).bind()

            let outcome = engine(b, origin).bind()
            Check.equal(activity(outcome)?.pulled, true)
            Check.equal(read("one.md", in: b), "# One\n")
        }

        Check.test("a folder with notes joins a remote with different ones — both survive") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("# Remote\n", "remote.md", in: a)
            _ = engine(a, origin).bind()

            write("# Local\n", "local.md", in: b)
            let outcome = engine(b, origin).bind()
            Check.expect(activity(outcome) != nil, "\(outcome)")
            Check.equal(read("remote.md", in: b), "# Remote\n")
            Check.equal(read("local.md", in: b), "# Local\n")

            // And the merge reached the remote.
            _ = engine(a, origin).cycle()
            Check.equal(read("local.md", in: a), "# Local\n")
        }

        Check.test("the same note on both sides with different text is a conflict, not an overwrite") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("remote text\n", "same.md", in: a)
            _ = engine(a, origin).bind()

            write("local text\n", "same.md", in: b)
            let outcome = engine(b, origin).bind()
            Check.equal(conflicts(outcome), ["same.md"])
            let text = read("same.md", in: b) ?? ""
            Check.expect(text.contains("<<<<<<<") && text.contains("local text") && text.contains("remote text"), text)
        }

        Check.test("noise is kept out of commits") {
            let origin = remote(), a = folder("a")
            write("# One\n", "one.md", in: a)
            write("x", ".DS_Store", in: a)
            _ = engine(a, origin).bind()
            let tracked = git.run(["ls-files"], in: a).stdout
            Check.expect(tracked.contains("one.md"))
            Check.expect(!tracked.contains(".DS_Store"), tracked)
        }

        Check.test("a folder inside another repository is refused") {
            let outer = folder("outer")
            git.run(["init", "--quiet"], in: outer)
            let inner = outer.appendingPathComponent("notes")
            try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            let outcome = engine(inner, remote()).bind()
            if case .failed(.repositoryState) = outcome {} else { Check.expect(false, "\(outcome)") }
            Check.expect(!FileManager.default.fileExists(atPath: inner.appendingPathComponent(".git").path))
        }

        Check.test("a missing remote is a failure that names the repository") {
            let a = folder("a")
            write("# One\n", "one.md", in: a)
            let outcome = GitSyncEngine(
                vault: a, remoteURL: root.appendingPathComponent("nowhere.git").path, runner: git
            ).bind()
            Check.equal(outcome, .failed(.repositoryNotFound))
        }
    }

    Check.suite("Git sync · cycles") {

        Check.test("nothing changed means nothing done") {
            let origin = remote(), a = folder("a")
            write("# One\n", "one.md", in: a)
            let sync = engine(a, origin)
            _ = sync.bind()
            Check.equal(activity(sync.cycle()), GitSyncEngine.Activity())
        }

        Check.test("edits travel both ways") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("# One\n", "one.md", in: a)
            let syncA = engine(a, origin), syncB = engine(b, origin)
            _ = syncA.bind()
            _ = syncB.bind()

            write("# One\nfrom A\n", "one.md", in: a)
            Check.equal(activity(syncA.cycle())?.pushed, true)
            Check.equal(activity(syncB.cycle())?.pulled, true)
            Check.equal(read("one.md", in: b), "# One\nfrom A\n")

            write("# Two\n", "two.md", in: b)
            _ = syncB.cycle()
            _ = syncA.cycle()
            Check.equal(read("two.md", in: a), "# Two\n")
        }

        Check.test("different notes edited on both sides merge without a word") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("1\n", "one.md", in: a)
            write("2\n", "two.md", in: a)
            let syncA = engine(a, origin), syncB = engine(b, origin)
            _ = syncA.bind()
            _ = syncB.bind()

            write("1 edited on A\n", "one.md", in: a)
            write("2 edited on B\n", "two.md", in: b)
            _ = syncA.cycle()
            let outcome = syncB.cycle()
            Check.equal(activity(outcome)?.pulled, true)
            Check.equal(activity(outcome)?.pushed, true)
            Check.equal(read("one.md", in: b), "1 edited on A\n")
            _ = syncA.cycle()
            Check.equal(read("two.md", in: a), "2 edited on B\n")
        }

        Check.test("the same line edited on both sides stops with markers, and pushes nothing") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("line\n", "n.md", in: a)
            let syncA = engine(a, origin), syncB = engine(b, origin)
            _ = syncA.bind()
            _ = syncB.bind()

            write("line from A\n", "n.md", in: a)
            write("line from B\n", "n.md", in: b)
            _ = syncA.cycle()
            Check.equal(conflicts(syncB.cycle()), ["n.md"])
            let text = read("n.md", in: b) ?? ""
            Check.expect(text.contains("<<<<<<<") && text.contains("=======") && text.contains(">>>>>>>"), text)
            Check.equal(syncB.conflictedFiles(), ["n.md"])

            // Still stopped on the next cycle, and still not published.
            Check.equal(conflicts(syncB.cycle()), ["n.md"])
            let remoteText = git.run(["show", "main:n.md"], in: origin).stdout
            Check.equal(remoteText, "line from A\n")
        }

        Check.test("removing the markers resumes sync and publishes the merge") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("line\n", "n.md", in: a)
            let syncA = engine(a, origin), syncB = engine(b, origin)
            _ = syncA.bind()
            _ = syncB.bind()
            write("line from A\n", "n.md", in: a)
            write("line from B\n", "n.md", in: b)
            _ = syncA.cycle()
            _ = syncB.cycle()

            // Half-resolved is still conflicted.
            write("<<<<<<< HEAD\nline from B\n=======\nline from A\n", "n.md", in: b)
            Check.equal(conflicts(syncB.recheckConflicts()), ["n.md"])

            write("line from A and B\n", "n.md", in: b)
            Check.expect(activity(syncB.recheckConflicts()) != nil)
            Check.expect(!syncB.isMergeInProgress)
            Check.equal(syncB.conflictedFiles(), [])

            Check.equal(activity(syncB.cycle())?.pushed, true)
            _ = syncA.cycle()
            Check.equal(read("n.md", in: a), "line from A and B\n")
        }

        Check.test("a note deleted on one side and edited on the other keeps the edit, quietly") {
            let origin = remote(), a = folder("a"), b = folder("b")
            write("keep me\n", "n.md", in: a)
            let syncA = engine(a, origin), syncB = engine(b, origin)
            _ = syncA.bind()
            _ = syncB.bind()

            try? FileManager.default.removeItem(at: a.appendingPathComponent("n.md"))
            write("keep me, edited\n", "n.md", in: b)
            _ = syncA.cycle()
            let outcome = syncB.cycle()
            Check.expect(activity(outcome) != nil, "\(outcome)")
            Check.equal(read("n.md", in: b), "keep me, edited\n")
        }

        Check.test("snapshot commits without the network") {
            let origin = remote(), a = folder("a")
            write("# One\n", "one.md", in: a)
            let sync = engine(a, origin)
            _ = sync.bind()
            let before = commitCount(a)

            write("# One\nmore\n", "one.md", in: a)
            Check.expect(sync.snapshot())
            Check.equal(commitCount(a), before + 1)
            Check.expect(!sync.snapshot(), "nothing left to commit")
        }

        Check.test("a failure to reach the remote leaves the local notes alone") {
            let origin = remote(), a = folder("a")
            write("# One\n", "one.md", in: a)
            let sync = engine(a, origin)
            _ = sync.bind()

            try? FileManager.default.moveItem(at: origin, to: root.appendingPathComponent("moved-\(counter).git"))
            write("# One\nedited\n", "one.md", in: a)
            let outcome = sync.cycle()
            if case .failed = outcome {} else { Check.expect(false, "\(outcome)") }
            Check.equal(read("one.md", in: a), "# One\nedited\n")
        }
    }

    Check.suite("Git sync · verification") {

        Check.test("a reachable, writable repository passes every step") {
            let origin = remote()
            let result = GitSyncValidation.run(address: origin.path, runner: git)
            Check.expect(result.passed, "\(result.entries)")
            Check.expect(result.remoteIsEmpty)
            Check.equal(result.entries.map(\.step), GitSyncValidation.Step.allCases)
        }

        Check.test("it stops at the first thing that is wrong") {
            let missing = GitSyncValidation.run(
                address: root.appendingPathComponent("nope.git").path, runner: git
            )
            Check.expect(!missing.passed)
            Check.equal(missing.firstFailure?.step, .remoteReachable)

            let malformed = GitSyncValidation.run(address: "--evil", runner: git)
            Check.equal(malformed.firstFailure?.step, .addressFormat)

            let blank = GitSyncValidation.run(address: "  ", runner: git)
            Check.equal(blank.firstFailure?.step, .addressFormat)
        }

        Check.test("it reports the remote's default branch and whether a named one exists") {
            let origin = remote(), a = folder("a")
            write("# One\n", "one.md", in: a)
            _ = engine(a, origin).bind()

            let result = GitSyncValidation.run(address: origin.path, branch: "other", runner: git)
            Check.expect(result.passed, "\(result.entries)")
            Check.equal(result.remoteDefaultBranch, "main")
            Check.expect(!result.remoteIsEmpty)
            Check.expect(result.entries.last?.detail.contains("other") == true)
        }

        Check.test("it leaves nothing behind in the remote") {
            let origin = remote()
            _ = GitSyncValidation.run(address: origin.path, runner: git)
            Check.equal(git.run(["for-each-ref"], in: origin).stdout, "")
        }
    }
}
