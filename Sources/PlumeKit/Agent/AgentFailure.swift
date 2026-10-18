import Foundation

/// The machine-stable error codes of the agent API.
///
/// An agent decides what to do next from the code, never from the message — messages are for the
/// person reading the transcript and may change. So the raw values are a published surface: adding
/// one is fine, renaming one breaks every agent prompt and script that branches on it.
public enum AgentErrorCode: String, Codable, Sendable, CaseIterable {
    // Connection and authorisation
    case accessDisabled = "ACCESS_DISABLED"
    case authFailed = "AUTH_FAILED"
    case permissionDenied = "PERMISSION_DENIED"
    // Running and protocol
    case appNotReady = "APP_NOT_READY"
    case appInstanceMismatch = "APP_INSTANCE_MISMATCH"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case requestTimeout = "REQUEST_TIMEOUT"
    case connectionBlocked = "CONNECTION_BLOCKED"
    // Vault and identity
    case vaultUnavailable = "VAULT_UNAVAILABLE"
    case vaultChanged = "VAULT_CHANGED"
    case noteNotFound = "NOTE_NOT_FOUND"
    case invalidNoteRef = "INVALID_NOTE_REF"
    // Content availability
    case noteNotAvailable = "NOTE_NOT_AVAILABLE"
    case downloadTimeout = "DOWNLOAD_TIMEOUT"
    case contentTooLarge = "CONTENT_TOO_LARGE"
    // Versions and matching
    case versionConflict = "VERSION_CONFLICT"
    case versionExpired = "VERSION_EXPIRED"
    case matchNotFound = "MATCH_NOT_FOUND"
    case matchAmbiguous = "MATCH_AMBIGUOUS"
    case changesOverlap = "CHANGES_OVERLAP"
    // Input
    case invalidRequest = "INVALID_REQUEST"
    case emptyContent = "EMPTY_CONTENT"
    case cursorExpired = "CURSOR_EXPIRED"
    // Writing and recovery
    case noteBusy = "NOTE_BUSY"
    case saveFailed = "SAVE_FAILED"
    case outcomeUnknown = "OUTCOME_UNKNOWN"
    // Idempotency
    case requestIDReused = "REQUEST_ID_REUSED"
    case operationExpired = "OPERATION_EXPIRED"
    case operationNotFound = "OPERATION_NOT_FOUND"
    // Rate
    case rateLimited = "RATE_LIMITED"

    /// Whether repeating the same request, unchanged, can succeed later. A version conflict is not
    /// retryable in this sense: the agent has to read again and rethink the change, with a new
    /// request ID. Nor is any write the journal has recorded as rejected, whatever its code — its
    /// request ID now replays that refusal (`NoteAccessHandler.terminal`).
    public var retryable: Bool {
        switch self {
        case .appNotReady, .requestTimeout, .noteBusy, .rateLimited, .downloadTimeout, .saveFailed:
            true
        default:
            false
        }
    }
}

/// A domain failure, as it crosses the IPC boundary and reaches the agent.
///
/// `details` is a flat string map on purpose: it is what an agent may branch on beyond the code
/// (`reason: editing`, `retry_after: 12`), and a flat map is the shape every JSON consumer reads
/// without a schema.
public struct AgentFailure: Error, Codable, Sendable, Equatable {
    public var code: AgentErrorCode
    public var message: String
    public var retryable: Bool
    public var details: [String: String]?
    /// For a write: which request this was, so a timed-out caller knows what to ask `get_operation`.
    public var requestID: String?
    /// For a write: what the journal knows about it.
    public var operationState: OperationState?

    public init(
        _ code: AgentErrorCode,
        _ message: String,
        details: [String: String]? = nil,
        retryable: Bool? = nil,
        requestID: String? = nil,
        operationState: OperationState? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable ?? code.retryable
        self.details = details
        self.requestID = requestID
        self.operationState = operationState
    }

    enum CodingKeys: String, CodingKey {
        case code, message, retryable, details
        case requestID = "request_id"
        case operationState = "operation_state"
    }

    /// The same failure, stamped with the write it belongs to.
    public func forRequest(_ requestID: String?, state: OperationState?) -> AgentFailure {
        var copy = self
        copy.requestID = requestID ?? copy.requestID
        copy.operationState = state ?? copy.operationState
        return copy
    }
}

/// Why a write to the open note was refused (`NOTE_BUSY`'s `reason`).
public enum AgentBusyReason: String, Codable, Sendable {
    /// The panel has the keyboard: someone is, or is about to be, typing in this note.
    case editing
    /// The buffer holds text that has not reached the disk yet.
    case unsavedChanges = "unsaved_changes"
    /// A save, rename or download of this note is in flight.
    case saving
    /// A Git sync cycle is merging into the working tree.
    case syncing
}
