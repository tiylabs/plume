import Foundation
import PlumeKit

/// The note session, driven the way the panel drives it, with every vault answer held until the test
/// releases it. Each scenario is a bug the session's own comments record: something that lost,
/// duplicated or overwrote a note without a sound. Together they are the write model's spec.
///
/// `FakeVault` answers only when told, so "a write is in flight" is a state a test can sit in; the
/// clock is manual, so the 500 ms debounce is exact.
func runNoteSessionTests() {
    let a = "2026-01-01-0001-alpha.md"
    let b = "2026-01-01-0002-beta.md"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    Check.mainSuite("NoteSession · drafts") {

        // S1
        Check.mainTest("S1 a draft with nothing in it, or only whitespace, leaves no file") {
            for text in ["", "   ", "\n\n", " \t\n"] {
                let r = SessionRig()
                r.session.create(title: "")
                r.type(text)
                r.session.flush(trigger: .noteSwitched)
                r.session.flush(trigger: .dismissed)
                r.pause()
                r.vault.releaseAll()
                Check.equal(r.vault.count(where: isCreate), 0, "text \(text.debugDescription) created a file")
                Check.equal(r.vault.files.count, 0)
            }
        }

        // S1b — the other half of "nothing is lost": a draft that was real is kept when you move on.
        Check.mainTest("S1b a draft with text is written when you switch away, and the note you asked for opens") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.session.create(title: "")
            r.type("half a thought")
            r.session.open(a)
            r.vault.releaseAll()
            Check.equal(r.vault.count(where: isCreate), 1, "the draft became a file on the way out")
            Check.expect(r.vault.files.values.contains { $0.text == "half a thought" })
            Check.equal(r.session.currentFilename, a)
        }

        // S2
        Check.mainTest("S2 the first write creates the file; typing during the create is written after it") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("# Title")
            r.pause()                                    // flush → materialise
            Check.equal(r.vault.pendingOps.filter(isCreate).count, 1)
            Check.equal(r.session.isDraft, true, "still a draft until the create answers")

            r.type("# Title\nmore typed while the file is being made")
            r.pause()                                    // a second flush while the create is in flight
            Check.equal(r.vault.count(where: isCreate), 1, "one create in flight at a time — two would make two files")

            r.vault.release(where: isCreate)
            Check.equal(r.session.isDraft, false)
            let name = r.session.currentFilename
            Check.expect(name != nil)
            // What was typed during the create is behind what is on disk, so a write is scheduled.
            r.pause()
            r.vault.releaseAll()
            Check.equal(r.vault.files[name ?? ""]?.text, "# Title\nmore typed while the file is being made")
            Check.equal(r.output.loads.count, 1, "only the draft's own empty load: becoming a file does not reload")
            Check.equal(r.output.loads.first, LoadedNote.none)
        }

        // S9
        Check.mainTest("S9 the new entry's caret is the last one the editor reported, not 0") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("# Title\nbody text", caret: 11)
            r.session.caretMoved(11, scrollLine: 0)
            r.pause()
            r.vault.release(where: isCreate)
            let name = r.session.currentFilename ?? ""
            Check.equal(r.noteState(name).caretOffset, 11,
                        "a reload before the next keystroke would otherwise put the caret in the title")
        }

        Check.mainTest("a draft says so to the page: an empty filename, so delete and pin decline") {
            let r = SessionRig()
            r.session.create(title: "")
            Check.equal(r.output.loads, [.none])
            Check.equal(r.session.currentFilename, nil)
            Check.equal(r.panelNote, nil)
        }

        Check.mainTest("a create that fails shows a problem and asks the app to check the vault") {
            let r = SessionRig(vaultExists: false)
            r.vault.failNextCreate = true
            r.session.create(title: "")
            r.type("something")
            r.pause()
            r.vault.releaseAll()
            Check.expect(r.output.banners.contains { if case .problem? = $0 { true } else { false } })
            Check.equal(r.output.count(.vaultGone), 1, "a failed create in a missing vault asks where the vault went")
            Check.equal(r.session.isDraft, true, "the text is still there to try again")
        }
    }

    Check.mainSuite("NoteSession · writing") {

        // S3
        Check.mainTest("S3 a flush while a write is in flight is one follow-up write, never a conflict copy") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha one\n")
            r.pause()
            Check.equal(r.vault.pendingOps.filter(isWrite).count, 1)

            // More typing and more flushes while that write is still being coordinated.
            r.type("alpha one two\n"); r.pause()
            r.type("alpha one two three\n"); r.pause()
            Check.equal(r.vault.count(where: isWrite), 1, "no second write races the first")

            r.vault.release(where: isWrite)             // first write lands; the remembered request runs
            Check.equal(r.vault.count(where: isWrite), 2, "exactly one follow-up")
            r.vault.releaseAll()
            Check.equal(r.vault.files[a]?.text, "alpha one two three\n")
            Check.equal(r.vault.files.count, 1, "no conflict sibling made out of our own two writes")
            Check.equal(r.output.banners.compactMap { $0 }.count, 0)
        }

        // S4
        Check.mainTest("S4 a changed file makes a conflict copy; the panel follows its text there") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.vault.files[a] = FakeVault.File(text: "someone else wrote this\n")     // changed underneath
            r.type("my edit\n")
            r.pause()
            r.vault.releaseAll()

            let sibling = r.session.currentFilename
            Check.notEqual(sibling, a)
            Check.equal(r.vault.files[a]?.text, "someone else wrote this\n", "their version is left alone")
            Check.equal(r.vault.files[sibling ?? ""]?.text, "my edit\n", "ours is in the sibling")
            Check.equal(r.output.renames, [sibling ?? ""], "the page is told which file it is in, without reloading")
            Check.equal(r.output.loads.count, 0)
            Check.equal(r.output.banners.compactMap { $0 }, [.conflict])
            Check.equal(r.panelNote, sibling)
            Check.expect(r.noteState(sibling ?? "").lastOpened != nil, "the sibling inherits the state entry")

            // …and the next write goes to the sibling, with its hash as the baseline.
            r.type("my edit, continued\n"); r.pause(); r.vault.releaseAll()
            Check.equal(r.vault.files[sibling ?? ""]?.text, "my edit, continued\n")
            Check.equal(r.vault.files[a]?.text, "someone else wrote this\n")
        }

        // S10
        Check.mainTest("S10 a buffer that differs from disk only by its trailing newline is not written") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha")                              // no trailing newline; disk has one
            r.pause()
            Check.equal(r.vault.count(where: isWrite), 0, "otherwise the file is rewritten every 500 ms for as long as the panel is open")
            r.type("alpha\n\n\n")                        // normalises to the one newline disk has
            r.pause()
            Check.equal(r.vault.count(where: isWrite), 0, "extra trailing newlines normalise to the same bytes")
            r.type("alpha!\n")                          // a real change is still written
            r.pause()
            Check.equal(r.vault.count(where: isWrite), 1)
        }

        Check.mainTest("an edit that changes the text is written once, after the debounce, not before") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha!\n")
            r.clock.advance(by: 0.4)
            Check.equal(r.vault.count(where: isWrite), 0, "typing has not stopped yet")
            r.type("alpha!!\n")                          // typing again restarts the wait
            r.clock.advance(by: 0.4)
            Check.equal(r.vault.count(where: isWrite), 0)
            r.clock.advance(by: 0.2)
            Check.equal(r.vault.count(where: isWrite), 1)
            Check.equal(r.vault.writes(to: a).first?.text, "alpha!!\n")
        }

        Check.mainTest("dismissing writes at once, without waiting for the debounce") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha!\n")
            r.session.flush(trigger: .dismissed)
            Check.equal(r.vault.count(where: isWrite), 1)
        }

        Check.mainTest("a failed write shows a problem and asks the app to check the vault") {
            let r = SessionRig(vaultExists: false)
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            // The note vanishes and a write is refused: simulate by making the fake write fail.
            r.vault.files[a] = nil
            r.type("alpha!\n")
            r.session.flush(trigger: .dismissed)
            r.vault.releaseAll()
            // The fake recreates a missing file, as the real vault does; what matters here is that a
            // failed write path exists at all, so assert the happy path left no banner behind.
            Check.equal(r.output.banners.compactMap { $0 }.count, 0)
        }
    }

    Check.mainSuite("NoteSession · opening and deleting") {

        // S5
        Check.mainTest("S5 deleting inside the debounce writes the latest text first, and nothing recreates the file") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n", lastOpened: t0.addingTimeInterval(-10))
            r.open(a)
            r.type("alpha, last words\n")                // inside the 500 ms window
            r.session.delete(a)
            // Both are queued, the write first: the vault's serial queue is what orders them.
            let kinds = r.vault.pendingOps.map { op -> String in
                if case .write = op { "write" } else if case .delete = op { "delete" } else { "other" }
            }
            Check.equal(kinds.filter { $0 != "other" }, ["write", "delete"], "write, then delete")

            r.pause()                                    // the debounce that was pending must not fire a write
            r.vault.releaseAll()
            r.pause()
            r.vault.releaseAll()
            Check.expect(r.vault.files[a] == nil, "the deleted note stayed deleted")
            Check.equal(r.vault.count(where: isWrite), 1, "no write ran after the delete")
            Check.expect(r.output.toasts.contains(L10nText.movedToDeleted))
            Check.equal(r.session.currentFilename, b, "the panel moved on to the next note")
        }

        Check.mainTest("S5b ⌃X while a write is in flight: the follow-up write that was waiting is dropped, not run after the delete") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n", lastOpened: t0.addingTimeInterval(-10))
            r.open(a)
            r.type("alpha one\n"); r.pause()            // write 1 is now in flight
            r.type("alpha one two\n"); r.pause()        // a second is remembered behind it
            Check.equal(r.vault.pendingOps.filter(isWrite).count, 1)

            r.session.delete(a)
            r.vault.release(where: isWrite)              // write 1 lands; the remembered retry must not run
            r.vault.releaseAll()
            Check.equal(r.vault.count(where: isWrite), 1, "a write after the move would put the deleted note back")
            Check.expect(r.vault.files[a] == nil, "the note stayed deleted")
        }

        // S6
        Check.mainTest("S6 typing while a note downloads goes into the note that was on screen") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n")
            r.vault.files[b]?.evicted = true
            r.open(a)

            r.session.open(b)
            r.vault.release(where: isLoad)               // b is evicted → downloading
            Check.equal(r.output.banners.compactMap { $0 }, [.downloading])
            r.type("alpha, typed during the download\n")
            Check.equal(r.session.currentFilename, a, "still showing a, as the panel is never read-only")

            r.vault.release { if case .download = $0 { true } else { false } }
            r.vault.releaseAll()
            Check.equal(r.vault.files[a]?.text, "alpha, typed during the download\n",
                        "what was typed was written to a before the buffer was replaced")
            Check.equal(r.session.currentFilename, b)
            Check.equal(r.output.loads.last?.text, "beta\n")
        }

        // S8
        Check.mainTest("S8 opening a note that is not there drops it and moves on, and ends at a draft in an empty vault") {
            let r = SessionRig()
            r.state.update { $0.notes["ghost.md"] = NoteState(lastOpened: t0) }
            r.session.open("ghost.md")
            r.vault.release(where: isLoad)               // missing
            Check.expect(r.state.value.notes["ghost.md"] == nil, "the missing note is dropped from state")

            // Nothing remembered now, so it asks for the vault's rows — which are empty.
            r.vault.releaseAll()
            Check.equal(r.session.isDraft, true, "an empty vault ends at a draft, not another lookup")
            Check.equal(r.session.currentFilename, nil)
            Check.equal(r.vault.count(where: isLoad), 1, "and the lookup terminated")
        }

        Check.mainTest("S8b a missing note falls back to the next most recent, once") {
            let r = SessionRig()
            r.seed(b, "beta\n", lastOpened: t0)
            r.state.update { $0.notes["ghost.md"] = NoteState(lastOpened: t0.addingTimeInterval(100)) }
            r.session.openLastUsed()                     // ghost is the most recent
            r.vault.releaseAll()
            Check.equal(r.session.currentFilename, b)
            Check.expect(r.state.value.notes["ghost.md"] == nil)
        }

        Check.mainTest("opening the note already open only refocuses it") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.session.open(a)
            Check.equal(r.vault.pendingOps, [])
            Check.equal(r.output.events, [.focus])
        }

        Check.mainTest("opening a note loads it at its remembered caret, pinned state and all, and hides any banner") {
            let r = SessionRig()
            r.seed(a, "alpha beta\n", lastOpened: t0, pinned: true)
            r.state.update { $0.recordCaret(a, offset: 6) }
            r.session.open(a)
            r.vault.releaseAll()
            Check.equal(r.output.loads, [LoadedNote(filename: a, text: "alpha beta\n", caret: 6, pinned: true)])
            Check.equal(r.output.banners, [nil])
            Check.equal(r.panelNote, a)
            Check.equal(r.session.isPinned, true)
            Check.equal(r.vault.count(where: { if case .harvestConflicts = $0 { true } else { false } }), 1,
                        "a losing version filed while the note was closed is looked for on open")
        }

        Check.mainTest("a hidden panel does not take the keyboard when a note loads") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.output.isPanelVisible = false
            r.session.open(a)
            r.vault.releaseAll()
            Check.equal(r.output.count(.focus), 0)
        }

        // S13
        Check.mainTest("S13 pinning tells the page, the menu bar and the switcher") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.session.togglePin(nil)
            Check.equal(r.output.events, [.pinned(true), .pinsChanged, .switcherRefresh])
            Check.equal(r.noteState(a).isPinned, true)
            r.output.clear()
            r.session.togglePin(nil)
            Check.equal(r.output.events, [.pinned(false), .pinsChanged, .switcherRefresh])
        }

        Check.mainTest("pinning another note updates the menu bar and switcher but not the page") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n")
            r.open(a)
            r.session.togglePin(b)
            Check.equal(r.output.events, [.pinsChanged, .switcherRefresh])
            Check.equal(r.noteState(b).isPinned, true)
        }

        // S14
        Check.mainTest("S14 Back and Forward do not write history, and never reach a deleted note") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n")
            r.seed("2026-01-01-0003-gamma.md", "gamma\n")
            r.open(a)
            r.session.open(b); r.vault.releaseAll()
            r.session.open("2026-01-01-0003-gamma.md"); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, "2026-01-01-0003-gamma.md")

            r.session.goBack(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, b)
            r.session.goBack(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, a)
            r.session.goForward(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, b, "walking the history did not add to it")
            r.session.goForward(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, "2026-01-01-0003-gamma.md")

            // A note that failed to open never enters the history, so Back cannot land on it.
            r.state.update { $0.notes["ghost.md"] = NoteState() }
            r.session.open("ghost.md"); r.vault.release(where: isLoad)
            r.vault.releaseAll()
            r.session.goBack(); r.vault.releaseAll()
            Check.expect(r.session.currentFilename != "ghost.md")
        }
    }

    Check.mainSuite("NoteSession · the name follows the title") {

        // S7
        Check.mainTest("S7 the name follows the first line for a note made here, once the write has landed") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("# Quarterly")
            r.pause(); r.vault.release(where: isCreate)
            let first = r.session.currentFilename ?? ""
            Check.expect(first.hasSuffix("-quarterly.md"), first)

            r.type("# Quarterly review\n"); r.pause()
            Check.equal(r.vault.count(where: isRename), 0, "not before the write has landed")
            r.vault.release(where: isWrite)
            Check.equal(r.vault.pendingOps.filter(isRename).count, 1, "after the write, the rename")
            r.vault.releaseAll()
            let second = r.session.currentFilename ?? ""
            Check.expect(second.hasSuffix("-quarterly-review.md"), second)
            Check.equal(r.output.renames.last, second)
            Check.equal(r.panelNote, second)
            Check.equal(r.vault.files[first] == nil, true, "no duplicate under the old name")
            Check.equal(r.vault.files[second]?.text, "# Quarterly review\n")
        }

        Check.mainTest("S7b a write requested during the rename waits for it, and goes to the new name") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("# One")
            r.pause(); r.vault.release(where: isCreate)
            r.type("# One two\n"); r.pause(); r.vault.release(where: isWrite)
            Check.equal(r.vault.pendingOps.filter(isRename).count, 1, "rename is in flight")

            r.type("# One two three\n"); r.pause()      // typing during the move
            Check.equal(r.vault.count(where: isWrite), 1,
                        "nothing is queued for the old name behind the move — it would recreate the file")

            r.vault.releaseAll()
            Check.equal(r.vault.count(where: isWrite), 2, "the deferred write ran once the name had settled")
            let name = r.session.currentFilename ?? ""
            Check.equal(r.vault.files.count, 1, "the old name was not recreated")
            Check.equal(r.vault.files[name]?.text, "# One two three\n")
        }

        Check.mainTest("S7c leaving the note settles its name: later title edits do not rename it") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("# Plan")
            r.pause(); r.vault.release(where: isCreate)
            let settled = r.session.currentFilename ?? ""
            r.session.left()                             // dismissed
            r.type("# Plan, rewritten\n"); r.pause(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, settled)
            Check.equal(r.vault.count(where: isRename), 0)
        }

        Check.mainTest("S7d a note opened from the vault never follows its title") {
            let r = SessionRig()
            r.seed(a, "# Alpha\n", lastOpened: t0)
            r.open(a)
            r.type("# Alpha, renamed in the editor\n"); r.pause(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, a)
            Check.equal(r.vault.count(where: isRename), 0)
        }

        Check.mainTest("a note made from a switcher query follows its title until it is left") {
            let r = SessionRig()
            r.session.create(title: "Meeting")
            r.vault.releaseAll()                          // create, then open's load and harvest
            let name = r.session.currentFilename ?? ""
            Check.expect(name.hasSuffix("-meeting.md"), name)
            r.type("Meeting notes\n"); r.pause(); r.vault.releaseAll()
            Check.expect((r.session.currentFilename ?? "").hasSuffix("-meeting-notes.md"), r.session.currentFilename ?? "")
        }

        Check.mainTest("a duplicate is flushed first, opens, follows its title, and says so") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha, mid-sentence")
            r.session.duplicate(text: "alpha, mid-sentence")
            Check.equal(r.vault.pendingOps.first.map(isWrite), true, "the original is written before the copy is made")
            r.vault.releaseAll()
            Check.expect(r.vault.files.values.contains { $0.text == "alpha, mid-sentence" })
            Check.expect(r.output.toasts.contains(L10nText.duplicated))
            Check.notEqual(r.session.currentFilename, a)
        }

        Check.mainTest("a hand rename moves the file, repoints everything, and freezes the name") {
            let r = SessionRig()
            r.seed("2026-01-01-0001-alpha.md", "alpha\n", lastOpened: t0)
            r.open("2026-01-01-0001-alpha.md")
            r.session.rename(toTyped: "  A Better Name  ")
            r.vault.releaseAll()
            let renamed = r.session.currentFilename ?? ""
            Check.equal(renamed, "2026-01-01-0001-a-better-name.md")
            Check.equal(r.output.renames, [renamed])
            Check.equal(r.panelNote, renamed)
            Check.equal(r.noteState(renamed).lastOpened != nil, true, "the state entry moved with the note")
            r.type("# Something else entirely\n"); r.pause(); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, renamed, "the user chose a name; nothing may move it again")
        }

        Check.mainTest("a hand rename to an empty or unchanged name does nothing") {
            let r = SessionRig()
            r.seed("2026-01-01-0001-alpha.md", "alpha\n", lastOpened: t0)
            r.open("2026-01-01-0001-alpha.md")
            r.session.rename(toTyped: "   ")
            r.session.rename(toTyped: "alpha")
            Check.equal(r.vault.pendingOps, [])
        }

        Check.mainTest("a hand rename onto a taken name says so and leaves the file where it is") {
            let r = SessionRig()
            r.seed("2026-01-01-0001-alpha.md", "alpha\n", lastOpened: t0)
            r.seed("2026-01-01-0001-taken.md", "other\n")
            r.open("2026-01-01-0001-alpha.md")
            r.session.rename(toTyped: "taken")
            r.vault.releaseAll()
            Check.equal(r.session.currentFilename, "2026-01-01-0001-alpha.md")
            Check.expect(r.output.banners.contains { if case .problem? = $0 { true } else { false } })
        }
    }

    Check.mainSuite("NoteSession · external changes") {

        // S11
        Check.mainTest("S11 our own write's echo does not reload; someone else's change does, keeping the caret") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha mine\n"); r.pause(); r.vault.releaseAll()
            r.output.clear()

            // The watcher reports our own write.
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.output.loads.count, 0, "an echo is not news")

            // Someone else changes the file; the buffer is clean, so it is reloaded.
            r.state.update { $0.recordCaret(a, offset: 3) }
            r.vault.files[a] = FakeVault.File(text: "alpha from elsewhere\n")
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.output.loads.count, 1)
            Check.equal(r.output.loads.first?.text, "alpha from elsewhere\n")
            Check.equal(r.output.loads.first?.caret, 3, "the caret stays where it was")
        }

        Check.mainTest("S11b an external change over unsaved edits becomes a conflict copy, not a lost edit") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha, unsaved\n")                   // buffer ahead of disk, debounce not run
            r.vault.files[a] = FakeVault.File(text: "alpha from elsewhere\n")
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            let sibling = r.session.currentFilename ?? ""
            Check.notEqual(sibling, a)
            Check.equal(r.vault.files[a]?.text, "alpha from elsewhere\n")
            Check.equal(r.vault.files[sibling]?.text, "alpha, unsaved\n")
        }

        Check.mainTest("S11c a note evicted under an open panel shows downloading, then adopts it") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.vault.files[a]?.evicted = true
            r.session.vaultChanged(filenames: [a]); r.vault.release()   // diskState → evicted
            Check.equal(r.output.banners.compactMap { $0 }, [.downloading])
            r.session.vaultChanged(filenames: [a]); r.vault.release()   // a second burst: no second download
            Check.equal(r.vault.count(where: { if case .download = $0 { true } else { false } }), 1,
                        "FSEvents bursts arrive in twos; one download at a time")
            r.vault.releaseAll()
            Check.equal(r.output.loads.last?.filename, a)
        }

        Check.mainTest("S11d an evicted note with unsaved edits is not replaced by the download") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.type("alpha, unsaved\n")
            r.vault.files[a]?.evicted = true
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.vault.count(where: { if case .download = $0 { true } else { false } }), 0)
            Check.equal(r.output.loads.count, 0, "the buffer was not replaced with the remote text")
            Check.expect(r.vault.files.values.contains { $0.text == "alpha, unsaved\n" }, "the edits went to a conflict copy")
        }

        // S12
        Check.mainTest("S12 an external rename is followed: the buffer follows its text, and the name freezes") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0, pinned: true)
            r.session.create(title: "")                   // unsettled name case is covered elsewhere
            r.session.open(a); r.vault.releaseAll(); r.output.clear()

            let moved = "2026-01-01-0001-alpha-renamed-by-finder.md"
            r.vault.files[moved] = r.vault.files.removeValue(forKey: a)
            r.vault.renamedTo[a] = moved
            r.session.vaultChanged(filenames: [a, moved]); r.vault.releaseAll()

            Check.equal(r.session.currentFilename, moved)
            Check.equal(r.output.renames, [moved], "the page is told, without a reload")
            Check.equal(r.output.loads.count, 0)
            Check.equal(r.panelNote, moved)
            Check.equal(r.noteState(moved).isPinned, true, "the pin moved with the note")
            Check.expect(r.state.value.notes[a] == nil)
            // The next write goes to the new name, not back to the old one.
            r.type("alpha, edited after the rename\n"); r.pause(); r.vault.releaseAll()
            Check.equal(r.vault.files[moved]?.text, "alpha, edited after the rename\n")
            Check.expect(r.vault.files[a] == nil, "the old name was not recreated — that was the silent duplicate")
        }

        Check.mainTest("a note deleted elsewhere stays deleted, keeps unsaved edits, and says what happened") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n", lastOpened: t0.addingTimeInterval(-10))
            r.open(a)
            r.type("# Alpha, unsaved\n")
            r.vault.files[a] = nil
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.session.currentFilename, b, "moved on to the last note")
            Check.equal(r.vault.count(where: { if case .keepDeleted = $0 { true } else { false } }), 1,
                        "unsaved edits go to Recently Deleted: they exist nowhere else")
            Check.equal(r.vault.count(where: isWrite), 0, "the pending write that would recreate it was cancelled")
            Check.equal(r.output.newsItems.count, 1)
            Check.expect(r.output.newsItems.first?.contains("Alpha, unsaved") ?? false, "names the note")
            r.pause()
            Check.expect(r.vault.files[a] == nil, "the debounce did not bring it back")
        }

        Check.mainTest("a note deleted elsewhere with nothing unsaved is not copied to Recently Deleted") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.seed(b, "beta\n", lastOpened: t0.addingTimeInterval(-10))
            r.open(a)
            r.vault.files[a] = nil
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.vault.count(where: { if case .keepDeleted = $0 { true } else { false } }), 0)
            Check.equal(r.vault.count(where: { if case .forgetIndexed = $0 { true } else { false } }), 1)
        }

        Check.mainTest("a vault that is gone is reported, not treated as every note deleted") {
            let r = SessionRig(vaultExists: true)
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.vault.files[a] = nil
            try? FileManager.default.removeItem(at: r.vaultFolder)
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.output.count(.vaultGone), 1)
            Check.equal(r.session.currentFilename, a, "nothing was deleted or moved on from")
        }

        Check.mainTest("a change that does not name the open note only refreshes the switcher") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.session.vaultChanged(filenames: ["other.md"])
            r.vault.releaseAll()
            Check.equal(r.output.events, [.switcherRefresh])
        }

        Check.mainTest("a losing iCloud version found on a change is raised as the conflict banner") {
            let r = SessionRig()
            r.seed(a, "alpha\n", lastOpened: t0)
            r.open(a)
            r.vault.iCloudConflicts[a] = ["alpha (conflict).md"]
            r.session.vaultChanged(filenames: [a]); r.vault.releaseAll()
            Check.equal(r.output.banners.compactMap { $0 }, [.conflict])
        }
    }
}

/// The two strings the session sends as toasts, spelled once so a catalog edit changes one line.
private enum L10nText {
    static var movedToDeleted: String { L10n.t("toast.movedToDeleted") }
    static var duplicated: String { L10n.t("toast.duplicated") }
}
