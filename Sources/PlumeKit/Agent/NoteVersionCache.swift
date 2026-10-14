import Foundation

/// What a `read_note` saw, kept so a later `modify_note` can be checked and applied against it.
///
/// Two hashes, because loading normalises the trailing newline: `rawHash` is of the bytes on disk
/// and is what the strict write compares; `text` is the normalised text the changes are matched
/// against (and, converted to LF, what the agent was shown).
public struct NoteVersionSnapshot: Sendable, Equatable {
    public var epoch: Int
    public var vaultID: String
    public var filename: String
    public var rawHash: String
    /// The note as loaded: trailing newline normalised, interior line endings untouched.
    public var text: String
    public var expiresAt: Date

    public init(epoch: Int, vaultID: String, filename: String, rawHash: String, text: String, expiresAt: Date) {
        self.epoch = epoch
        self.vaultID = vaultID
        self.filename = filename
        self.rawHash = rawHash
        self.text = text
        self.expiresAt = expiresAt
    }
}

/// A bounded, expiring map from an opaque token to a value — versions and cursors.
///
/// Tokens are random, never derived from content: a version is an equality token for the caller,
/// and one it could compute from a hash would invite it to skip the read. Expiry and capacity are
/// the constants in `AgentLimits`, one place; past either, the caller reads again.
public final class ExpiringTokenCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (value: Value, expires: Date, order: Int)] = [:]
    private var counter = 0
    private let prefix: String
    private let lifetime: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(prefix: String, lifetime: TimeInterval, capacity: Int, now: @escaping @Sendable () -> Date = { Date() }) {
        self.prefix = prefix
        self.lifetime = lifetime
        self.capacity = capacity
        self.now = now
    }

    /// Stores `value` and returns its new token and expiry.
    public func insert(_ value: Value) -> (token: String, expiresAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        entries = entries.filter { $0.value.expires > current }
        while entries.count >= capacity, let oldest = entries.min(by: { $0.value.order < $1.value.order }) {
            entries.removeValue(forKey: oldest.key)
        }
        counter += 1
        let token = prefix + Base64URL.randomToken()
        let expires = current.addingTimeInterval(lifetime)
        entries[token] = (value, expires, counter)
        return (token, expires)
    }

    public enum Lookup {
        case found(Value)
        case expired
        case unknown
    }

    public func lookup(_ token: String) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token] else {
            // A well-formed token we no longer hold is one that expired, was evicted, or came from
            // before a restart — all "read again", which is what `expired` tells the caller.
            return token.hasPrefix(prefix) ? .expired : .unknown
        }
        guard entry.expires > now() else {
            entries.removeValue(forKey: token)
            return .expired
        }
        return .found(entry.value)
    }

    /// Forgets everything — the vault changed, so no token issued for the old one may be honoured.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    public func expiry(after date: Date) -> Date { date.addingTimeInterval(lifetime) }
}

/// One page-able result list, frozen at the moment it was first asked for.
///
/// The cursor binds the query and the result snapshot, so paging does not reshuffle when a note is
/// saved between pages. It does not freeze the vault: a note deleted since still appears, and reading
/// it answers `NOTE_NOT_FOUND`.
public struct NoteCursorState: Sendable {
    public enum Items: Sendable {
        case notes([NoteSummary])
        case hits([SearchHit], SearchCoverage)
    }

    /// nil for `list_notes`.
    public var query: String?
    public var vaultID: String
    public var offset: Int
    public var limit: Int
    public var items: Items

    public init(query: String?, vaultID: String, offset: Int, limit: Int, items: Items) {
        self.query = query
        self.vaultID = vaultID
        self.offset = offset
        self.limit = limit
        self.items = items
    }
}
