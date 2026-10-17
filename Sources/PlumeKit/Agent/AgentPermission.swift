import Foundation

/// How much of the vault the local agent API may touch, for this profile.
///
/// Three steps and no finer, because the person choosing is answering one question — "may my agent
/// change my notes?" — and a matrix of per-tool switches would be a question nobody can answer
/// confidently. Off is the default; nothing listens for writes until somebody turns it on.
public enum AgentPermission: String, Codable, Sendable, CaseIterable {
    case off
    case readOnly = "read_only"
    case readWrite = "read_write"

    public func allows(_ tool: AgentTool) -> Bool {
        switch self {
        case .off: false
        case .readOnly: !tool.writes
        case .readWrite: true
        }
    }
}

/// The tools, by their published names. MCP's `tools/list`, the CLI, the IPC method names and the
/// permission check all key on these strings, so they are frozen once released.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case getWritingContext = "get_writing_context"
    case listNotes = "list_notes"
    case searchNotes = "search_notes"
    case readNote = "read_note"
    case createNote = "create_note"
    case modifyNote = "modify_note"
    case getOperation = "get_operation"

    /// Whether the tool changes a note. `get_operation` reads the journal and is not a write, but it
    /// only has anything to say about writes — so it goes with them, and a read-only connection is
    /// not offered a tool it can never use.
    public var writes: Bool {
        switch self {
        case .createNote, .modifyNote, .getOperation: true
        default: false
        }
    }
}
