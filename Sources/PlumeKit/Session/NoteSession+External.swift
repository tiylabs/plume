import Foundation

/// What the session does when something other than the panel touches the open note: the file
/// changed, was evicted by iCloud, was renamed in the Finder, or was deleted on another machine.
extension NoteSession {

    /// Reacts to the vault changing underneath us. Called on the main thread by the watcher.
    public func vaultChanged(filenames: [String]) {
        output.switcherNeedsRefresh()

        guard let current = currentFilename else { return }
        guard filenames.contains(current) else {
            // The burst does not name the open note, so nothing here is about it — unless the note
            // is gone from the vault entirely, which is what a rename in Finder looks like from
            // here. Decision 103's external-rename half.
            followExternalRename(of: current, within: filenames) {}
            return
        }

        vault.diskState(current) { [weak self] disk in
            guard let self, current == self.currentFilename else { return }

            let diskHash: String
            switch disk {
            case .unreadable:
                return

            case .missing:
                // A rename usually names *both* paths in one burst, so this is where following one
                // most often starts — the old name is in `filenames` and gone from disk.
                self.followExternalRename(of: current, within: filenames) { [weak self] in
                    guard let self else { return }
                    // Genuinely gone, and not a rename. Either the whole vault went — which is
                    // decision 13's "choose vault", not this — or another machine deleted the note
                    // this panel has open.
                    if self.vaultIsMissing() {
                        self.output.vaultIsGone()
                        return
                    }
                    self.noteDeletedElsewhere(current)
                }
                return

            case .evicted:
                // Decision 105a. The open note has been dataless-ed under us — "Optimize Mac Storage"
                // reclaiming it, or a remote update arriving as a placeholder. Before this the panel
                // showed stale text with no banner: "downloading…" only ever fired on `open`.
                self.reloadEvictedNote(current)
                return

            case .available(let hash):
                diskHash = hash
            }

            // Decision 105b. iCloud files a losing version rather than telling anyone, and it can
            // arrive long after the edit that caused it — which is why this is here as well as on
            // load, and why Plume's own hash conflict does not cover it.
            self.harvestConflicts(of: current)

            switch VaultReconciler.react(
                diskHash: diskHash,
                baselineHash: self.baselineHash,
                bufferHash: self.bufferHash
            ) {
            case .ignoreEcho, .noChange:
                break

            case .adoptBaseline:
                self.baselineHash = diskHash
                // Somebody else's write, byte-identical to our buffer but not to our baseline. It is
                // still somebody else: decision 103 freezes the name (another tool knows this file
                // by path now, and renaming under it is decision 74's trap one process further out).
                self.freezeNameOnExternalWrite(current)

            case .reload:
                self.freezeNameOnExternalWrite(current)
                self.vault.load(current) { [weak self] result in
                    guard let self, case .loaded(let text, let hash) = result else { return }
                    guard current == self.currentFilename else { return }
                    self.bufferText = text
                    self.baselineHash = hash
                    let noteState = self.state.value.note(current)
                    self.output.load(LoadedNote(
                        filename: current, text: text,
                        caret: min(noteState.caretOffset, text.utf16.count), pinned: noteState.isPinned
                    ))
                }

            case .writeConflictSibling:
                self.freezeNameOnExternalWrite(current)
                // Push our version out now; `VaultIO.write` sees the mismatch and makes the sibling.
                self.flush(trigger: .reloadPending)
            }
        }
    }

    /// Decision 103's freeze list: an external write ends the name's freedom to move.
    private func freezeNameOnExternalWrite(_ filename: String) {
        guard unsettledName == filename else { return }
        unsettledName = nil
    }

    /// Decision 105a: the open note was evicted, so fetch it back and adopt it.
    ///
    /// Routed into the paths `open()` already has rather than new ones — the same
    /// `.downloading` banner, the same `vault.download`, the same `adopt`.
    private func reloadEvictedNote(_ filename: String) {
        // Unsaved edits over bytes we have never seen is decision 8's case exactly, and the answer is
        // already written: flush, and `VaultIO.write` sees `.evicted` and makes the conflict sibling
        // rather than destroying content that only exists on another machine. Downloading here would
        // replace the buffer with the remote text and take the unsaved edits with it.
        guard bufferHash == baselineHash else {
            flush(trigger: .reloadPending)
            return
        }

        // FSEvents bursts arrive in twos and threes; without this the panel starts a second download
        // on top of the first and the banner flickers between them.
        guard !isDownloadingCurrent else { return }
        isDownloadingCurrent = true

        freezeNameOnExternalWrite(filename)
        output.show(.downloading)
        vault.download(filename) { [weak self] result in
            guard let self else { return }
            self.isDownloadingCurrent = false
            guard filename == self.currentFilename else { return }
            if case .loaded(let text, let hash) = result {
                self.adopt(filename: filename, text: text, hash: hash, recordingHistory: false)
            } else {
                self.output.show(.problem(L10n.t("error.downloadFailed", ["filename": filename])))
            }
        }
    }

