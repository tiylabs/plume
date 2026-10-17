import Foundation

/// One Git sync: the vault folder is a working tree, `origin` is the other end, and a cycle is
/// *commit what changed here, merge what changed there, push the result*.
///
/// **Merge, not rebase, and git's own conflict markers.** A note that both sides edited comes out as
/// an ordinary conflicted file — `<<<<<<<`, `=======`, `>>>>>>>` — in place. Nothing is overwritten
/// and nothing is dropped, which is the property the vault has everywhere else (decision 8). While any
/// file is still conflicted the engine does nothing to the remote: pushing a half-merged tree would
/// publish the markers.
///
/// **Not thread-safe by design.** One cycle at a time is the caller's job (`GitSyncController` runs
/// them on one serial queue); two interleaved cycles would race on the index.
public final class GitSyncEngine: @unchecked Sendable {

    public struct Activity: Equatable, Sendable {
        public var committed = false
        public var pulled = false
        public var pushed = false

        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        case synced(Activity)
        /// The files, relative to the vault, that still carry conflict markers.
        case conflicts([String])
        case failed(GitSyncFailure)
    }

    /// Written to `.git` once a cycle has completed against this remote. Until it exists, a merge may
    /// join two unrelated histories — the first sync of a folder that already has notes into a
    /// repository that already has content — and afterwards it may not, because histories that
    /// *became* unrelated mean the remote was rewritten, which is not something to merge silently.
    static let initializedMarker = "plume-sync-initialized"

    public let vault: URL
    public let remoteURL: String
    private let configuredBranch: String
    private let runner: GitRunner
    private let device: String
    private let now: @Sendable () -> Date

    private var resolvedBranch: String?

    /// Held around every step that writes the working tree or reads it into a commit — finishing a
    /// merge, committing, merging — so an agent API write cannot land in the middle of one. Fetch and
    /// push run outside it. See `VaultWriteGate`.
    private let gate: VaultWriteGate

    public init(
        vault: URL,
        remoteURL: String,
        branch: String = "",
        runner: GitRunner = GitRunner(),
        gate: VaultWriteGate = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gate = gate
        self.vault = vault
        self.remoteURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runner = runner
        self.device = Host.current().localizedName ?? "Mac"
        self.now = now
    }

    // MARK: - Setup

