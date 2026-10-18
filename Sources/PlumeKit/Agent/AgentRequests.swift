import Foundation

// The typed inputs of the seven tools. Field names are the published snake_case names, written out
// in `CodingKeys` rather than produced by a key strategy: `convertFromSnakeCase` turns `request_id`
// into `requestId`, which does not match a Swift property called `requestID`, and a strategy that
// is right for some keys and silently wrong for others is worse than spelling them out.

public struct WritingContextRequest: Codable, Sendable, Equatable {
    public var target: String?
    public var templateID: String?
    public var exampleRefs: [String]?

    public init(target: String? = nil, templateID: String? = nil, exampleRefs: [String]? = nil) {
        self.target = target
        self.templateID = templateID
        self.exampleRefs = exampleRefs
    }

    enum CodingKeys: String, CodingKey {
        case target
        case templateID = "template_id"
        case exampleRefs = "example_refs"
    }
}

public struct ListNotesRequest: Codable, Sendable, Equatable {
    public var cursor: String?
    public var limit: Int?

    public init(cursor: String? = nil, limit: Int? = nil) {
        self.cursor = cursor
        self.limit = limit
    }
}

public struct SearchNotesRequest: Codable, Sendable, Equatable {
    public var query: String
    public var cursor: String?
    public var limit: Int?

    public init(query: String, cursor: String? = nil, limit: Int? = nil) {
        self.query = query
        self.cursor = cursor
        self.limit = limit
    }
}

public struct ReadNoteRequest: Codable, Sendable, Equatable {
    public var noteRef: String
    /// The caller allows an iCloud download of this one note. Off by default: a read that blocks
    /// for twenty seconds is a decision the agent should make knowingly.
    public var download: Bool?

    public init(noteRef: String, download: Bool? = nil) {
        self.noteRef = noteRef
        self.download = download
    }

    enum CodingKeys: String, CodingKey {
        case noteRef = "note_ref"
        case download
    }
}

public struct CreateNoteRequest: Codable, Sendable, Equatable {
    public var markdown: String
    public var requestID: String

    public init(markdown: String, requestID: String) {
        self.markdown = markdown
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case markdown
        case requestID = "request_id"
    }
}

/// One change of a `modify_note`. Two kinds only in this version: replace a unique passage, or
/// append to the end. Offsets are deliberately not offered — a model counting characters gets
/// UTF-16 against grapheme counts wrong, and a wrong offset edits the wrong place silently.
public struct NoteChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case replace
        case append
    }

    public var kind: Kind
    public var oldText: String?
    public var newText: String?
    public var text: String?

    public init(kind: Kind, oldText: String? = nil, newText: String? = nil, text: String? = nil) {
        self.kind = kind
        self.oldText = oldText
        self.newText = newText
        self.text = text
    }

    public static func replace(_ old: String, with new: String) -> NoteChange {
        NoteChange(kind: .replace, oldText: old, newText: new)
    }

    public static func append(_ text: String) -> NoteChange {
        NoteChange(kind: .append, text: text)
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case oldText = "old_text"
        case newText = "new_text"
        case text
    }
}

public struct ModifyNoteRequest: Codable, Sendable, Equatable {
    public var noteRef: String
    public var expectedVersion: String
    public var changes: [NoteChange]
    public var requestID: String

    public init(noteRef: String, expectedVersion: String, changes: [NoteChange], requestID: String) {
        self.noteRef = noteRef
        self.expectedVersion = expectedVersion
        self.changes = changes
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case noteRef = "note_ref"
        case expectedVersion = "expected_version"
        case changes
        case requestID = "request_id"
    }
}

public struct GetOperationRequest: Codable, Sendable, Equatable {
    public var requestID: String

    public init(requestID: String) {
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
    }
}

/// A request ID must be a UUID. Free-form IDs invite `"1"`, `"2"`, … from a model, which collide
/// across conversations and turn idempotency into "your new note was silently not created".
public enum AgentRequestID {
    public static func validate(_ raw: String) throws -> String {
        guard let uuid = UUID(uuidString: raw) else {
            throw AgentFailure(.invalidRequest, "request_id must be a UUID, such as one from uuidgen")
        }
        return uuid.uuidString.lowercased()
    }
}
