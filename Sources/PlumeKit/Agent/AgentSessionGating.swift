import Foundation

/// What the agent API needs from the note session: is a note the one open in the panel, is someone
/// editing it, and the gate an agent write to it must hold.
///
/// "Open" means the session's current note, not "visible": dismissing parks the panel offscreen and
/// the session keeps pointing at the last note, which an agent may still modify. `NoteSession` is
/// the real one (`NoteSession+Agent.swift`); a test may supply another.
@MainActor
public protocol AgentSessionGating: AnyObject {

    /// The note the session holds, or nil for none or a draft. Drafts have no file and no ref.
    var agentCurrentFilename: String? { get }

    /// Whether `filename` is the open note and its buffer differs from what was last saved.
    func agentHasUnsavedChanges(_ filename: String) -> Bool

    /// Ends the "name follows the title" phase for any of these notes, before the API hands out a
    /// ref to one. Settling does not save or rewrite anything; it only stops a later rename from
    /// invalidating the ref.
    func agentSettleNames(_ filenames: Set<String>)

    /// For the open note: claims the session's write gate, or says why not. Nil when `filename` is
    /// not the open note — then there is nothing in the session to coordinate with.
    ///
    /// `panelHasKeyboard` comes from the panel (AppKit); the session cannot see it.
    func agentBeginWrite(_ filename: String, panelHasKeyboard: Bool) -> Result<AgentWriteTicket, AgentFailure>?

    /// The write landed on disk: put it on screen if the buffer is still what it was, and release
    /// the gate. Returns warnings for the result (for instance, the person started typing meanwhile).
    func agentFinishWrite(_ ticket: AgentWriteTicket, savedText: String, savedHash: String) -> [AgentWarning]

    /// The write did not happen. Releases the gate; the buffer and the file are untouched.
    func agentAbortWrite(_ ticket: AgentWriteTicket)
}

/// Proof of holding the open note's write gate, and what the buffer was when it was taken.
public struct AgentWriteTicket: Sendable, Equatable {
    public var filename: String
    public var baselineHash: String?
    public var bufferHash: String

    public init(filename: String, baselineHash: String?, bufferHash: String) {
        self.filename = filename
        self.baselineHash = baselineHash
        self.bufferHash = bufferHash
    }
}