    /// Turns the vault into a repository with `origin` set, then runs the first cycle.
    ///
    /// This is `git init` (if needed), `git remote add origin <url>`, and a sync — in other words
    /// exactly what a person would type, with the same outcome when both sides already have content:
    /// their histories are merged, and a note that exists on both with different text is a conflict.
    public func bind() -> Outcome {
        guard runner.isAvailable else { return .failed(.gitMissing) }
        guard FileManager.default.fileExists(atPath: vault.path) else {
            return .failed(.repositoryState(L10n.t("sync.failure.folderMissing")))
        }

        let dotGit = vault.appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: dotGit.path) {
            // Inside somebody else's repository, `git init` here would nest one. Refuse rather than
            // quietly commit this folder into a project that is not about notes.
            let enclosing = git(["rev-parse", "--is-inside-work-tree"])
            if enclosing.succeeded, enclosing.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                return .failed(.repositoryState(L10n.t("sync.failure.nested")))
            }
            let initialised = git(["init", "--quiet"])
            guard initialised.succeeded else { return .failed(.other(initialised.output)) }
        }

        // A new remote is a new relationship: the first merge with it may join unrelated histories.
        try? FileManager.default.removeItem(at: dotGit.appendingPathComponent(Self.initializedMarker))

        let remote = git(["remote", "get-url", "origin"])
        if !remote.succeeded {
            let added = git(["remote", "add", "origin", remoteURL])
            guard added.succeeded else { return .failed(.other(added.output)) }
        } else if remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != remoteURL {
            let changed = git(["remote", "set-url", "origin", remoteURL])
            guard changed.succeeded else { return .failed(.other(changed.output)) }
        }

        excludeNoise()

        // An empty repository starts on whatever git's default is — usually `master`. Point it at the
        // branch this sync will use, so the first commit lands there rather than on a stranger.
        if !hasCommits, let branch = branchForBinding() {
            _ = git(["symbolic-ref", "HEAD", "refs/heads/\(branch)"])
        }
        resolvedBranch = nil

        return cycle()
    }

    /// The `origin` URL of a repository already in the vault, so the UI can say it is about to change.
    public func existingOrigin() -> String? {
        let result = git(["remote", "get-url", "origin"])
        guard result.succeeded else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Whether the vault already has a `.git` folder of its own.
    public var isRepository: Bool {
        FileManager.default.fileExists(atPath: vault.appendingPathComponent(".git").path)
    }

    /// Keeps Finder and sync-daemon litter out of commits. In `.git/info/exclude` rather than a
    /// committed `.gitignore`: it is local, so it can never conflict with the remote's own and never
    /// adds a file to a repository the user may share with others.
    private func excludeNoise() {
        let url = vault.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let wanted = [".DS_Store", ".dat.nosync*", ".*.icloud"]
        let missing = wanted.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let block = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
            + "# Plume\n" + missing.joined(separator: "\n") + "\n"
        try? (existing + block).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - A cycle

    /// Commit, merge, push. Safe to call repeatedly; does nothing when nothing changed.
    public func cycle() -> Outcome {
        guard runner.isAvailable else { return .failed(.gitMissing) }
        guard FileManager.default.fileExists(atPath: vault.path) else {
            return .failed(.repositoryState(L10n.t("sync.failure.folderMissing")))
        }
        guard isRepository else {
            return .failed(.repositoryState(L10n.t("sync.failure.notBound")))
        }

        var activity = Activity()

        // 1. A merge left open by an earlier cycle, or by the person resolving it.
        switch gate.withGate({ finishMergeIfResolved() }) {
        case .done: break
        case .conflicts(let files): return .conflicts(files)
        case .failed(let failure): return .failed(failure)
        }

        // 2. What is on the other end.
        let fetched = git(["fetch", "--prune", "--quiet", "origin"], network: true)
        guard fetched.succeeded else {
            return .failed(.classify(output: fetched.output, timedOut: fetched.timedOut))
        }
        let branch = targetBranch()

        // 3. What is here — committed first, so the merge below is between two commits and a clash
        //    shows up as markers instead of git refusing to start.
        switch gate.withGate({ commitLocalChanges() }) {
        case .success(let committed): activity.committed = committed
        case .failure(let failure): return .failed(failure)
        }

        // 4 and 5, retried once if somebody pushed between our fetch and our push.
        for attempt in 0..<2 {
            switch gate.withGate({ integrateRemote(branch: branch, activity: &activity) }) {
            case .done: break
            case .conflicts(let files): return .conflicts(files)
            case .failed(let failure): return .failed(failure)
            }

            switch pushIfAhead(branch: branch) {
            case .success(let pushed):
                activity.pushed = activity.pushed || pushed
                markInitialized()
                return .synced(activity)
            case .failure(let failure):
                guard case .rejected = failure, attempt == 0 else { return .failed(failure.failure) }
                let refetched = git(["fetch", "--prune", "--quiet", "origin"], network: true)
                guard refetched.succeeded else {
                    return .failed(.classify(output: refetched.output, timedOut: refetched.timedOut))
                }
            }
        }
        return .failed(.other(L10n.t("sync.failure.rejected")))
    }

    /// Resolves what can be resolved without the network, for the moment after somebody edited a
    /// conflicted note. Cheap enough to run on every change while conflicts stand.
    public func recheckConflicts() -> Outcome {
        switch gate.withGate({ finishMergeIfResolved() }) {
        case .done: return .synced(Activity())
        case .conflicts(let files): return .conflicts(files)
        case .failed(let failure): return .failed(failure)
        }
    }

    /// Commits whatever changed, without touching the network. Quit calls this so that the last edits
    /// are in history even if the next launch is the one that pushes them.
    @discardableResult
    public func snapshot() -> Bool {
        guard runner.isAvailable, isRepository, !isMergeInProgress, conflictedFiles().isEmpty else {
            return false
        }
        if case .success(let committed) = gate.withGate({ commitLocalChanges() }) { return committed }
        return false
    }

    // MARK: - Conflicts

    /// Files git still lists as unmerged.
    public func conflictedFiles() -> [String] {
        let result = git(["diff", "--name-only", "--diff-filter=U"])
        guard result.succeeded else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    public var isMergeInProgress: Bool {
        FileManager.default.fileExists(atPath: gitPath("MERGE_HEAD").path)
    }

    private enum MergeState {
        case done
        case conflicts([String])
        case failed(GitSyncFailure)
    }

    /// Stages the files whose markers are gone and, once none are left, commits the merge.
    ///
    /// A conflicted file that never had markers — one side deleted it, or it is binary — is accepted
    /// as it stands: the side git left in the folder is the side that has content, so nothing is
    /// lost, and asking a person to resolve a conflict they cannot see in a text editor would be a
    /// dead end.
    private func finishMergeIfResolved() -> MergeState {
        for state in ["rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        where FileManager.default.fileExists(atPath: gitPath(state).path) {
            return .failed(.repositoryState(L10n.t("sync.failure.inProgress")))
        }

        let merging = isMergeInProgress
        let unmerged = conflictedFiles()
        guard merging || !unmerged.isEmpty else { return .done }

        var unresolved: [String] = []
        for file in unmerged {
            let url = vault.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path), ConflictMarkers.isPresent(inFileAt: url) {
                unresolved.append(file)
                continue
            }
            let staged = git(["add", "-A", "--", file])
            if !staged.succeeded { return .failed(.classify(output: staged.output)) }
        }
        if !unresolved.isEmpty { return .conflicts(unresolved) }

        if merging {
            let committed = git(["commit", "--no-edit", "--quiet"], identity: true)
            if !committed.succeeded {
                let stillUnmerged = conflictedFiles()
                if !stillUnmerged.isEmpty { return .conflicts(stillUnmerged) }
                return .failed(.classify(output: committed.output))
            }
        }
        return .done
    }

    // MARK: - Commit

    private func commitLocalChanges() -> Swift.Result<Bool, GitSyncFailure> {
        let status = git(["status", "--porcelain"])
        guard status.succeeded else { return .failure(.classify(output: status.output)) }
        guard !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(false)
        }

        let added = git(["add", "-A"])
        guard added.succeeded else { return .failure(.classify(output: added.output)) }

        // Ignored files can make `status` non-empty before `add` and leave nothing staged after.
        let staged = git(["diff", "--cached", "--name-only"])
        let count = staged.stdout.split(whereSeparator: \.isNewline).count
        guard count > 0 else { return .success(false) }

        let stamp = ISO8601DateFormatter().string(from: now())
        let message = "Plume sync · \(count) \(count == 1 ? "note" : "notes") · \(device) · \(stamp)"
        let committed = git(["commit", "--quiet", "-m", message], identity: true)
        guard committed.succeeded else { return .failure(.classify(output: committed.output)) }
        return .success(true)
    }

    // MARK: - Merge

    private func integrateRemote(branch: String, activity: inout Activity) -> MergeState {
        let remoteRef = "refs/remotes/origin/\(branch)"
        guard git(["rev-parse", "--verify", "--quiet", remoteRef]).succeeded else {
            return .done  // an empty remote has nothing to bring in
        }

        guard hasCommits else {
            // Nothing committed here at all, so there is nothing to merge *with*: adopt the remote.
            let adopted = git(["checkout", "--quiet", "-B", branch, "origin/\(branch)"])
            guard adopted.succeeded else { return .failed(.classify(output: adopted.output)) }
            activity.pulled = true
            return .done
        }

        let behind = git(["rev-list", "--count", "HEAD..\(remoteRef)"])
        guard behind.succeeded else { return .failed(.classify(output: behind.output)) }
        guard (Int(behind.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else {
            return .done
        }

        var arguments = ["merge", "--no-edit", "--quiet", "-m", "Plume sync · merge · \(device)"]
        let related = git(["merge-base", "HEAD", remoteRef]).succeeded
        if !related {
            guard !isInitialized else {
                return .failed(.repositoryState(L10n.t("sync.failure.unrelated")))
            }
            arguments.append("--allow-unrelated-histories")
        }
        // Spelled the way a person would, because it is what ends up after `>>>>>>>` in a note.
        arguments.append("origin/\(branch)")

        let merged = git(arguments, identity: true)
        activity.pulled = true
        if merged.succeeded { return .done }

        if conflictedFiles().isEmpty && !isMergeInProgress {
            // Refused before it started — typically an untracked file in the way. Nothing was
            // changed, so there is nothing to clean up.
            return .failed(.classify(output: merged.output))
        }
        return finishMergeIfResolved()
    }

    // MARK: - Push

    private enum PushFailure: Error {
        case rejected
        case failed(GitSyncFailure)

        var failure: GitSyncFailure {
            switch self {
            case .rejected: return .other(L10n.t("sync.failure.rejected"))
            case .failed(let failure): return failure
            }
        }
    }

    private func pushIfAhead(branch: String) -> Swift.Result<Bool, PushFailure> {
        guard hasCommits else { return .success(false) }

        let remoteRef = "refs/remotes/origin/\(branch)"
        let remoteExists = git(["rev-parse", "--verify", "--quiet", remoteRef]).succeeded
        if remoteExists {
            let ahead = git(["rev-list", "--count", "\(remoteRef)..HEAD"])
            guard (Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else {
                return .success(false)
            }
        }

        let pushed = git(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], network: true)
        if pushed.succeeded { return .success(true) }

        let text = pushed.output.lowercased()
        // The last two are how a server words the same race when the other push lands *between* ours
        // being negotiated and being applied — which is the usual shape of it on a busy remote, and
        // not a fault in the repository.
        let lostRace = text.contains("non-fast-forward") || text.contains("fetch first")
            || text.contains("[rejected]") || text.contains("but expected")
            || text.contains("failed to update ref")
        if lostRace, !text.contains("protected branch"), !text.contains("pre-receive") {
            return .failure(.rejected)
        }
        return .failure(.failed(.classify(output: pushed.output, timedOut: pushed.timedOut, pushing: true)))
    }

    // MARK: - Branch

    /// The remote branch this sync follows: the configured one, else the remote's default, else the
    /// branch the repository is already on, else `main`.
    private func targetBranch() -> String {
        if let resolvedBranch { return resolvedBranch }
        let branch = !configuredBranch.isEmpty
            ? configuredBranch
            : (remoteDefaultBranch() ?? localBranch() ?? "main")
        resolvedBranch = branch
        return branch
    }

    private func branchForBinding() -> String? {
        if !configuredBranch.isEmpty { return configuredBranch }
        return remoteDefaultBranch() ?? "main"
    }

    private func remoteDefaultBranch() -> String? {
        let result = git(["ls-remote", "--symref", "origin", "HEAD"], network: true)
        guard result.succeeded else { return nil }
        for line in result.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("ref:") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[1].hasPrefix("refs/heads/") {
                return String(parts[1].dropFirst("refs/heads/".count))
            }
        }
        return nil
    }

    private func localBranch() -> String? {
        let result = git(["symbolic-ref", "--short", "-q", "HEAD"])
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !name.isEmpty ? name : nil
    }

    // MARK: - Helpers

    private var hasCommits: Bool {
        git(["rev-parse", "--verify", "--quiet", "HEAD"]).succeeded
    }

    private var isInitialized: Bool {
        FileManager.default.fileExists(atPath: gitPath(Self.initializedMarker).path)
    }

    private func markInitialized() {
        FileManager.default.createFile(atPath: gitPath(Self.initializedMarker).path, contents: Data())
    }

    private func gitPath(_ name: String) -> URL {
        vault.appendingPathComponent(".git").appendingPathComponent(name)
    }

    @discardableResult
    private func git(_ arguments: [String], network: Bool = false, identity: Bool = false) -> GitRunner.Result {
        runner.run(arguments, in: vault, network: network, identity: identity)
    }
}
