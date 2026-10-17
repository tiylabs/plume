import Foundation

/// Where one write is in its life.
///
///     accepted → prepared → saved
///                     ↘ rejected
///                     ↘ outcome_unknown
///
/// `saved` is only written once the note is on disk, and only after it is written is success
/// reported. `rejected` promises the note was not changed by this operation — writes are atomic
/// replaces, so a failed one leaves the old bytes. `outcome_unknown` is the honest answer when a
/// crash left evidence that cannot be reconciled: the operation stops and says so rather than guess.
public enum OperationState: String, Codable, Sendable {
    case accepted
    case prepared
    case saved
    case rejected
    case outcomeUnknown = "outcome_unknown"

    public var isTerminal: Bool {
        switch self {
        case .saved, .rejected, .outcomeUnknown: true
        case .accepted, .prepared: false
        }
    }
}

public enum OperationKind: String, Codable, Sendable {
    case create
    case modify
    /// Putting back the text an earlier modify replaced, from Settings. A new operation through the
    /// same write path, not an inversion of the old record.
    case restore
}

/// One write, as the journal keeps it.
///
/// Holds no note text: the before and after snapshots live beside the record in their own files,
/// so the record can be compacted — snapshots dropped, the request ID kept — without rewriting a
/// megabyte to keep a few hundred bytes.
public struct OperationRecord: Codable, Sendable, Equatable {
    public var operationID: String
    public var requestID: String
    /// The authorisation generation the request arrived under. Revoking access starts a new one, so
    /// an old credential's request IDs neither collide with nor reveal the new one's.
    public var generation: String
    public var kind: OperationKind
    public var state: OperationState
    /// Digest of the typed request (target, vault, version, changes or text), so a retry with the
    /// same ID can be told from a different request reusing it.
    public var inputDigest: String
    /// The vault the operation was bound to when first accepted. Fixed for life: a retry after a
    /// vault switch returns the original operation rather than creating in the new vault.
    public var vaultPath: String
    public var vaultID: String
    /// The target file. For a create, the name reserved at `prepared`.
    public var filename: String?
    public var noteRef: String?
    public var title: String?
    /// Raw-byte hash of the target before and after. `before` is nil for a create.
    public var beforeHash: String?
    public var afterHash: String?
    public var changed: Bool?
    public var error: AgentFailure?
    public var warnings: [AgentWarning]
    /// Shown in Settings' recent writes. Supplied by the client; a label, not an identity.
    public var clientLabel: String?
    /// For a restore, the operation whose before-text it put back.
    public var restoreOf: String?
    /// Set when the operation's snapshots have been dropped after the full retention period.
    public var compacted: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        operationID: String = UUID().uuidString.lowercased(),
        requestID: String,
        generation: String,
        kind: OperationKind,
        inputDigest: String,
        vaultPath: String,
        vaultID: String,
        filename: String? = nil,
        clientLabel: String? = nil,
        now: Date = Date()
    ) {
        self.operationID = operationID
        self.requestID = requestID
        self.generation = generation
        self.kind = kind
        self.state = .accepted
        self.inputDigest = inputDigest
        self.vaultPath = vaultPath
        self.vaultID = vaultID
        self.filename = filename
        self.warnings = []
        self.clientLabel = clientLabel
        self.compacted = false
        self.createdAt = now
        self.updatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case requestID = "request_id"
        case generation, kind, state
        case inputDigest = "input_digest"
        case vaultPath = "vault_path"
        case vaultID = "vault_id"
        case filename
        case noteRef = "note_ref"
        case title
        case beforeHash = "before_hash"
        case afterHash = "after_hash"
        case changed, error, warnings
        case clientLabel = "client_label"
        case restoreOf = "restore_of"
        case compacted
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
