import Foundation

/// The note a panel is showing, and everything that has to stay true about it: what is on disk, what
/// is in the buffer, when to write, when to rename, and what to do when something else touches the
/// file.
///
/// It owns no window and no web view. What it needs from outside comes in through `vault`, `state`,
/// `settings` and `scheduler`; what it does to the outside goes out through `output`. That is what
/// makes it testable, and it matters because this is where the write model lives — and the write
/// model is the part of Plume that has been wrong silently the most times. Each of the guards below
/// is there because a note was once lost, duplicated or overwritten without a sound.
///
/// Everything here runs on the main actor. The vault's own I/O is on its serial queue and answers
/// back here; the ordering argument for most of this file is that one queue.
@MainActor
public final class NoteSession {

    private let panelID: UUID
    let vault: any VaultServicing
    let state: StateStore
    let settings: SettingsStore
    private let scheduler: any Scheduling
    unowned let output: any NoteSessionOutput

    public init(
        panelID: UUID,
        vault: any VaultServicing,
        state: StateStore,
        settings: SettingsStore,
        scheduler: any Scheduling,
        output: any NoteSessionOutput
    ) {
        self.panelID = panelID
        self.vault = vault
        self.state = state
        self.settings = settings
        self.scheduler = scheduler
        self.output = output
    }

    // MARK: - Session state


    public internal(set) var currentFilename: String?
    var bufferText = ""
    /// Hash of the bytes we believe are on disk. `nil` means "we have not read this file yet", which
    /// `VaultReconciler.react` treats differently from "we read it and it was empty".
    var baselineHash: String?

    /// The buffer hashed the way `VaultIO.write` will store it — trailing newline normalised.
    ///
    /// Every comparison between the buffer and `baselineHash` must go through this. `baselineHash`
    /// holds the hash of what is on disk, and what goes on disk is normalised (decision 10), so a
    /// raw `ContentHash.of(bufferText)` differs from it by exactly one newline on most notes. The
    /// guard in `flush` would then never match, and the panel would rewrite the file every 500 ms for
    /// as long as it was open.
    var bufferHash: String {
        ContentHash.of(MarkdownDocument.normalizeTrailingNewline(bufferText))
    }

    var writeTimer: (any Cancellable)?
    private var isWriting = false
    var writeRequestedWhileWriting = false

    /// A note that has been asked for but not yet written — no file, no name, no state entry.
    ///
    /// ⌘N used to create the file immediately, and decision 2 freezes a filename at creation from
    /// whatever the first line says at that moment. On a note that does not exist yet the first line
    /// says nothing, so **every note anyone ever made with ⌘N was called `untitled` for life** — the
    /// "first few words" half of the scheme had never once run — and a note started and then
    /// abandoned left a permanent zero-length file behind it.
    ///
    /// Decision 2 is untouched by this: the name is still frozen at creation and still never
    /// changes. Creation simply moves from the keystroke that asks for a note to the first write of
    /// one, which is the first moment there is anything to name it after. It also means a note you
    /// asked for and did not write in leaves nothing at all, which is what it should have done.
    public internal(set) var isDraft = false

    /// One create in flight at a time, for `flush`'s reason: two would make two files.
    private var isMaterialising = false

    /// One mid-session download at a time (decision 105a). FSEvents bursts arrive in twos.
    var isDownloadingCurrent = false

    /// The note whose filename is still following its first line (decision 103), if any.
    ///
    /// Set for a note **this panel created**, and cleared by the first of: dismiss, a note switch,
    /// quit, an external write, an external rename, or a hand rename through ⌘K. That list is the
    /// rule — the name follows only while Plume is the only thing that has touched the file and the
    /// note has not been left. Once anything else knows this file by path, renaming under it is
    /// decision 74's trap extended to a process we do not control.
    var unsettledName: String?

    /// Carries "this note was just created here" across the async `open` that follows a create.
    /// `adopt` is shared by every way into a note, and only this one starts the name unsettled.
    private var pendingCreatedName: String?