    /// Decision 105b: writes out iCloud's own losing versions as ordinary siblings.
    ///
    /// The banner is the one decision 8 already ships, and the loser is a normal note in a flat
    /// vault — so this adds no UI at all. Silent when there is nothing, which is nearly always.
    func harvestConflicts(of filename: String) {
        vault.harvestConflicts(filename) { [weak self] written in
            guard let self, !written.isEmpty else { return }
            self.output.show(.conflict)
            self.output.switcherNeedsRefresh()
        }
    }

    /// Follows the open note when something outside Plume renamed its file.
    ///
    /// Today this **silently duplicates the note**: `vaultChanged` only reacts when the burst names
    /// the current filename, so a rename was ignored; the panel went on pointing at the dead name;
    /// and `VaultIO.write` takes `case .missing: break` — "recreating a note deleted elsewhere is
    /// fine" — and writes the old name back. You end up with both files, and `state.json` keeps the
    /// caret and the pin on the dead one.
    ///
    /// The fix is the move decision 25 already makes for a conflict sibling: the buffer follows its
    /// text. And then the name freezes, because the user has chosen one.
    private func followExternalRename(
        of filename: String,
        within burst: [String],
        otherwise: @escaping @MainActor () -> Void
    ) {
        guard let hash = baselineHash else {
            otherwise()
            return
        }

        vault.findRenamed(of: filename, among: burst, matching: hash) { [weak self] moved in
            guard let self, self.currentFilename == filename else { return }
            guard let moved else {
                otherwise()
                return
            }
            self.repoint(from: filename, to: moved)
            // The user has chosen a name (decision 103's freeze list).
            self.unsettledName = nil
        }
    }

    /// Decision 13: a vault that is simply gone must never be silently recreated.
    /// The three call sites that only want the side effect: a failed read or write is often the
    /// vault having moved, and decision 13 says ask rather than recreate.
    func checkVaultStillThere() {
        if vaultIsMissing() { output.vaultIsGone() }
    }

    private func vaultIsMissing() -> Bool {
        var isDirectory: ObjCBool = false
        let vaultURL = settings.value.vaultURL
        let exists = FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory)
        return !exists || !isDirectory.boolValue
    }

    /// Decision 117: another machine deleted the note this panel has open.
    ///
    /// **The delete sticks.** Before this the note simply came back: the state entry stayed, nothing
    /// cancelled the pending write, and `VaultIO.write` recreated the file on the next keystroke
    /// with everything typed since. No text was lost, which is why it survived so long — but a
    /// delete made on one machine did not hold on the other, and neither person was told. Plume has
    /// no save button (decision 10 writes on a 500 ms debounce), so that recreation was never a
    /// decision anybody made; it was the app overruling a delete automatically and in silence.
    ///
    /// **Nothing is lost either.** If the buffer differs from what the vault last held, those edits
    /// exist nowhere else — the machine that deleted the note never saw them — so they go into
    /// Recently Deleted, which is the surface that already means "gone, and recoverable for 30 days"
    /// (decisions 20 and 35). If the buffer matches disk there is nothing only this machine has, and
    /// nothing is written: the note is already in *that* machine's Recently Deleted, and a second
    /// copy here would be one the reader never made.
    ///
    /// Then a toast names what happened and the panel moves on, exactly as it does after ⌃X.
    private func noteDeletedElsewhere(_ filename: String) {
        // First, and before anything can schedule another one: stop the write that would put the
        // file back. Same ordering argument as `delete` — all vault I/O is one serial queue, and a
        // write landing after this would recreate the note, which is the bug this method exists to
        // fix wearing its original face.
        writeTimer?.cancel()
        writeTimer = nil
        writeRequestedWhileWriting = false

        let unsavedEdits = baselineHash != nil && bufferHash != baselineHash
        let text = bufferText
        let title = MarkdownDocument.title(of: text)

        // The buffer is no longer bound to a file, so nothing downstream can flush it back.
        currentFilename = nil
        baselineHash = nil
        bufferText = ""
        unsettledName = nil
        state.update { $0.notes.removeValue(forKey: filename) }
        output.pinsChanged()

        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // A toast that names the note, not a banner (decision 176): the banner is the row about
            // the note under it, and this one would sit over the next note saying it was deleted.
            // The event first, so a long title is what the ellipsis takes.
            self.output.news(title.isEmpty ? L10n.t("news.deletedElsewhere") : L10n.t("news.deletedElsewhereTitled", ["title": title]))
            self.openLastUsed()
            self.output.switcherNeedsRefresh()
        }

        if unsavedEdits {
            vault.keepDeleted(filename, text: text) { _ in finish() }
        } else {
            vault.forgetIndexed(filename) { finish() }
        }
    }
}
