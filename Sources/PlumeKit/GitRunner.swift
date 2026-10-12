import Foundation

/// Runs the system `git`, and nothing else.
///
/// **Authentication is whatever the user already has.** Plume asks for no password and stores none:
/// an SSH remote goes through the user's own `ssh-agent` and keys, an HTTPS one through whatever
/// credential helper their git is configured with (on macOS, `osxkeychain`). What this type adds is
/// the part a terminal supplies without anyone noticing — a human to answer a prompt — by making every
/// prompt fail fast instead. A background sync that waits on a password nobody can see is a sync that
/// hangs for ever.
///
/// Foundation only, so the whole sync engine can be driven from the test suite against real
/// repositories on disk.
public struct GitRunner: Sendable {

    public struct Result: Equatable, Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }

        /// Both streams, trimmed, for an error message or for classification.
        public var output: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// The git binary, or nil when this machine has none.
    public let executable: URL?

    /// Name and e-mail handed to commits when the user's own git config has none. Without them a
    /// first commit on a fresh Mac fails with "Please tell me who you are".
    public let fallbackIdentity: (name: String, email: String)

    /// Shell command ssh is invoked with, already carrying the non-interactive options.
    private let sshCommand: String

    public init(
        executable: URL? = GitRunner.locate(),
        fallbackIdentity: (name: String, email: String) = GitRunner.defaultIdentity()
    ) {
        self.executable = executable
        self.fallbackIdentity = fallbackIdentity
        self.sshCommand = executable.map(Self.nonInteractiveSSH(git:)) ?? "ssh"
    }

    public var isAvailable: Bool { executable != nil }

    // MARK: - Locating git

    /// Finds a working git without ever triggering the Command Line Tools installer.
    ///
    /// `/usr/bin/git` exists on every Mac, but on one without the Command Line Tools it is a stub
    /// that pops up an install dialog the moment it runs. `xcode-select -p` is the question that does
    /// not: it succeeds only when a developer directory is installed. Homebrew's git needs no such
    /// check and is tried second.
    public static func locate(fileManager: FileManager = .default) -> URL? {
        var candidates: [String] = []
        if developerDirectoryInstalled() { candidates.append("/usr/bin/git") }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func developerDirectoryInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public static func defaultIdentity() -> (name: String, email: String) {
        let device = Host.current().localizedName ?? "Mac"
        let slug = device.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        return ("Plume (\(device))", "plume@\(slug.isEmpty ? "mac" : slug).local")
    }

    /// The user's own ssh invocation with `BatchMode` added, so a missing key or a locked agent
    /// fails at once rather than waiting on a prompt.
    ///
    /// `StrictHostKeyChecking=accept-new` is trust-on-first-use: a host never seen before is recorded,
    /// a host whose key *changed* is still refused. Without it the first sync to a new server would
    /// die on "Host key verification failed" for a question only a terminal could have answered.
    private static func nonInteractiveSSH(git: URL) -> String {
        var base = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? ""
        if base.isEmpty {
            let probe = GitRunner.run(
                git: git,
                arguments: ["config", "--get", "core.sshCommand"],
                directory: nil,
                environment: [:],
                timeout: 10
            )
            base = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if base.isEmpty { base = "ssh" }
        return base + " -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"
    }

    // MARK: - Running

    /// Runs `git <arguments>` in `directory`.
    ///
    /// - Parameters:
    ///   - network: raises the timeout for commands that talk to a remote.
    ///   - identity: supplies a committer when the user's git has none. Only for commands that write
    ///     a commit.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL,
        network: Bool = false,
        identity: Bool = false
    ) -> Result {
        guard let executable else {
            return Result(status: 127, stdout: "", stderr: "git is not installed", timedOut: false)
        }

        var full: [String] = ["-c", "merge.conflictStyle=merge", "-c", "core.quotePath=false"]
        // The fallback is only for a machine whose git has no identity of its own: `-c` beats the
        // user's config, so passing it unconditionally would sign their commits as Plume.
        if identity, !hasIdentity(in: directory) {
            full += ["-c", "user.name=\(fallbackIdentity.name)", "-c", "user.email=\(fallbackIdentity.email)"]
        }
        full += arguments

        return Self.run(
            git: executable,
            arguments: full,
            directory: directory,
            environment: ["GIT_SSH_COMMAND": sshCommand],
            timeout: network ? 90 : 30
        )
    }

    private func hasIdentity(in directory: URL) -> Bool {
        guard let executable else { return false }
        func configured(_ key: String) -> Bool {
            !Self.run(
                git: executable, arguments: ["config", "--get", key], directory: directory,
                environment: [:], timeout: 10
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return configured("user.name") && configured("user.email")
    }

    static func run(
        git: URL,
        arguments: [String],
        directory: URL?,
        environment extra: [String: String],
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }

        var environment = ProcessInfo.processInfo.environment
        // No prompts of any kind: this runs with nobody to answer them.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["GCM_INTERACTIVE"] = "never"
        // Merges and commits must never open an editor.
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        // Refuses `ext::` and other transports that run a command, whatever the address says.
        environment["GIT_ALLOW_PROTOCOL"] = "https:http:ssh:git:file"
        // `GitSyncFailure.classify` reads git's English.
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Drained on their own threads: a child that fills a pipe's 64 KB buffer blocks until
        // somebody reads, and waiting for exit before reading would deadlock on a large diff.
        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                collected.set(pipe.fileHandleForReading.readDataToEndOfFile(), isOut: isOut)
                group.leave()
            }
        }

        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.wait()
            return Result(status: 127, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let timeoutFlag = TimeoutFlag()
        let killer = DispatchWorkItem {
            timeoutFlag.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: collected.out, as: UTF8.self),
            stderr: String(decoding: collected.err, as: UTF8.self),
            timedOut: timeoutFlag.value
        )
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var _out = Data(), _err = Data()
        var out: Data { lock.withLock { _out } }
        var err: Data { lock.withLock { _err } }
        func set(_ data: Data, isOut: Bool) {
            lock.withLock { if isOut { _out = data } else { _err = data } }
        }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }
}