    /// The caret offset the editor last reported, whether or not there is a file to record it under.
    ///
    /// `recordCaret` is keyed on `currentFilename`, and a draft has none for the whole of its life
    /// — so everything typed before the first write left no caret behind, and the state entry
    /// `adoptDraft` creates started at 0. Any reload before the next keystroke then put the caret at
    /// the top of the note (decision 11 says it restores to the exact offset), and what was typed
    /// next went into the **title**, which decision 103 renames the file after.
    private var lastReportedCaret = 0

    // MARK: - Opening, creating, deleting

    public func openLastUsed() {
        if let last = state.value.lastUsedFilename {
            open(last)
            return
        }
        // Nothing remembered: take whatever the vault has, most recent first.
        vault.rows(query: "", state: state.value, current: nil, order: settings.value.noteOrder) {
            [weak self] snapshot in
            guard let self else { return }
            if let first = snapshot.rows.first {
                self.open(first.filename)
            } else {
                self.create(title: "")
            }
        }
    }

    /// `recordingHistory` is false only when ⌘[ / ⌘] are the ones doing the opening — walking the
    /// history must not itself write history, or Back would just alternate between two notes forever.
    public func open(_ filename: String, recordingHistory: Bool = true) {
        guard filename != currentFilename else {
            output.focusEditor()
            return
        }
        flush(trigger: .noteSwitched)

        vault.load(filename) { [weak self] result in
            guard let self else { return }
            switch result {
            case .loaded(let text, let hash):
                self.adopt(
                    filename: filename, text: text, hash: hash, recordingHistory: recordingHistory)

            case .downloading:
                // Decision 13: never read an evicted note on the main thread, and never pretend a
                // download is instant — it is 5–20 s even for a tiny file.
                self.output.show(.downloading)
                self.vault.download(filename) { [weak self] downloaded in
                    guard let self else { return }
                    if case .loaded(let text, let hash) = downloaded {
                        self.adopt(
                            filename: filename, text: text, hash: hash,
                            recordingHistory: recordingHistory)
                    } else {
                        self.output.show(.problem(L10n.t("error.downloadFailed", ["filename": filename])))
                    }
                }

            case .missing:
                self.state.update { $0.notes.removeValue(forKey: filename) }
                self.checkVaultStillThere()

                // And then open something, because a panel bound to *no* note silently throws away
                // everything typed into it: `flush` returns at its first guard when there is no
                // filename, so the buffer fills up, the word count rises, and not one byte is ever
                // written. Reachable any time the last-used note is gone — deleted in the Finder
                // while Plume was closed, or the vault re-pointed at a folder that does not have it.
                //
                // This terminates: the line above drops the missing note from `notes`, so the next
                // pass picks a different one, and an empty vault ends at a draft rather than
                // another lookup.
                if self.currentFilename == nil, !self.isDraft { self.openLastUsed() }

            case .failed(let message):
                self.output.show(.problem(L10n.t("error.openFailed", ["filename": filename, "message": message])))
            }
        }
    }

