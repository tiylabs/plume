import Foundation
import PlumeKit

/// Exercise the asynchronous create through the session, so the lifecycle ticket must guard the
/// actual filename, buffer, state and follow-up writes rather than only the pure value type.
func runNoteSessionDraftTests() {
    Check.mainSuite("NoteSession · draft create races") {

        Check.mainTest("an empty new draft never adopts or overwrites the previous draft's file") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("first thought")
            r.session.create(title: "")             // flush A inside the debounce, then show B
            Check.equal(r.vault.pendingOps.filter(isCreate).count, 1)

            r.vault.release(where: isCreate)
            let first = r.vault.files.keys.first ?? ""
            Check.equal(r.session.isDraft, true)
            Check.equal(r.session.currentFilename, nil)
            Check.equal(r.session.buffer, "")
            Check.equal(r.panelNote, nil)
            Check.equal(r.state.value.notes[first], nil, "A's completion must not record B as opening A")
            Check.equal(r.output.renames, [])

            r.pause()
            r.session.flush(trigger: .dismissed)
            r.vault.releaseAll()
            Check.equal(r.vault.files[first]?.text, "first thought")
            Check.equal(r.vault.files.count, 1)
            Check.equal(r.vault.count(where: isWrite), 0, "B's empty buffer must not be written into A")
            Check.equal(r.vault.count(where: isCreate), 1, "an empty B leaves no file")
        }

        Check.mainTest("a newer draft whose flush was blocked creates its own file when the old create answers") {
            let r = SessionRig()
            r.session.create(title: "")
            r.type("first thought")
            r.session.create(title: "")
            r.type("second thought", caret: 5)
            r.pause()                                // B's flush waits behind A's create
            Check.equal(r.vault.count(where: isCreate), 1)

            r.vault.release(where: isCreate)
            let first = r.vault.files.keys.first ?? ""
            Check.equal(r.session.isDraft, true)
            Check.equal(r.session.currentFilename, nil)
            Check.equal(r.vault.pendingOps.filter(isCreate), [.create(text: "second thought")])
            Check.equal(r.output.renames, [])

            r.type("second thought\ncontinued", caret: 8)
            r.vault.release(where: isCreate)
            let second = r.session.currentFilename ?? ""
            Check.notEqual(second, first)
            Check.equal(r.session.isDraft, false)
            Check.equal(r.panelNote, second)
            Check.equal(r.noteState(second).caretOffset, 8)
            Check.equal(r.output.renames, [second])
            Check.equal(r.output.loads, [.none, .none], "adoption must keep the editor buffer and caret")

            r.pause()
            r.vault.releaseAll()
            Check.equal(r.vault.files[first]?.text, "first thought")
            Check.equal(r.vault.files[second]?.text, "second thought\ncontinued")
            Check.equal(r.vault.files.count, 2)
            Check.equal(r.vault.writes(to: first).count, 0)
            Check.equal(r.vault.count(where: isCreate), 2)
        }

        Check.mainTest("an old draft's create cannot replace a real note opened before its answer") {
            let r = SessionRig()
            let note = "existing.md"
            r.seed(note, "existing text\n")
            r.session.create(title: "")
            r.type("draft text")
            r.pause()
            r.session.open(note)
            r.vault.release(where: isLoad)
            r.output.clear()

            r.vault.release(where: isCreate)
            r.pause()
            r.vault.releaseAll()
            Check.equal(r.session.isDraft, false)
            Check.equal(r.session.currentFilename, note)
            Check.equal(r.session.buffer, "existing text\n")
            Check.equal(r.panelNote, note)
            Check.equal(r.output.renames, [])
            Check.equal(r.vault.files[note]?.text, "existing text\n")
            Check.expect(r.vault.files.values.contains { $0.text == "draft text" })
            Check.equal(r.vault.count(where: isCreate), 1)
        }
    }
}
