import Foundation

/// The local agent connection's switch and credential, for one profile.
///
/// Kept in `Agent/` under Application Support, not in `settings.json`: the credential must not sit in
/// a file people paste into bug reports, and the permission travels with it — revoking one without
/// the other is a state with no meaning.
///
/// - `access.json`: the permission and the authorisation generation.
/// - `token`: the credential, `0600`.
///
/// Not the Keychain, for two measured reasons. The credential is written in plain text into the
/// agent's own configuration anyway, readable by every process of this user, so the Keychain would
/// add no protection; and a Dev build is ad-hoc signed, its signature changes on every rebuild, and
/// each change makes the Keychain ask for permission to read the old item — a prompt in an app that
/// otherwise never asks for any. The credential's job is to show a client was configured by the
/// person, not to defend against processes that could read the configuration file themselves.
public final class AgentAccessStore: @unchecked Sendable {

    public struct Access: Codable, Sendable, Equatable {
        public var permission: AgentPermission
        /// Changes when access is revoked or the history is cleared. Request IDs and operations are
        /// scoped to it, so a credential from before cannot query or retry into what came after.
        public var generation: String

        public init(permission: AgentPermission = .off, generation: String = UUID().uuidString.lowercased()) {
            self.permission = permission
            self.generation = generation
        }
    }

    public let directory: URL
    private let lock = NSLock()
    private var cached: Access?

    public init(directory: URL) {
        self.directory = directory
    }

    private var accessURL: URL { directory.appendingPathComponent("access.json") }
    public var tokenURL: URL { directory.appendingPathComponent("token") }

    public var access: Access {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: accessURL))
            .flatMap { try? AgentJSON.decoder.decode(Access.self, from: $0) } ?? Access()
        cached = loaded
        return loaded
    }

    /// The current credential, or nil when there is none (never enabled, or revoked).
    public var token: String? {
        guard let data = try? Data(contentsOf: tokenURL),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Turns access on at `permission`, creating a credential if there is none.
    @discardableResult
    public func enable(_ permission: AgentPermission) throws -> String {
        let token = try self.token ?? rotateToken()
        var next = access
        next.permission = permission
        try save(next)
        return token
    }

    /// Off, credential destroyed, new generation: a configured agent stops working at once, and a
    /// later enable issues a credential the old configuration does not have.
    public func revoke() throws {
        try save(Access(permission: .off))
        if FileManager.default.fileExists(atPath: tokenURL.path) { try FileManager.default.removeItem(at: tokenURL) }
    }

    /// Changes only the permission; the credential and generation stay, so configured agents keep
    /// working with the new scope.
    public func setPermission(_ permission: AgentPermission) throws {
        var next = access
        next.permission = permission
        try save(next)
    }

    /// A new credential and a new generation, with the permission unchanged: every configured agent
    /// stops working until it is given the new configuration, and access stays on for the ones that
    /// are. What Settings' Rotate does — the fix for a credential that leaked, without the detour
    /// through turning access off and on again.
    ///
    /// Clearing history rotates the same way. Otherwise a disconnected old helper could
    /// authenticate again and replay an old ID into the empty journal under the new generation.
    public func rotateGeneration() throws {
        var next = access
        next.generation = UUID().uuidString.lowercased()
        _ = try rotateToken()
        try save(next)
    }

    private func save(_ access: Access) throws {
        try DurableFile.write(try AgentJSON.prettyEncoder.encode(access), to: accessURL)
        lock.lock()
        cached = access
        lock.unlock()
    }

    @discardableResult
    private func rotateToken() throws -> String {
        // `SystemRandomNumberGenerator` is the kernel's CSPRNG (arc4random) on Darwin.
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let token = "plm_" + Base64URL.encode(Data(bytes))
        try DurableFile.write(Data((token + "\n").utf8), to: tokenURL)
        return token
    }

    /// Re-reads both files; for a hand edit or another process (Settings) having changed them.
    public func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Constant-time comparison: the credential is checked on every connection.
    public static func matches(_ offered: String?, _ expected: String?) -> Bool {
        guard let offered, let expected else { return false }
        let a = Array(offered.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
