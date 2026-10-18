import Foundation
import PlumeKit

/// The tools as MCP clients see them: name, description and JSON Schema for the arguments.
///
/// Descriptions are written for a model deciding what to call. They state the workflow (context →
/// search → read → create or modify), the rules a model gets wrong without being told (short search
/// terms, a fresh UUID per write, re-read after a conflict), and nothing about how Plume is built.
public enum MCPToolCatalog {

    /// Sent in `initialize` and shown by a client's `describe`. The Chinese phrases map each step to
    /// the words a Chinese-speaking user says (搜索笔记 = search notes), so the agent can pick the
    /// right tool for a Chinese request. Tool search does not read this text; see `AgentSearchMetadata`.
    public static let serverInstructions = """
    Plume is the user's local Markdown notes app (笔记 / notes). Typical flow: call get_writing_context to learn how \
    Plume renders Markdown and how the user likes notes written; search_notes with short keywords to \
    find a related note (搜索笔记); read_note to get its text and version (读取笔记); then modify_note (exact, unique \
    replacements against that version, 修改笔记) or create_note (新建笔记). Every write needs a new UUID request_id; if a \
    write times out, call get_operation with the same request_id before retrying. Never resolve Git \
    conflict markers unless the user asked. A success means saved on this Mac, not synced.
    """

    public static func tools(for permission: AgentPermission?) -> [JSONValue] {
        AgentTool.allCases
            .filter { permission?.allows($0) ?? true }
            .map(definition)
    }

    static func definition(_ tool: AgentTool) -> JSONValue {
        .object([
            "name": .string(tool.rawValue),
            "description": .string(description(tool)),
            "inputSchema": schema(tool),
        ])
    }

    static func description(_ tool: AgentTool) -> String {
        switch tool {
        case .getWritingContext:
            "How to write a note the way this user and Plume expect: Plume's Markdown format guide (what actually renders), the user's saved writing preferences, their templates, and optionally the shape of a target note and up to 3 example notes. Call before creating or substantially rewriting a note. Priority when they disagree: the user's explicit request, then preferences and template, then the target's existing structure, then Plume's defaults."
        case .listNotes:
            "List notes, newest first, without their text. Pages of up to 100; pass next_cursor to continue. Prefer search_notes when looking for something specific."
        case .searchNotes:
            "Search notes. Titles and filenames match fuzzily; note bodies match the whole query literally (case-insensitive), so use one or two short keywords and search several times rather than one long sentence. Returns note_refs and snippets, not full text. Notes stored only in iCloud are matched by title only; coverage says how many."
        case .readNote:
            "Read one note's full Markdown (always LF line endings) and its version. The version is required by modify_note and expires after 10 minutes. Returns the last saved text: if has_unsaved_changes is true the user is typing in it right now. Set download: true only if the user agreed to fetch a note stored in iCloud."
        case .createNote:
            "Create a new note. The title is the first non-blank line, so start with '# Title'; the filename is derived from it. Pass a new UUID as request_id; retrying with the same request_id never creates a second note. Does not open the note in front of the user."
        case .modifyNote:
            "Change part of an existing note, keeping everything else exactly as it is. Needs note_ref and the version from read_note. Each 'replace' change swaps old_text — copied exactly from read_note's markdown and appearing exactly once — for new_text (empty new_text deletes it); one 'append' change adds text at the end (include the blank lines you want). All changes match the same original text and apply together or not at all. On VERSION_CONFLICT or VERSION_EXPIRED, read again and rebuild the change with a new request_id. On NOTE_BUSY the user is editing this note: try later, ask them to close the Plume panel, or create a new note."
        case .getOperation:
            "Look up a create_note or modify_note by its request_id: whether it was saved, rejected, or is unknown. Use after a timeout or lost connection, before retrying. Returns no note text."
        }
    }

    static func schema(_ tool: AgentTool) -> JSONValue {
        let noteRef: JSONValue = .object(["type": .string("string"), "description": .string("A note_ref returned by list_notes, search_notes, read_note or create_note.")])
        let requestID: JSONValue = .object([
            "type": .string("string"), "format": .string("uuid"),
            "description": .string("A new UUID for this write. Reuse it only to retry the very same request."),
        ])
        let cursor: JSONValue = .object(["type": .string("string"), "description": .string("next_cursor from the previous page.")])
        let limit: JSONValue = .object([
            "type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(AgentLimits.listMaxPage)),
            "default": .number(Double(AgentLimits.listDefaultPage)),
        ])

        func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ])
        }

        switch tool {
        case .getWritingContext:
            return object([
                "target": .object(["type": .string("string"), "description": .string("note_ref of the note about to be modified, to return its headings and an excerpt.")]),
                "template_id": .object(["type": .string("string"), "description": .string("One of the ids in templates, to include that template's text.")]),
                "example_refs": .object([
                    "type": .string("array"), "items": .object(["type": .string("string")]),
                    "maxItems": .number(Double(AgentLimits.maxExamples)),
                    "description": .string("note_refs of notes the user pointed to as examples of their style."),
                ]),
            ])
        case .listNotes:
            return object(["cursor": cursor, "limit": limit])
        case .searchNotes:
            return object([
                "query": .object(["type": .string("string"), "description": .string("One or two short keywords.")]),
                "cursor": cursor, "limit": limit,
            ], required: ["query"])
        case .readNote:
            return object([
                "note_ref": noteRef,
                "download": .object(["type": .string("boolean"), "description": .string("Allow fetching this one note from iCloud. Can take tens of seconds.")]),
            ], required: ["note_ref"])
        case .createNote:
            return object([
                "markdown": .object(["type": .string("string"), "description": .string("The whole note, starting with '# Title'.")]),
                "request_id": requestID,
            ], required: ["markdown", "request_id"])
        case .modifyNote:
            let change: JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object(["type": .string("string"), "enum": .array([.string("replace"), .string("append")])]),
                    "old_text": .object(["type": .string("string"), "description": .string("replace: exact passage from read_note, unique in the note.")]),
                    "new_text": .object(["type": .string("string"), "description": .string("replace: what it becomes; empty to delete.")]),
                    "text": .object(["type": .string("string"), "description": .string("append: text added at the very end.")]),
                ]),
                "required": .array([.string("kind")]),
                "additionalProperties": .bool(false),
            ])
            return object([
                "note_ref": noteRef,
                "expected_version": .object(["type": .string("string"), "description": .string("The version from read_note.")]),
                "changes": .object([
                    "type": .string("array"), "items": change, "minItems": .number(1),
                    "maxItems": .number(Double(AgentLimits.maxChangesPerRequest)),
                ]),
                "request_id": requestID,
            ], required: ["note_ref", "expected_version", "changes", "request_id"])
        case .getOperation:
            return object(["request_id": requestID], required: ["request_id"])
        }
    }
}