    func adopt(
        filename: String, text: String, hash: String, recordingHistory: Bool = true
    ) {
        // Everything typed since `open` asked for this note belongs to the note that was on screen
        // while it was being fetched, and the next four lines replace the buffer holding it.
        //
        // `open` flushes too, which covers the ordinary case where a note loads in a millisecond.
        // A note that has to be **downloaded** does not: decision 13 measures that at 5–20 seconds,
        // and the panel goes on showing and accepting edits into the previous note for all of it
        // (decision 8 — the panel is never made read-only). Measured on the running app: type a
        // character while "Downloading from iCloud…" is up, let the download land inside the 500 ms
        // debounce, and the character is gone — the write timer fires after the buffer has already
        // been replaced, finds the new note's text against the new note's baseline, and declines.
        //
        // That is decision 10's write model wrong for the **fifth** time and silent for the fifth
        // time, and the shape is decisions 56 and 74's exactly: something replacing or moving the
        // buffer without putting what was in it somewhere first.
        if filename != currentFilename { flush(trigger: .noteSwitched) }

        // Recorded here rather than in `open` so the history can only ever contain notes that really
        // opened — a filename that turned out to be missing never reaches this line, which is what
        // keeps Back from walking onto a note that has since been deleted.
        if recordingHistory { recordVisit(filename) }
        // Opening a real note ends any draft. The draft's own text, if it had any, was written by
        // the `flush(trigger: .noteSwitched)` every caller of `open` runs first.
        isDraft = false
        currentFilename = filename
        bufferText = text
        baselineHash = hash
        // Arriving at a note settles its name unless this panel just made it. "The note has not been
        // left" is the rule, and a note switch is leaving it (decision 103).
        unsettledName = (filename == pendingCreatedName) ? filename : nil
        pendingCreatedName = nil

        state.update { $0.recordOpen(filename, at: Date()) }
        setPanelNote(filename)

        let noteState = state.value.note(filename)
        output.load(LoadedNote(
            filename: filename, text: text, caret: noteState.caretOffset, pinned: noteState.isPinned
        ))
        output.show(nil)
        if output.isPanelVisible { output.focusEditor() }

        // Decision 105b, on load as well as on a vault change: a losing version can have been filed
        // days ago, while this note was not open, and nothing would ever have surfaced it. After
        // `hideBanner`, because finding one raises the banner.
        harvestConflicts(of: filename)
    }

    /// ⌘N, and the switcher's "no results — ⏎ makes one titled with what you typed".
    ///
    /// With a title the note is real immediately: the user has already said what it is called, so
    /// there is nothing to wait for. Without one — which is every ⌘N — the panel takes a draft and
    /// the file appears at the first write. See `isDraft`.
    public func create(title: String) {
        flush(trigger: .noteSwitched)
        guard title.isEmpty else {
            createNote(text: title + "\n")
            return
        }
        beginDraft()
    }

    /// An empty panel pointing at nothing, ready to be typed into.
    private func beginDraft() {
        currentFilename = nil
        bufferText = ""
        baselineHash = nil
        isDraft = true

        setPanelNote(nil)

        // Empty filename rather than a made-up one: the web layer reads it as "no note", so ⌃X and
        // the pin decline rather than acting on a file that does not exist.
        output.load(.none)
        output.show(nil)
        if output.isPanelVisible { output.focusEditor() }
    }

