import Foundation

/// The user's Git-sync choices: whether it is on, and where it goes.
///
/// Stored in `settings.json` like everything else the user chooses. There is deliberately no field for
/// a password or a token — authentication is the system git's, and whatever it is configured with
/// (ssh keys, the macOS keychain) is what runs. See `GitRunner`.
public struct GitSyncSettings: Codable, Equatable, Sendable {

    public var enabled: Bool

    /// The remote's address, exactly as `git remote add origin <url>` takes it.
    public var remoteURL: String

    /// Empty means the remote's own default branch.
    public var branch: String

    public init(enabled: Bool = false, remoteURL: String = "", branch: String = "") {
        self.enabled = enabled
        self.remoteURL = remoteURL
        self.branch = branch
    }

    /// As forgiving as `Settings` itself: this file is meant to be hand-edited, and one bad field
    /// should cost that field, not the launch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        remoteURL = (try c.decodeIfPresent(String.self, forKey: .remoteURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        branch = (try c.decodeIfPresent(String.self, forKey: .branch) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enabled with an address. A hand edit that flips `enabled` on with no URL is not a sync.
    public var isActive: Bool { enabled && !remoteURL.isEmpty }
}

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

/// What the sync is doing, as the app shows it.
public enum GitSyncStatus: Equatable, Sendable {
    /// Between cycles. `lastSync` is nil until the first one completes in this process.
    case idle(lastSync: Date?)
    case syncing
    /// A merge stopped on files that need a person. Sync is paused until they are resolved.
    case conflicts([String])
    case failed(GitSyncFailure)

    public var isSyncing: Bool { self == .syncing }
}

/// Decides when a failure is worth a red dot.
///
/// A laptop lid closing mid-cycle, a train tunnel, a captive portal: network trouble is the commonest
/// failure by far and the one that fixes itself, so lighting the menu bar for the first one would
/// make the dot mean nothing. Everything else — a revoked key, a missing repository, a locked index —
/// will not fix itself and surfaces on the first occurrence.
public struct GitSyncFailureTracker: Equatable, Sendable {

    /// Three five-minute cycles: about a quarter of an hour offline before it is called a failure.
    public static let transientThreshold = 3

    public private(set) var consecutiveTransient = 0

    public init() {}

    /// Records a cycle's result and returns the failure to show, if any.
    public mutating func record(_ failure: GitSyncFailure?) -> GitSyncFailure? {
        guard let failure else {
            consecutiveTransient = 0
            return nil
        }
        guard failure.isTransient else {
            consecutiveTransient = 0
            return failure
        }
        consecutiveTransient += 1
        return consecutiveTransient >= Self.transientThreshold ? failure : nil
    }

    public mutating func reset() { consecutiveTransient = 0 }
}

/// Which dot the menu bar icon wears.
///
/// One at a time, most urgent first: a failure means the sync is not running at all, a conflict means
/// it is paused waiting for you, and an available update is a nicety. Showing the least urgent of them
/// while a worse one stands would be the icon lying by omission.
public enum MenuBarDot: Equatable, Sendable {
    case none
    case update
    case conflict
    case failure

    public static func resolve(sync: GitSyncStatus?, updateAvailable: Bool) -> MenuBarDot {
        switch sync {
        case .failed: return .failure
        case .conflicts: return .conflict
        default: return updateAvailable ? .update : MenuBarDot.none
        }
    }
}

/// Conflict markers, as git writes them into a file it could not merge.
public enum ConflictMarkers {

    /// Whether `text` still carries a `<<<<<<<` or `>>>>>>>` line.
    ///
    /// Only those two, and only at the start of a line: `=======` is a legitimate Markdown setext
    /// underline, and a note about git may quote a marker mid-line or inside indentation. Either
    /// remaining half means the person has not finished — a half-deleted block is not resolved.
    public static func isPresent(in text: String) -> Bool {
        // `isNewline`, not `"\n"`: Swift reads `\r\n` as a single character, so splitting on `"\n"`
        // never splits a file with Windows line endings and every marker after the first goes unseen.
        for line in text.split(whereSeparator: \.isNewline) {
            for marker in ["<<<<<<<", ">>>>>>>"] where line.hasPrefix(marker) {
                let rest = line.dropFirst(marker.count)
                if rest.isEmpty || rest.first == " " || rest.first == "\r" { return true }
            }
        }
        return false
    }

    public static func isPresent(inFileAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isPresent(in: String(decoding: data, as: UTF8.self))
    }
}

/// Whether an address is one `git remote add` should be handed.
public enum GitRemoteAddress {

    public enum Problem: Equatable, Sendable {
        case empty
        case unsupported
        /// `https://user:token@host/…` — the token would be written in plain text to
        /// `settings.json` and `.git/config`. Refused; the credential helper is the place for it.
        case embeddedCredentials
    }

    /// nil when the address is acceptable.
    public static func problem(with address: String) -> Problem? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }
        // A leading dash would be read by git as an option, and whitespace is never in an address.
        guard !value.hasPrefix("-"), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .unsupported
        }

        if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
           value.contains("://") {
            guard ["https", "http", "ssh", "git", "file"].contains(scheme) else { return .unsupported }
            if scheme == "http" || scheme == "https", components.password != nil {
                return .embeddedCredentials
            }
            if scheme != "file", (components.host ?? "").isEmpty { return .unsupported }
            return nil
        }
        // scp-like: user@host:path/to/repo.git
        if let colon = value.firstIndex(of: ":"), !value.hasPrefix("/"), !value.contains("::") {
            let host = value[..<colon]
            let path = value[value.index(after: colon)...]
            return !host.isEmpty && !path.isEmpty && !host.contains("/") ? nil : .unsupported
        }
        // A path on this Mac — a bare repository on a NAS mount, or a test fixture.
        if value.hasPrefix("/") { return nil }
        return .unsupported
    }
}
