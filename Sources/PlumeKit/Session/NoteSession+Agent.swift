import Foundation

/// An agent writing to the note this session holds.
///
/// The first version treats the agent as one more outside writer and reuses the reload path that
/// already exists for those — no new editor or bridge code. The one thing it adds is a refusal at
/// the point where that path would otherwise invent a conflict: when the disk changes under a buffer
/// with unsaved typing, `VaultReconciler` writes the buffer to a `-conflict-` sibling and moves the
/// panel there. Nothing is lost, but it would be a conflict the API itself manufactured. So while the
/// panel has the keyboard, or the buffer is ahead of the disk, or a save is in flight, the answer is
/// `NOTE_BUSY` and nothing is touched.
///
/// The order of an allowed write (each step's reason):
///
/// 1. Here, on the main actor: check, and take the same gate a save and a rename take. A debounced
///    save that fires meanwhile is deferred by the gate, exactly as during a rename.
/// 2. On the vault queue: the strict replace (`VaultIO.agentReplace`).
/// 3. Back here: if the buffer is still what it was at step 1, take the new text as both buffer and
///    baseline and reload the editor *now*, rather than waiting for FSEvents — the event that
///    arrives later then finds disk equal to baseline and does nothing, so there is no second
///    reload. If the person started typing in between, nothing is reloaded; the deferred save then
///    meets a changed disk and goes to a conflict sibling by the existing rule. Their text survives,
///    the agent's change is saved, and the result carries a warning saying so.
///
/// Undo: the reload is `loadNote`, which replaces the document and its history. ⌘Z does not undo an
/// agent's change in this version; the operation journal's restore does.
extension NoteSession: AgentSessionGating {

    public var agentCurrentFilename: String? { isDraft ? nil : currentFilename }

    public func agentHasUnsavedChanges(_ filename: String) -> Bool {
        filename == currentFilename && baselineHash != nil && bufferHash != baselineHash
    }

    public func agentSettleNames(_ filenames: Set<String>) {
        if let unsettledName, filenames.contains(unsettledName) { self.unsettledName = nil }
    }

    public func agentBeginWrite(
        _ filename: String, panelHasKeyboard: Bool
    ) -> Result<AgentWriteTicket, AgentFailure>? {
        guard !isDraft, filename == currentFilename else { return nil }

        let reason: AgentBusyReason?
        if panelHasKeyboard {
            reason = .editing
        } else if baselineHash == nil || bufferHash != baselineHash {
            reason = .unsavedChanges
        } else if isWriting || writeTimer != nil || isDownloadingCurrent {
            reason = .saving
        } else {
            reason = nil
        }
        if let reason {
            return .failure(AgentFailure(
                .noteBusy,
                "the user is editing this note in Plume; read it again in a moment, ask them to close the panel, or create a new note instead",
                details: ["reason": reason.rawValue]
            ))
        }

        isWriting = true
        // A note the API is about to change is known to another program by name now.
        unsettledName = nil
        return .success(AgentWriteTicket(filename: filename, baselineHash: baselineHash, bufferHash: bufferHash))
    }

    public func agentFinishWrite(_ ticket: AgentWriteTicket, savedText: String, savedHash: String) -> [AgentWarning] {
        var warnings: [AgentWarning] = []
        isWriting = false

        if ticket.filename == currentFilename {
            if bufferHash == ticket.bufferHash, baselineHash == ticket.baselineHash {
                bufferText = savedText
                baselineHash = savedHash
                let noteState = state.value.note(ticket.filename)
                output.load(LoadedNote(
                    filename: ticket.filename, text: savedText,
                    caret: min(noteState.caretOffset, savedText.utf16.count), pinned: noteState.isPinned
                ))
                let title = MarkdownDocument.title(of: savedText)
                if output.isPanelVisible {
                    output.toast(L10n.t("toast.agentUpdated"))
                } else {
                    output.news(title.isEmpty ? L10n.t("news.agentUpdated") : L10n.t("news.agentUpdatedTitled", ["title": title]))
                }
            } else {
                warnings.append(AgentWarning(
                    "user_edited_during_write",
                    "The user started typing in this note while the change was being saved. Your change is saved; their typing was kept in a separate conflict copy beside the note."
                ))
            }
        }

        releaseDeferredWrite()
        return warnings
    }

    public func agentAbortWrite(_ ticket: AgentWriteTicket) {
        isWriting = false
        releaseDeferredWrite()
    }

    /// A save asked for while the gate was held runs now, as after a rename.
    private func releaseDeferredWrite() {
        if writeRequestedWhileWriting {
            writeRequestedWhileWriting = false
            flush(trigger: .typingStopped)
        }
    }
}
