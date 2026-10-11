import Foundation

/// The Storage tab's *Verify* button: can this address be synced to, from this Mac, right now?
///
/// Each step is a different thing the person might have to fix, so they are reported separately and
/// the run stops at the first one that fails — "can't write" means nothing until "can connect" has
/// passed.
///
/// Nothing here touches the notes folder or the remote's contents. The probes run in a throwaway
/// repository, and the write check is a `push --dry-run` to a branch name that does not exist, which
/// authenticates and checks permission without sending anything.
public struct GitSyncValidation: Equatable, Sendable {

    public enum Step: String, CaseIterable, Sendable {
        case gitInstalled
        case addressFormat
        case remoteReachable
        case writeAccess
        case branch

        public var label: String { L10n.t("sync.verify.step.\(rawValue)") }
    }

    public struct Entry: Equatable, Sendable {
        public let step: Step
        public let passed: Bool
        public let detail: String
    }

    public private(set) var entries: [Entry] = []

    /// The remote's default branch, when it has one.
    public private(set) var remoteDefaultBranch: String?

    /// Whether the remote has no branches at all, so the first sync will simply push.
    public private(set) var remoteIsEmpty = false

    public var passed: Bool {
        entries.count == Step.allCases.count && entries.allSatisfy(\.passed)
    }

    public var firstFailure: Entry? { entries.first { !$0.passed } }

    /// Runs every step against `address` and, if given, `branch`. Blocks for up to a couple of
    /// network round trips: call it off the main thread.
    public static func run(
        address rawAddress: String,
        branch rawBranch: String = "",
        runner: GitRunner = GitRunner()
    ) -> GitSyncValidation {
        var result = GitSyncValidation()
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. git
        guard runner.isAvailable else {
            result.entries.append(.init(step: .gitInstalled, passed: false, detail: GitSyncFailure.gitMissing.message))
            return result
        }
        result.entries.append(.init(step: .gitInstalled, passed: true, detail: ""))

        // 2. the address, as text
        if let problem = GitRemoteAddress.problem(with: address) {
            let key: String
            switch problem {
            case .empty: key = "sync.verify.address.empty"
            case .unsupported: key = "sync.verify.address.unsupported"
            case .embeddedCredentials: key = "sync.verify.address.credentials"
            }
            result.entries.append(.init(step: .addressFormat, passed: false, detail: L10n.t(key)))
            return result
        }
        result.entries.append(.init(step: .addressFormat, passed: true, detail: ""))

        // Probes run in a throwaway repository so the notes folder is never involved.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-verify-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            result.entries.append(.init(step: .remoteReachable, passed: false, detail: error.localizedDescription))
            return result
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard runner.run(["init", "--quiet"], in: scratch).succeeded,
              runner.run(["remote", "add", "origin", address], in: scratch).succeeded else {
            result.entries.append(.init(step: .remoteReachable, passed: false, detail: GitSyncFailure.other("").message))
            return result
        }

        // 3. reachable and authenticated
        let listing = runner.run(["ls-remote", "--symref", "origin", "HEAD", "refs/heads/*"], in: scratch, network: true)
        guard listing.succeeded else {
            let failure = GitSyncFailure.classify(output: listing.output, timedOut: listing.timedOut)
            result.entries.append(.init(step: .remoteReachable, passed: false, detail: failure.message))
            return result
        }
        result.entries.append(.init(step: .remoteReachable, passed: true, detail: ""))

        var heads: [String] = []
        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if line.hasPrefix("ref:"), parts.count >= 2, parts[1].hasPrefix("refs/heads/") {
                result.remoteDefaultBranch = String(parts[1].dropFirst("refs/heads/".count))
            } else if parts.count >= 2, parts[1].hasPrefix("refs/heads/") {
                heads.append(String(parts[1].dropFirst("refs/heads/".count)))
            }
        }
        result.remoteIsEmpty = heads.isEmpty

        // 4. write permission — a dry run authenticates against the receive side, which is where a
        //    read-only deploy key is turned away, and sends nothing.
        _ = runner.run(["commit", "--allow-empty", "--quiet", "-m", "probe"], in: scratch, identity: true)
        let probe = runner.run(
            ["push", "--dry-run", "origin", "HEAD:refs/heads/plume-verify-probe"],
            in: scratch, network: true
        )
        guard probe.succeeded else {
            let failure = GitSyncFailure.classify(output: probe.output, timedOut: probe.timedOut, pushing: true)
            // An auth failure here is a write failure: the read just worked a moment ago.
            let shown: GitSyncFailure = failure == .authenticationFailed ? .noWriteAccess : failure
            result.entries.append(.init(step: .writeAccess, passed: false, detail: shown.message))
            return result
        }
        result.entries.append(.init(step: .writeAccess, passed: true, detail: ""))

        // 5. the branch
        let target = branch.isEmpty ? (result.remoteDefaultBranch ?? "main") : branch
        let exists = heads.contains(target) || result.remoteDefaultBranch == target
        let detail = exists
            ? L10n.t("sync.verify.branch.exists", ["branch": target])
            : L10n.t("sync.verify.branch.willCreate", ["branch": target])
        result.entries.append(.init(step: .branch, passed: true, detail: detail))
        return result
    }
}
