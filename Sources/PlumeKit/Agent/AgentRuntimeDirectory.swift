import CryptoKit
import Darwin
import Foundation

/// Where the app's agent socket lives, and how both ends agree on it.
///
/// **The per-user temporary directory, found with `confstr`, not `$TMPDIR`.** An agent may clear or
/// rewrite its child processes' environment, and a helper that computed its path from a different
/// `$TMPDIR` than the app's would look for the socket somewhere the app never put it. `confstr
/// (_CS_DARWIN_USER_TEMP_DIR)` asks the system, and answers the same for every process of the user.
///
/// **Short.** A Unix socket path is limited to 104 bytes (`sun_path`), and the Application Support
/// path is long enough with a long user name to run past it. Measured here:
/// `/var/folders/xx/<28 chars>/T/` is 49 bytes; `plume-agent.<profile>/agent.sock` adds at most 28.
///
/// **Checked, both ends.** The directory must be a real directory (not a symlink), owned by this
/// user, `0700`; the socket must be a socket owned by this user. A planted symlink or a same-named
/// file in a shared place would otherwise redirect a credential to someone else's listener.
public struct AgentRuntimeDirectory: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The directory for `profile`, under the user's temporary directory.
    public static func standard(profile: BuildProfile) -> AgentRuntimeDirectory {
        AgentRuntimeDirectory(directory: userTemporaryDirectory().appendingPathComponent("plume-agent.\(profile.runtimeKey)"))
    }

    public var socketURL: URL { directory.appendingPathComponent("agent.sock") }
    public var lockURL: URL { directory.appendingPathComponent("owner.lock") }
    public var ownerURL: URL { directory.appendingPathComponent("owner.json") }

    public static func userTemporaryDirectory() -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            }
        }
        // Only reached without a user temp dir, which a logged-in macOS session always has.
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Creates the directory `0700` if missing; throws if what is there is not ours to use.
    public func prepare() throws {
        try DurableFile.ensurePrivateDirectory(directory)
        try verifyDirectory()
    }

    /// The directory exists, is a directory, is ours, and nobody else can enter it.
    public func verifyDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw AgentFailure(.appNotReady, "the agent runtime directory does not exist")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw AgentFailure(.connectionBlocked, "the agent runtime directory is not private to this user: \(directory.path)")
        }
    }

    /// What is at the socket path: nothing, our socket, or something that must not be touched.
    public enum SocketStatus: Equatable {
        case absent
        case ours
        case foreign
    }

    public func socketStatus() -> SocketStatus {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else { return .absent }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { return .foreign }
        return .ours
    }
}

extension BuildProfile {
    /// Names the runtime directory. Short on purpose — see `AgentRuntimeDirectory`.
    public var runtimeKey: String {
        switch self {
        case .release: "release"
        case .dev: "dev"
        }
    }

    public init?(runtimeKey: String) {
        switch runtimeKey {
        case "release": self = .release
        case "dev": self = .dev
        default: return nil
        }
    }
}

/// Which installed copy of Plume an app or helper belongs to: a hash of the bundle's resolved path.
///
/// Two copies of the same profile (one in /Applications, one in ~/Downloads) share a profile and so
/// a runtime directory, but must not both act as the writer; the handshake compares this so a helper
/// from one copy is told it is talking to the other.
public enum AgentInstance {
    public static func identifier(bundleURL: URL) -> String {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The process-lifetime lock that makes one app the owner of a profile's agent socket.
///
/// `flock` rather than a pid file: the kernel releases it when the process dies however it dies, so
/// a crash never leaves a stale owner that has to be guessed at.
public final class AgentOwnerLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Takes the lock, or returns nil if another live process holds it.
    public static func acquire(_ runtime: AgentRuntimeDirectory) -> AgentOwnerLock? {
        let fd = open(runtime.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return AgentOwnerLock(fd: fd)
    }

    /// Whether some live process holds the lock, without taking it for long.
    public static func isHeld(_ runtime: AgentRuntimeDirectory) -> Bool {
        let fd = open(runtime.lockURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Written beside the lock by the owner, so a helper can tell "another installed copy owns this
/// profile" before it launches its own copy for nothing.
public struct AgentOwnerRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var instance: String
    public var appVersion: String
    public var bundlePath: String

    public init(pid: Int32, instance: String, appVersion: String, bundlePath: String) {
        self.pid = pid
        self.instance = instance
        self.appVersion = appVersion
        self.bundlePath = bundlePath
    }

    enum CodingKeys: String, CodingKey {
        case pid, instance
        case appVersion = "app_version"
        case bundlePath = "bundle_path"
    }
}
