import Foundation

// The typed outputs of the seven tools. Every result carries `api_version`; times are ISO 8601, never
// the switcher's localised "just now" — an agent compares and sorts these, it does not read them.

/// Something worth telling the agent that is not a failure: a note with Git conflict markers, a
/// truncated example, a write that landed while the person was starting to type.
public struct AgentWarning: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let conflictMarkers = AgentWarning(
        "git_conflict_markers",
        "This note contains unresolved Git conflict markers. Do not resolve them unless the user asked you to."
    )
}

/// One note, without its body.
public struct NoteSummary: Codable, Sendable, Equatable {
    public var noteRef: String
    public var filename: String
    public var title: String
    public var modified: Date
    /// `available`, or `evicted` for an iCloud placeholder whose body is not on this Mac.
    public var availability: String

    public init(noteRef: String, filename: String, title: String, modified: Date, availability: String) {
        self.noteRef = noteRef
        self.filename = filename
        self.title = title
        self.modified = modified
        self.availability = availability
    }

    enum CodingKeys: String, CodingKey {
        case noteRef = "note_ref"
        case filename, title, modified, availability
    }
}

public struct ListNotesResult: Codable, Sendable, Equatable {
    public var apiVersion = AgentAPI.apiVersion
    public var notes: [NoteSummary]
    public var total: Int
    public var nextCursor: String?

    public init(notes: [NoteSummary], total: Int, nextCursor: String?) {
        self.notes = notes
        self.total = total
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case notes, total
        case nextCursor = "next_cursor"
    }
}

public struct SearchHit: Codable, Sendable, Equatable {
    public struct Snippet: Codable, Sendable, Equatable {
        public var before: String
        public var match: String
        public var after: String

        public init(before: String, match: String, after: String) {
            self.before = before
            self.match = match
            self.after = after
        }
    }

    public var note: NoteSummary
    /// `title`, `filename` or `body` — which part matched.
    public var matchedIn: String
    public var snippet: Snippet?
    public var hasConflictMarkers: Bool

    public init(note: NoteSummary, matchedIn: String, snippet: Snippet?, hasConflictMarkers: Bool) {
        self.note = note
        self.matchedIn = matchedIn
        self.snippet = snippet
        self.hasConflictMarkers = hasConflictMarkers
    }

    enum CodingKeys: String, CodingKey {
        case note
        case matchedIn = "matched_in"
        case snippet
        case hasConflictMarkers = "has_conflict_markers"
    }
}

/// What a search could and could not look at. iCloud-evicted notes are searched by title and
/// filename only — reading their bodies would download them — so the caller is told how many.
public struct SearchCoverage: Codable, Sendable, Equatable {
    public var notesTotal: Int
    public var bodiesSearched: Int
    public var bodiesNotSearched: Int

    public init(notesTotal: Int, bodiesSearched: Int, bodiesNotSearched: Int) {
        self.notesTotal = notesTotal
        self.bodiesSearched = bodiesSearched
        self.bodiesNotSearched = bodiesNotSearched
    }

    enum CodingKeys: String, CodingKey {
        case notesTotal = "notes_total"
        case bodiesSearched = "bodies_searched"
        case bodiesNotSearched = "bodies_not_searched"
    }
}

public struct SearchNotesResult: Codable, Sendable, Equatable {
    public var apiVersion = AgentAPI.apiVersion
    public var query: String
    public var results: [SearchHit]
    public var total: Int
    public var nextCursor: String?
    public var coverage: SearchCoverage

    public init(query: String, results: [SearchHit], total: Int, nextCursor: String?, coverage: SearchCoverage) {
        self.query = query
        self.results = results
        self.total = total
        self.nextCursor = nextCursor
        self.coverage = coverage
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case query, results, total
        case nextCursor = "next_cursor"
        case coverage
    }
}

public struct ReadNoteResult: Codable, Sendable, Equatable {
    public var apiVersion = AgentAPI.apiVersion
    public var noteRef: String
    public var filename: String
    public var title: String
    /// Always LF line endings, whatever the file uses.
    public var markdown: String
    public var version: String
    public var versionExpiresAt: Date
    /// `disk` in this version: what has been saved, never the unsaved buffer.
    public var source: String
    public var hasUnsavedChanges: Bool
    public var availability: String
    public var warnings: [AgentWarning]

    public init(
        noteRef: String, filename: String, title: String, markdown: String, version: String,
        versionExpiresAt: Date, hasUnsavedChanges: Bool, warnings: [AgentWarning]
    ) {
        self.noteRef = noteRef
        self.filename = filename
        self.title = title
        self.markdown = markdown
        self.version = version
        self.versionExpiresAt = versionExpiresAt
        self.source = "disk"
        self.hasUnsavedChanges = hasUnsavedChanges
        self.availability = "available"
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case noteRef = "note_ref"
        case filename, title, markdown, version
        case versionExpiresAt = "version_expires_at"
        case source
        case hasUnsavedChanges = "has_unsaved_changes"
        case availability, warnings
    }
}

/// The answer to `create_note` and `modify_note`, and what `get_operation` returns for a write
/// that finished. `saved_locally` is the whole promise: the file is on this Mac's disk. Whether
/// iCloud or a Git remote has it yet is a different question this API does not answer.
public struct WriteResult: Codable, Sendable, Equatable {
    public var apiVersion = AgentAPI.apiVersion
    public var operationID: String
    public var requestID: String
    public var state: OperationState
    public var noteRef: String
    public var filename: String
    public var title: String
    public var version: String?
    public var versionExpiresAt: Date?
    public var savedLocally: Bool
    public var changed: Bool
    public var warnings: [AgentWarning]

    public init(
        operationID: String, requestID: String, state: OperationState, noteRef: String,
        filename: String, title: String, version: String?, versionExpiresAt: Date?,
        changed: Bool, warnings: [AgentWarning]
    ) {
        self.operationID = operationID
        self.requestID = requestID
        self.state = state
        self.noteRef = noteRef
        self.filename = filename
        self.title = title
        self.version = version
        self.versionExpiresAt = versionExpiresAt
        self.savedLocally = state == .saved
        self.changed = changed
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case operationID = "operation_id"
        case requestID = "request_id"
        case state
        case noteRef = "note_ref"
        case filename, title, version
        case versionExpiresAt = "version_expires_at"
        case savedLocally = "saved_locally"
        case changed, warnings
    }
}

/// `get_operation`: what the journal knows about one write. No note text, ever — a caller with the
/// request ID is not thereby entitled to the content.
public struct OperationStatusResult: Codable, Sendable, Equatable {
    public var apiVersion = AgentAPI.apiVersion
    public var operationID: String
    public var requestID: String
    public var kind: OperationKind
    public var state: OperationState
    public var noteRef: String?
    public var filename: String?
    public var changed: Bool?
    public var savedLocally: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var error: AgentFailure?
    public var warnings: [AgentWarning]

    public init(record: OperationRecord) {
        operationID = record.operationID
        requestID = record.requestID
        kind = record.kind
        state = record.state
        noteRef = record.noteRef
        filename = record.filename
        changed = record.changed
        savedLocally = record.state == .saved
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        error = record.error
        warnings = record.warnings
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case operationID = "operation_id"
        case requestID = "request_id"
        case kind, state
        case noteRef = "note_ref"
        case filename, changed
        case savedLocally = "saved_locally"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case error, warnings
    }
}
