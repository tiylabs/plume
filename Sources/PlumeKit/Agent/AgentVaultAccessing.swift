import Foundation

/// One note in a listing, as the agent API needs it.
public struct AgentNoteEntry: Sendable, Equatable {
    public var filename: String
    public var title: String
    public var modified: Date
    public var evicted: Bool
    public var hasConflictMarkers: Bool

    public init(filename: String, title: String, modified: Date, evicted: Bool, hasConflictMarkers: Bool) {
        self.filename = filename
        self.title = title
        self.modified = modified
        self.evicted = evicted
        self.hasConflictMarkers = hasConflictMarkers
    }
}

public struct AgentSearchMatch: Sendable, Equatable {
    public var entry: AgentNoteEntry
    public var matchedIn: String
    public var snippet: SearchHit.Snippet?
    public var score: Int
}

public struct AgentSearchOutcome: Sendable, Equatable {
    public var matches: [AgentSearchMatch]
    public var notesTotal: Int
    public var bodiesNotSearched: Int
}

/// A note as read from disk for the API: the normalised text, and the hash of the raw bytes.
public struct AgentDiskNote: Sendable, Equatable {
    public var filename: String
    public var rawHash: String
    public var text: String

    public init(filename: String, rawHash: String, text: String) {
        self.filename = filename
        self.rawHash = rawHash
        self.text = text
    }
}

/// What the agent API needs from the vault. `VaultService` is the real one, running every call on
/// the same serial queue the panel's own reads and writes use — which is what orders an API write
/// against a save, a rename, and the FSEvents reaction to either.
///
/// Every call names the vault it expects. The queue compares it with the vault it is actually
/// pointed at *when the work runs*, not when it was asked for, so a request that was queued before
/// a vault switch fails with `VAULT_CHANGED` instead of landing in the new folder.
public protocol AgentVaultAccessing: AnyObject, Sendable {
    func agentList(vault: URL) async throws -> [AgentNoteEntry]
    /// `diskOnly` names notes whose index entry may hold the unsaved buffer; they are searched as
    /// saved on disk, because the API never exposes unsaved text.
    func agentSearch(query: String, vault: URL, diskOnly: Set<String>) async throws -> AgentSearchOutcome
    func agentRead(filename: String, vault: URL, download: Bool) async throws -> AgentDiskNote
    /// Enqueued before it returns, and `completion` runs on the vault queue — not `async`, because
    /// the open note's write gate needs both: see `NoteAccessHandler.replaceOnVaultQueue`.
    func agentReplace(
        filename: String, vault: URL, expectedHash: String, text: String,
        completion: @escaping @Sendable (Result<String, any Error>) -> Void
    )
    /// A unique name for a new note with this text, not colliding with `excluding` either.
    func agentReserveName(text: String, vault: URL, excluding: Set<String>) async throws -> String
    func agentCreate(filename: String, vault: URL, text: String) async throws -> String
    /// The raw hash of a note, nil if missing. For crash recovery.
    func agentHash(filename: String, vault: URL) async throws -> String?
}
