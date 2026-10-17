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
/// 1. Here, on the main actor, after the journal has recorded the change: check, and take the same
///    gate a save and a rename take, and — in the same turn — put the replace on the vault queue. A
///    debounced save that fires meanwhile is deferred by the gate, exactly as during a rename, and a
///    note switch's load queues behind the replace, so the deferred save still finds its own note
///    open when it runs.
/// 2. On the vault queue: the strict replace (`VaultIO.agentReplace`).
/// 3. Back here: if the buffer is still what it was at step 1, take the new text as both buffer and
///    baseline and reload the editor *now*, rather than waiting for FSEvents — the event that
///    arrives later then finds disk equal to baseline and does nothing, so there is no second
///    reload. If the person started typing in between, nothing is reloaded; the deferred save then
///    meets a changed disk and goes to a conflict sibling by the existing rule. Their text survives,
///    the agent's change is saved, and the result carries a warning saying so.
///
/// One thing can still replace the buffer while step 2 runs: ⌘N, which empties it at once with no
/// load to queue — and step 2 can last as long as Git sync's merge holds the working tree (up to
/// five seconds). So the save the gate deferred is parked with its own note and baseline before the
/// buffer goes (`parkDeferredSaveIfAgentWriting`), and written when the gate opens.
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

    public func agentWriteRefusal(_ filename: String, panelHasKeyboard: Bool) -> AgentFailure? {
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
        return reason.map {
            AgentFailure(
                .noteBusy,
                "the user is editing this note in Plume; read it again in a moment, ask them to close the panel, or create a new note instead",
                details: ["reason": $0.rawValue]
            )
        }
    }

    public func agentBeginWrite(
        _ filename: String, panelHasKeyboard: Bool
    ) -> Result<AgentWriteTicket, AgentFailure>? {
        guard !isDraft, filename == currentFilename else { return nil }
        if let busy = agentWriteRefusal(filename, panelHasKeyboard: panelHasKeyboard) { return .failure(busy) }

        isWriting = true
        // A note the API is about to change is known to another program by name now.
        unsettledName = nil
        let ticket = AgentWriteTicket(filename: filename, baselineHash: baselineHash, bufferHash: bufferHash)
        agentWriteTicket = ticket
        return .success(ticket)
    }

    public func agentFinishWrite(_ ticket: AgentWriteTicket, savedText: String, savedHash: String) -> [AgentWarning] {
        var warnings: [AgentWarning] = []
        isWriting = false
        agentWriteTicket = nil

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
                warnings.append(Self.userEditedDuringWrite)
            }
        } else if parkedAgentSave?.filename == ticket.filename {
            warnings.append(Self.userEditedDuringWrite)
        }

        releaseDeferredWrite()
        return warnings
    }

    public func agentAbortWrite(_ ticket: AgentWriteTicket) {
        isWriting = false
        agentWriteTicket = nil
        releaseDeferredWrite()
    }

    private static let userEditedDuringWrite = AgentWarning(
        "user_edited_during_write",
        "The user started typing in this note while the change was being saved. Your change is saved; their typing was kept in a separate conflict copy beside the note."
    )

    /// The buffer is about to be replaced — a note switch, ⌘N — while an agent write holds the gate
    /// and the save of the buffer is waiting behind it as a flag. That flag would be read later
    /// against whatever note is open by then, and the text it stood for would be gone. Keeping the
    /// text with the note and baseline it belongs to lets the gate's release write it where it
    /// belongs: in place if the agent's write did not happen, as a conflict sibling if it did.
    ///
    /// Only for an agent's gate. A save's or a rename's gate is held while the vault queue runs
    /// them, and everything that replaces the buffer after a load waits behind them already; a gate
    /// that can also wait out Git's merge is the one ⌘N can overtake.
    func parkDeferredSaveIfAgentWriting() {
        guard agentWriteTicket != nil, writeRequestedWhileWriting, !isDraft,
              let filename = currentFilename, bufferHash != baselineHash
        else { return }
        writeRequestedWhileWriting = false
        parkedAgentSave = ParkedSave(filename: filename, text: bufferText, baselineHash: baselineHash)
    }

    /// A save asked for while the gate was held runs now, as after a rename — a parked one first.
    private func releaseDeferredWrite() {
        if let parked = parkedAgentSave {
            parkedAgentSave = nil
            vault.write(text: parked.text, to: parked.filename, expectedHash: parked.baselineHash) { [weak self] result in
                guard let self else { return }
                switch result {
                case .written:
                    break
                case .conflicted:
                    // As `flush` does for a note the panel has left: no banner over another note,
                    // the sibling simply appears in the list. The agent's result carries the warning.
                    self.output.switcherNeedsRefresh()
                case .failed(let message):
                    self.output.show(.problem(L10n.t("error.saveFailed", ["message": message])))
                }
            }
        }
        if writeRequestedWhileWriting {
            writeRequestedWhileWriting = false
            flush(trigger: .typingStopped)
        }
    }
}

/// A save of a note's typing that outlived the buffer holding it (`parkDeferredSaveIfAgentWriting`).
struct ParkedSave: Equatable {
    var filename: String
    var text: String
    var baselineHash: String?
}
