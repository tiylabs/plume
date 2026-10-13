import Foundation

/// Why a sync did not complete.
///
/// A closed set, because each case is a different thing for the user to do: fix a key, ask for write
/// access, wait for the network, or look at the repository.
public enum GitSyncFailure: Error, Equatable, Sendable {
    case gitMissing
    case authenticationFailed
    case noWriteAccess
    case network
    case repositoryNotFound
    case branchMissing
    /// The local repository is in a state Plume will not touch — mid-rebase, locked, nested in
    /// another repository. The detail is git's own words.
    case repositoryState(String)
    case other(String)

    /// Failures that cure themselves: the Wi-Fi comes back. These are retried quietly and only
    /// surface after `GitSyncFailureTracker.transientThreshold` in a row; everything else is
    /// something the user has to do, and waiting would only hide it.
    public var isTransient: Bool { self == .network }

    /// Reads git's English output — `GitRunner` pins `LC_ALL=C` so it is always English.
    ///
    /// Order matters: "unable to access" prefixes HTTP errors that are really auth or permission
    /// problems, so the specific patterns come before the connectivity ones.
    public static func classify(output: String, timedOut: Bool = false, pushing: Bool = false) -> GitSyncFailure {
        if timedOut { return .network }
        let text = output.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("index.lock", "another git process", "unable to create", "cannot lock ref",
               "rebase in progress", "you have not concluded your merge", "not a git repository",
               "unfinished merge") {
            return .repositoryState(firstLine(of: output))
        }
        if has("couldn't find remote ref", "remote branch", "not found in upstream") && !has("repository not found") {
            return .branchMissing
        }
        if has("repository not found", "does not appear to be a git repository",
               "returned error: 404", "project not found", "repository does not exist") {
            return .repositoryNotFound
        }
        if pushing, has("permission to", "denied to", "returned error: 403", "protected branch",
                        "pre-receive hook declined", "you are not allowed", "write access") {
            return .noWriteAccess
        }
        if has("permission denied (publickey", "permission denied, please try again",
               "authentication failed", "could not read username", "could not read password",
               "terminal prompts disabled", "host key verification failed", "invalid credentials",
               "returned error: 401", "returned error: 403", "access denied", "bad credentials",
               "remote host identification has changed", "no supported authentication methods") {
            return .authenticationFailed
        }
        if has("could not resolve host", "could not resolve hostname", "connection refused",
               "connection timed out", "operation timed out", "network is unreachable",
               "no route to host", "failed to connect", "connection reset", "early eof",
               "unable to access", "ssl", "kex_exchange_identification", "ssh: connect to host",
               "the remote end hung up", "transfer closed", "temporary failure in name resolution") {
            return .network
        }
        return .other(firstLine(of: output))
    }

    private static func firstLine(of output: String) -> String {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// One line for the menu and the Storage tab, in the language in effect.
    public var message: String {
        switch self {
        case .gitMissing: return L10n.t("sync.failure.gitMissing")
        case .authenticationFailed: return L10n.t("sync.failure.auth")
        case .noWriteAccess: return L10n.t("sync.failure.noWrite")
        case .network: return L10n.t("sync.failure.network")
        case .repositoryNotFound: return L10n.t("sync.failure.notFound")
        case .branchMissing: return L10n.t("sync.failure.branch")
        case .repositoryState(let detail):
            return detail.isEmpty
                ? L10n.t("sync.failure.state.plain")
                : L10n.t("sync.failure.state", ["detail": detail])
        case .other(let detail):
            return detail.isEmpty
                ? L10n.t("sync.failure.other.plain")
                : L10n.t("sync.failure.other", ["detail": detail])
        }
    }
}