    /// Creates a note that already has its text — a duplicate, or a switcher query.
    private func createNote(text: String) {
        vault.create(text: text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let created):
                self.currentFilename = nil        // force `open` past its no-op guard
                // A note made from a switcher query is named from the query, and the user carries on
                // typing the first line — so its name is as unsettled as a draft's (decision 103).
                self.pendingCreatedName = created.filename
                self.open(created.filename)
            case .failure(let error):
                self.output.show(.problem(L10n.t("error.createFailed", ["message": error.localizedDescription])))
                self.checkVaultStillThere()
            }
        }
    }

    /// Turns a draft into a real note, naming it from what has been typed.
    ///
    /// An empty draft is deliberately not written: a note you asked for and did not write in should
    /// leave nothing behind rather than a zero-length file whose name is frozen forever. Whitespace
    /// counts as empty for the same reason — a stray Return is not a note.
    private func materialiseDraft() {
        let text = bufferText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isMaterialising else { return }
        isMaterialising = true

        vault.create(text: text) { [weak self] result in
            guard let self else { return }
            self.isMaterialising = false
            switch result {
            case .success(let created):
                // A note may have been opened while the create was in flight, which makes this
                // draft somebody else's problem — it is already on disk and no longer on screen.
                guard self.isDraft else { return }
                self.isDraft = false
                self.adoptDraft(filename: created.filename, hash: created.hash)
            case .failure(let error):
                self.output.show(.problem(L10n.t("error.createFailed", ["message": error.localizedDescription])))
                self.checkVaultStillThere()
            }
        }
    }

    /// Points the panel at the file a draft just became, **without reloading it**.
    ///
    /// Deliberately not `adopt`: the buffer is already on screen and the user is typing in it, so
    /// sending `loadNote` would replace the document under their hands and move the caret. All that
    /// changes here is which file the buffer belongs to.
    private func adoptDraft(filename: String, hash: String) {
        recordVisit(filename)
        currentFilename = filename
        baselineHash = hash
        // Decision 103. This is the exact case the decision exists for: the file has just appeared
        // under whatever the first line said at the 500 ms pause, which is very often half a title.
        unsettledName = filename

        state.update {
            $0.recordOpen(filename, at: Date())
            // Seeded from the caret the editor last reported, because a draft has no filename to
            // record one under: `.edited` keys `recordCaret` on `currentFilename`, which is nil for
            // the whole of a draft's life. Without this the entry starts at 0, and a reload arriving
            // before the next keystroke — an external write, an eviction — puts the caret at the top
            // of the note. What is typed next then goes into the **title**, which decision 103 uses
            // to rename the file.
            $0.recordCaret(filename, offset: lastReportedCaret)
        }
        setPanelNote(filename)

        output.currentNoteRenamed(to: filename)
        output.pinsChanged()
        output.switcherNeedsRefresh()

        // Typing carried on while the create was in flight, so what is on disk is already behind.
        if bufferHash != baselineHash { scheduleWrite() }
    }

    /// ⌘D. Raycast's key, carried across for the reason decision 39 gives.
    ///
    /// The buffer comes from the web layer rather than being re-read from disk, so a duplicate taken
    /// mid-sentence contains the sentence — the same argument Copy as Markdown makes against the
    /// 500 ms write debounce. The original is flushed first so both copies exist in full.
    public func duplicate(text: String) {
        flush(trigger: .noteSwitched)
        vault.create(text: text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let created):
                self.currentFilename = nil        // force `open` past its no-op guard
                // A copy is named after the note it came from, and retitling the copy is most of
                // why anyone makes one — so its name follows too, until the copy is left
                // (decision 103). Without this a duplicate keeps the original's slug for life.
                self.pendingCreatedName = created.filename
                self.open(created.filename)
                // Decision 50's rule, which had only ever been applied to ⌃X: an action with a
                // consequence that says nothing reads as "nothing happened". ⌘D is the worst case
                // for it — the copy opens looking exactly like the note you were just in, so
                // without this the only evidence anything happened is a filename you cannot see.
                //
                // One word, because that is the whole of what needs saying (decision 76).
                self.output.toast(L10n.t("toast.duplicated"))
            case .failure(let error):
                self.output.show(.problem(L10n.t("error.duplicateFailed", ["message": error.localizedDescription])))
                self.checkVaultStillThere()
            }
        }
    }

    public func togglePin(_ filename: String?) {
        guard let filename = filename ?? currentFilename else { return }
        var pinned = false
        state.update { pinned = $0.togglePin(filename) }

        if filename == currentFilename {
            output.pinnedChanged(pinned)
        }
        output.pinsChanged()
        output.switcherNeedsRefresh()
    }

    public func delete(_ filename: String) {
        // Write what is on screen before moving the file — decision 10's immediate-flush list had
        // dismiss, blur and quit on it and not this, which made ⌃X the one action that could lose
        // typing. Measured: type a sentence, press ⌃X inside the 500 ms debounce, and the copy that
        // lands in Recently Deleted is the *previous* text — for a note created moments ago, a
        // zero-length file. Decision 35 made deleting recoverable and this made it recover the wrong
        // thing, which is worse than not being recoverable at all.
        //
        // Ordering is what makes this safe rather than a race: all vault I/O is one serial queue, so
        // the write enqueued here runs to completion before the move enqueued below starts. The
        // retry flag is cleared for the same reason — a write that lands *after* the move would put
        // the note back in the vault, which is the same bug wearing the opposite mask.
        if filename == currentFilename {
            flush(trigger: .noteSwitched)
            writeRequestedWhileWriting = false
        }

        vault.delete(filename) { [weak self] ok in
            guard let self, ok else { return }
            self.state.update { $0.notes.removeValue(forKey: filename) }
            self.output.pinsChanged()

            // Deleting was silent, which reads as "nothing happened" for the one action where you
            // most want to know that it did — and where the next thought is "can I get it back?".
            // So the message names the place rather than just confirming: ⌃X is one keystroke away
            // from ⌘X, and the answer to hitting it by accident should be on screen, not in the
            // documentation. Floating, so it costs no height (see `.plume__toast`).
            self.output.toast(L10n.t("toast.movedToDeleted"))

            if filename == self.currentFilename {
                self.currentFilename = nil
                self.baselineHash = nil
                self.bufferText = ""
                self.openLastUsed()
            }
            self.output.switcherNeedsRefresh()
        }
    }

    // MARK: - Writing

    /// Decision 10: 500 ms after typing stops, and immediately on dismiss, blur, quit and note
    /// switch.
    private func scheduleWrite() {
        writeTimer?.cancel()
        writeTimer = scheduler.schedule(after: WritePolicy.delay(for: .typingStopped)) { [weak self] in
            self?.flush(trigger: .typingStopped)
        }
    }

    public func flush(trigger: WritePolicy.Trigger) {
        writeTimer?.cancel()
        writeTimer = nil

        // A draft has no file to write to yet, so the write *is* the creation (see `isDraft`).
        // Every trigger reaches here — typing stopped, dismiss, blur, quit, note switch — which is
        // what makes "the file appears at the first write" true rather than aspirational.
        if isDraft {
            materialiseDraft()
            return
        }

        guard let filename = currentFilename else { return }
        guard bufferHash != baselineHash else { return }

        // One write in flight at a time. A second request while the first is coordinating would race
        // the baseline update and could produce a conflict sibling out of our own two writes.
        guard !isWriting else {
            writeRequestedWhileWriting = true
            return
        }
        isWriting = true

        let text = bufferText
        vault.write(text: text, to: filename, expectedHash: baselineHash) { [weak self] result in
            guard let self else { return }
            self.isWriting = false
            var didWrite = false

            switch result {
            case .written(let hash):
                if filename == self.currentFilename { self.baselineHash = hash }
                didWrite = true

            case .conflicted(let sibling, let hash):
                // Decision 8. The original keeps the other machine's version; our text is now in the
                // sibling, so the panel follows its own words there rather than sitting on a file it
                // is no longer allowed to write. Nothing is lost and nothing goes read-only.
                if filename == self.currentFilename {
                    self.currentFilename = sibling
                    self.baselineHash = hash
                    self.state.update { s in
                        var moved = s.note(filename)
                        moved.lastOpened = Date()
                        s.notes[sibling] = moved
                    }
                    self.setPanelNote(sibling)

                    // And tell the web layer, which otherwise goes on holding the *original*
                    // filename — `loadNote` is the only thing that sets it and this path
                    // deliberately does not reload (the buffer is already correct and reloading
                    // would move the caret). The two layers then disagree about which file is open,
                    // and every message that names a file is wrong: ⌃X would delete the original,
                    // the one now holding the other machine's version, and ⇧⌘P would pin it.
                    self.output.currentNoteRenamed(to: sibling)
                    self.output.show(.conflict)
                }

            case .failed(let message):
                self.output.show(.problem(L10n.t("error.saveFailed", ["message": message])))
                self.checkVaultStillThere()
            }

            if self.writeRequestedWhileWriting {
                self.writeRequestedWhileWriting = false
                self.flush(trigger: trigger)
            } else if didWrite {
                // Decision 103, and deliberately here rather than in the `.written` case above: the
                // bytes have to be on disk under the old name before anything moves, **and** no
                // further write may be pending. A write requested during this one is enqueued for
                // the *old* filename, and the vault queue is serial — so renaming first would put
                // that write behind the move, where `VaultIO.write`'s `case .missing: break`
                // recreates the old name. That is the very duplicate this decision came to fix,
                // arriving by a different door.
                self.considerRename()
            }
        }
    }

    // MARK: - The filename follows the title (decision 103)

    /// Asks whether this note's name should move, and moves it if so.
    ///
    /// Piggybacks the 500 ms write debounce rather than running a timer of its own: the question
    /// "has the title changed" only has a new answer when the text has changed, which is exactly
    /// when a write happens.
    private func considerRename() {
        guard let filename = currentFilename, unsettledName == filename, !isWriting else { return }

        let text = bufferText
        holdingTheWriteGate { done in
            vault.renameFollowingTitle(
                filename, title: MarkdownDocument.title(of: text), text: text
            ) { [weak self] result in
                defer { done() }
                guard let self, case .renamed(let newName) = result else { return }
                // The panel may have moved on while the move was on the queue.
                guard self.currentFilename == filename else { return }
                self.repoint(from: filename, to: newName)
                // Still unsettled: the title can go on changing, and so can the name.
                self.unsettledName = newName
            }
        }
    }

    /// Runs a file move under the same gate a write runs under.
    ///
    /// `isWriting` is not really "a write is in flight" — it is "nothing else may write to this
    /// note's name right now", and a rename needs exactly that. Without it a `scheduleWrite` timer
    /// firing mid-move enqueues a write for the *old* filename behind the move on the serial vault
    /// queue, and `VaultIO.write` recreates a note it finds missing. Anything deferred this way is
    /// flushed once the name has settled, so nothing is dropped — only delayed by one hop.
    private func holdingTheWriteGate(_ body: (@escaping @MainActor () -> Void) -> Void) {
        isWriting = true
        body { [weak self] in
            guard let self else { return }
            self.isWriting = false
            if self.writeRequestedWhileWriting {
                self.writeRequestedWhileWriting = false
                self.flush(trigger: .typingStopped)
            }
        }
    }

    /// Points everything that knows this note by name at its new one.
    ///
    /// **This is decision 74's list**, and it has now been got wrong twice — Move Notes wrote to the
    /// old folder, and after a conflict the editor did not know which file it was in, so ⌃X would
    /// have deleted the original. One function so there is one list: the panel's own pointer, the
    /// state entry carrying the caret, the pin and `lastOpened`, the panel record, the visit history,
    /// the web layer's copy of the name, the menu bar's pins, and an open switcher.
    ///
    /// `baselineHash` is deliberately untouched: a rename moves the same bytes, so what is on disk
    /// still matches what we last wrote. `NoteIndex` moves inside `VaultService.rename`, on the
    /// queue that owns it.
    func repoint(from old: String, to new: String) {
        currentFilename = new

        state.update { s in
            if let moved = s.notes.removeValue(forKey: old) { s.notes[new] = moved }
        }

        setPanelNote(new)

        // Back and Forward hold filenames, so an un-rewritten entry is a ⌘[ onto a file that no
        // longer exists — which `open` would then treat as a missing note and drop from state.
        history.rename(old, to: new)

        // The web layer is told for the same reason the conflict path tells it: `loadNote` is the
        // only other thing that sets this, and this path must not reload (it would move the caret).
        output.currentNoteRenamed(to: new)
        output.pinsChanged()
        output.switcherNeedsRefresh()
    }

    /// ⌘K's "Rename File…", after the dialog. The panel asks the user for a name (that is AppKit) and
    /// hands over the slug; everything from here is the session's.
    ///
    /// `typed` is what the user entered. Only the slug is editable: the timestamp is the creation
    /// time and the real content of the naming scheme, so a rename that could rewrite it would be a
    /// different feature.
    public func rename(toTyped typed: String) {
        guard let filename = currentFilename else { return }
        let prefix = Self.frozenPrefix(of: filename)

        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field is a slip, not a request for a note called `untitled` — and unlike the
        // automatic rename this one cannot be undone by typing the next character.
        guard !typed.isEmpty else { return }
        // Through `slug` rather than taken literally: what the user types is a title, and the same
        // rules that make a filename out of a first line make one out of this.
        let slug = NoteFilename.slug(from: typed)
        let newName = NoteFilename.unique(
            stem: prefix + slug,
            existing: [] // uniquing against the vault happens in `VaultService.rename`, which refuses
                         // an existing destination — asking twice would race the answer anyway.
        )
        guard newName != filename else { return }

        // Flush before the file moves. The same rule ⌃X and every vault re-point follow, and the one
        // this path can actually break — there may be up to 500 ms of typing outstanding.
        flush(trigger: .noteSwitched)
        let text = bufferText
        holdingTheWriteGate { done in
            vault.rename(filename, to: newName, text: text) { [weak self] result in
                defer { done() }
                guard let self else { return }
                switch result {
                case .renamed(let moved):
                    guard self.currentFilename == filename else { return }
                    self.repoint(from: filename, to: moved)
                    // The user has chosen a name. Nothing may move it again.
                    self.unsettledName = nil
                case .declined:
                    self.output.show(.problem(L10n.t("error.renameTaken")))
                case .failed(let message):
                    self.output.show(.problem(L10n.t("error.renameFailed", ["message": message])))
                }
            }
        }
    }

    /// The part of a note's name the dialog shows but does not offer: `2026-08-11-1453-` for a name
    /// made by Plume, empty for one that was not.
    public static func frozenPrefix(of filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        guard NoteFilename.creationDate(from: filename) != nil else { return "" }
        return String(Array(stem).prefix(NoteFilename.timestampWidth + 1))
    }

    // MARK: - Events from the editor

    /// The buffer changed. Carries the whole text, because the write debounce leaves the session's
    /// copy up to 500 ms behind what is on screen.
    public func edited(text: String, caret: Int) {
        bufferText = text
        lastReportedCaret = caret
        if let filename = currentFilename {
            state.update { $0.recordCaret(filename, offset: caret) }
            vault.noteBufferChanged(filename: filename, text: text)
        }
        scheduleWrite()
    }

    public func caretMoved(_ caret: Int, scrollLine: Int) {
        lastReportedCaret = caret
        guard let filename = currentFilename else { return }
        state.update { $0.recordCaret(filename, offset: caret, scrollLine: scrollLine) }
    }

    /// The panel was dismissed. The write still lands (the caller flushes); only the *name* stops
    /// following the title, so a note comes back on the next summon under the name you left it with.
    public func left() {
        unsettledName = nil
    }

    /// The editor is ready, or the panel was summoned: if nothing is open — and no draft is — open
    /// the last note. `isDraft` as well as the filename: a draft has no filename by design, and
    /// opening the last-used note over the top of one would throw away whatever had been typed.
    public func openLastUsedIfNothingOpen() {
        if currentFilename == nil, !isDraft { openLastUsed() }
    }

    public var isPinned: Bool {
        guard let currentFilename else { return false }
        return state.value.note(currentFilename).isPinned
    }

    /// The buffer as the session last heard it, for actions that act on the whole note.
    public var buffer: String { bufferText }

    // MARK: - History

    private var history = NavigationHistory()

    private func recordVisit(_ filename: String) { history.recordVisit(filename) }

    public func goBack() {
        guard let filename = history.back() else { return }
        open(filename, recordingHistory: false)
    }

    public func goForward() {
        guard let filename = history.forward() else { return }
        open(filename, recordingHistory: false)
    }

    // MARK: - Panel record

    private func setPanelNote(_ filename: String?) {
        state.updatePanel(id: panelID) { $0.noteFilename = filename }
    }
}
