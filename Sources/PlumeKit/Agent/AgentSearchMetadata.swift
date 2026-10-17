import Foundation

/// The server fields a client configuration carries so that its tool search can find Plume.
///
/// Why this exists: an MCP client (for example pi-mcp-adapter) ranks a server's tools by the tool
/// name and description, and by the server's configured `description`. The configuration Plume hands
/// out with "copy" used to carry neither, and the tool descriptions are English. So a user who asked
/// their agent for "笔记" (note) or "打开笔记" (open a note) got "No tools matching".
///
/// The copied configuration carries only `description`. A `searchKeywords` table was tried and dropped:
/// it made the pasted JSON much longer, and the words it held reached the client's search only through
/// that same field. The MCP `instructions` are not read by the search at all; a client shows them only
/// from `describe`.
public enum AgentSearchMetadata {

    /// The server's own description. Clients show it in their server listing and rank the server by it.
    /// It names the product in Chinese, so a Chinese query such as "笔记" matches it.
    public static let serverDescription = "Plume 本地 Markdown 笔记应用（Plume local Markdown notes）：搜索、读取、创建和修改用户的笔记。Search, read, create and modify the user's notes."

    /// The server entry fields a copied configuration carries, minus the per-install fields the app
    /// supplies (the helper path and the token). The app merges these into its entry, so the copy and
    /// the tests read one definition.
    public static func serverEntryFields() -> [String: JSONValue] {
        ["description": .string(serverDescription)]
    }
}
