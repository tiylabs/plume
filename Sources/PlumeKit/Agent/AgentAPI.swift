import Foundation

/// The versions and limits of the local agent API, in one place.
///
/// Three version numbers move independently, because they describe three different promises:
///
/// - `apiVersion` is what a tool result looks like. It is in every result so an agent can tell which
///   shape it is reading; an added optional field does not bump it.
/// - `ipcMajorVersion` is the framing and handshake between the helper and the app. A helper and an
///   app that disagree on it refuse to talk rather than guess, which is the case after an update
///   while an old helper process is still running under an agent.
/// - `formatVersion` is the Markdown capability description the writing context hands out. It moves
///   when what the editor actually renders moves, and only then.
///
/// The app version is deliberately not one of them: an updated app with an MCP process that has not
/// been restarted yet is the ordinary state after every update, and refusing it would make every
/// update look like a failure.
public enum AgentAPI {
    public static let apiVersion = 1
    public static let ipcMajorVersion = 1
    public static let formatVersion = 1

    /// The environment variable the helper reads its credential from. It is written into the user's
    /// agent configuration, so it is a frozen name.
    public static let tokenEnvironmentKey = "PLUME_CLI_TOKEN"

    /// The helper's file name inside `Contents/MacOS/`. Also written into agent configurations.
    public static let helperExecutableName = "plume-cli"
}

/// Every bound the API enforces. Public numbers, documented in the connection help, and checked by
/// the contract tests — an agent should be able to plan around them rather than discover them.
///
/// Over a limit is always an error, never a truncation: a note cut short and then modified would
/// lose its tail on save, and a list cut short silently looks like a vault that ends early.
public enum AgentLimits {
    public static let listDefaultPage = 20
    public static let listMaxPage = 100
    /// One note's body, in UTF-8 bytes.
    public static let noteMaxBytes = 1 << 20
    public static let maxChangesPerRequest = 32
    /// One IPC frame. Bigger than a note so a 1 MiB note plus its JSON escaping still fits.
    public static let ipcMaxFrameBytes = 4 << 20
    /// How long the app waits for a helper to take one frame before it drops the connection. A
    /// helper that reads takes a full frame in milliseconds; one that has stopped (⌃Z on the agent
    /// stops the helper with it) reconnects when it resumes.
    public static let ipcSendTimeout: TimeInterval = 5
    /// What may wait unsent on one connection: four full frames. A helper further behind than that
    /// is not reading, and is dropped rather than buffered for.
    public static let ipcMaxQueuedBytes = 4 * ipcMaxFrameBytes
    public static let maxExamples = 3
    /// Example bodies in one writing context, together.
    public static let examplesMaxBytes = 32 << 10
    /// Writes (create + modify + restore) per minute, across all connections of one profile. There
    /// is no per-write confirmation, so this is what stops a runaway agent loop from filling the
    /// vault before anyone notices.
    public static let writesPerMinute = 30
    /// How long a read's version stays usable for a modify.
    public static let versionLifetime: TimeInterval = 10 * 60
    /// How many versions are kept at once; the oldest are evicted first.
    public static let versionCacheCapacity = 512
    /// How long a list or search cursor stays usable.
    public static let cursorLifetime: TimeInterval = 10 * 60
    public static let cursorCacheCapacity = 64
    /// Preferences file and each template, in bytes.
    public static let writingFileMaxBytes = 64 << 10
    /// An operation's full result and its restore snapshots.
    public static let operationFullRetention: TimeInterval = 7 * 24 * 3600
    /// The compact record that keeps a used request ID from being run again.
    public static let operationCompactRetention: TimeInterval = 90 * 24 * 3600
    /// How long the helper waits for a launched app to answer.
    public static let readyTimeout: TimeInterval = 5
    /// Between launch attempts the system refused, inside `readyTimeout`. The refusal right after
    /// Plume exits clears within about 0.3 s (measured), so a few retries cover it.
    public static let launchRetryInterval: TimeInterval = 0.25
    /// An ordinary request, end to end.
    public static let requestTimeout: TimeInterval = 10
    /// A read that asked for an iCloud download. Measured downloads of a tiny file took 5–20 s.
    public static let downloadTimeout: TimeInterval = 90
    /// How long an API write waits for a Git cycle to leave the working tree.
    public static let worktreeGateTimeout: TimeInterval = 5
}
