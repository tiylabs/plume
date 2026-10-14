import Foundation
import PlumeKit

/// An agent writing to the note open in the panel: a real vault, a real session, the real handler.
@MainActor
func runAgentSessionTests() {

    @MainActor
    final class Rig {
        let agent = AgentRig()
        let output = RecordingOutput()
        let clock = ManualScheduler()
        let state: StateStore
        let settings: SettingsStore
        let session: NoteSession
        var panelKey = false

        init() {
            let folder = agent.root.appendingPathComponent("state")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state = StateStore(store: JSONFileStore<AppState>(url: folder.appendingPathComponent("state.json")), scheduler: clock)
            var initial = Settings()
            initial.vaultPath = agent.vaultURL.path
            let file = JSONFileStore<Settings>(url: folder.appendingPathComponent("settings.json"))
            try! file.save(initial)
            settings = SettingsStore(store: file, profile: .release, bundleURL: folder, homeDirectory: folder)
            let panelID = UUID()
            state.update { $0.panels = [PanelState(id: panelID)] }
            session = NoteSession(panelID: panelID, vault: agent.vault, state: state, settings: settings, scheduler: clock, output: output)
            agent.handler.session = session
            agent.handler.panelHasKeyboard = { [unowned self] in self.panelKey }
        }

        /// Lets queued vault work and its main-thread answers run.
        func settle(_ seconds: TimeInterval = 0.15) {
            _ = runAsync { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        }

        func open(_ name: String, _ text: String) {
            agent.seed(name, text)
            session.open(name)
            settle()
            output.clear()
        }

        /// Turns the run loop until the write in flight is prepared, then a little longer: the gate is
        /// taken in the main-actor turn that follows, and the replace is on the vault queue after it.
        func settleUntilPrepared() {
            let journal = agent.journal
            runAsync {
                while journal.all().first?.state != .prepared { try? await Task.sleep(nanoseconds: 5_000_000) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        /// Starts a modify and returns without waiting for it; `outcome` is filled in when it ends.
        func startModify(_ name: String, version: String, _ change: NoteChange) -> () -> Result<JSONValue, AgentFailure>? {
            let handler = agent.handler!
            let caller = agent.caller!
            let params: JSONValue = .object([
                "note_ref": .string(agent.refOf(name)), "expected_version": .string(version),
                "changes": try! JSONValue.from([change]), "request_id": .string(uuid()),
            ])
            var outcome: Result<JSONValue, AgentFailure>?
            Task { @MainActor in outcome = await handler.handle(method: "modify_note", params: params, caller: caller) }
            return { outcome }
        }

        func typeAndSave(_ text: String) {
            session.edited(text: text, caret: text.utf16.count)
            clock.advance(by: WritePolicy.debounce + 0.01)
            settle()
        }
    }

    Check.mainSuite("Agent · the note open in the panel") {

        Check.mainTest("panel has the keyboard: NOTE_BUSY (editing), nothing changes") {
            let rig = Rig()
            rig.open("2026-01-01-1200-open.md", "# Open\n\nbody\n")
            let read = rig.agent.read("2026-01-01-1200-open.md")!
            rig.panelKey = true
            let result = rig.agent.modify("2026-01-01-1200-open.md", version: read.version, [.append("x\n")])
            if case .failure(let failure) = result {
                Check.equal(failure.code, .noteBusy)
                Check.equal(failure.details?["reason"], "editing")
                Check.expect(failure.retryable)
            } else { Check.expect(false, "expected NOTE_BUSY") }
            Check.equal(rig.agent.disk("2026-01-01-1200-open.md"), "# Open\n\nbody\n")
            Check.equal(rig.output.loads.count, 0)
        }

        Check.mainTest("typed but not yet saved: NOTE_BUSY; once saved, the old version conflicts; typing survives") {
            let rig = Rig()
            let name = "2026-01-01-1200-typing.md"
            rig.open(name, "# Typing\n")
            let read = rig.agent.read(name)!
            rig.session.edited(text: "# Typing\n\nnew words\n", caret: 5)
            let readAgain = rig.agent.read(name)!
            Check.equal(readAgain.hasUnsavedChanges, true)
            Check.equal(readAgain.markdown, "# Typing\n", "a read returns what is saved, never the buffer")
            if case .failure(let failure) = rig.agent.modify(name, version: read.version, [.append("agent\n")]) {
                Check.equal(failure.code, .noteBusy)
                Check.equal(failure.details?["reason"], "unsaved_changes")
            } else { Check.expect(false) }

            rig.clock.advance(by: WritePolicy.debounce + 0.01)
            rig.settle()
            Check.equal(rig.agent.disk(name), "# Typing\n\nnew words\n")
            Check.equal(rig.agent.modify(name, version: read.version, [.append("agent\n")]).failureCode, .versionConflict)
            Check.equal(rig.agent.disk(name), "# Typing\n\nnew words\n")
        }

        Check.mainTest("search does not see the unsaved buffer") {
            let rig = Rig()
            let name = "2026-01-01-1200-s.md"
            rig.open(name, "# S\n\nsaved words\n")
            rig.session.edited(text: "# S\n\nsaved words zebra\n", caret: 3)
            rig.settle()
            let hits = rig.agent.ok(.searchNotes, ["query": .string("zebra")], as: SearchNotesResult.self)!
            Check.equal(hits.total, 0)
        }

        Check.mainTest("panel up but not focused: reloaded in place, toast, caret clamped, no second reload from the echo") {
            let rig = Rig()
            let name = "2026-01-01-1200-shown.md"
            rig.open(name, "# Shown\n\na long body that will be shortened\n")
            rig.state.update { $0.recordCaret(name, offset: 40) }
            rig.output.isPanelVisible = true
            let read = rig.agent.read(name)!
            let result = rig.agent.modify(name, version: read.version, [.replace("a long body that will be shortened\n", with: "short\n")]).value(WriteResult.self)
            Check.equal(result?.changed, true)
            Check.equal(rig.output.loads.count, 1)
            Check.equal(rig.output.loads.last?.text, "# Shown\n\nshort\n")
            Check.equal(rig.output.loads.last?.caret, "# Shown\n\nshort\n".utf16.count, "caret clamped to the new length")
            Check.equal(rig.output.toasts, [L10n.t("toast.agentUpdated")])
            Check.equal(rig.session.buffer, "# Shown\n\nshort\n")

            // FSEvents arrives afterwards: disk equals the new baseline, so nothing more happens.
            rig.session.vaultChanged(filenames: [name])
            rig.settle()
            Check.equal(rig.output.loads.count, 1)
            // And the session does not write anything back.
            rig.clock.advance(by: 1)
            rig.settle()
            Check.equal(rig.agent.disk(name), "# Shown\n\nshort\n")
            Check.equal(rig.agent.noteFiles, [name], "no conflict copy")
        }

        Check.mainTest("panel dismissed: buffer follows the disk and the news waits for the next summon") {
            let rig = Rig()
            let name = "2026-01-01-1200-parked.md"
            rig.open(name, "# Parked Title\n")
            rig.output.isPanelVisible = false
            let read = rig.agent.read(name)!
            _ = rig.agent.modify(name, version: read.version, [.append("- from the agent\n")])
            Check.equal(rig.session.buffer, "# Parked Title\n- from the agent\n")
            Check.equal(rig.output.newsItems, [L10n.t("news.agentUpdatedTitled", ["title": "Parked Title"])])
            Check.equal(rig.output.toasts, [])
            Check.equal(rig.agent.journal.all().first?.state, .saved, "restorable from recent writes")
        }

        Check.mainTest("typing that starts during the write: no reload, typing goes to a conflict copy, the agent's change is saved") {
            let rig = Rig()
            let name = "2026-01-01-1200-race.md"
            rig.open(name, "# Race\n")
            let read = rig.agent.read(name)!
            rig.agent.vault.writeDelayForTesting = 0.3
            let handler = rig.agent.handler!
            let caller = rig.agent.caller!
            var outcome: Result<JSONValue, AgentFailure>?
            Task { @MainActor in
                outcome = await handler.handle(method: "modify_note", params: .object([
                    "note_ref": .string(rig.agent.refOf(name)), "expected_version": .string(read.version),
                    "changes": try! JSONValue.from([NoteChange.append("agent line\n")]), "request_id": .string(uuid()),
                ]), caller: caller)
            }
            rig.settleUntilPrepared()
            rig.session.edited(text: "# Race\nuser typing\n", caret: 10)   // the person clicks in and types
            rig.settle(0.5)
            rig.agent.vault.writeDelayForTesting = 0
            let write = outcome?.value(WriteResult.self)
            Check.equal(write?.state, .saved)
            Check.expect(write?.warnings.contains { $0.code == "user_edited_during_write" } == true)
            Check.equal(rig.output.loads.count, 0, "the buffer under the person's hands is not replaced")
            Check.equal(rig.agent.disk(name), "# Race\nagent line\n")

            rig.clock.advance(by: WritePolicy.debounce + 0.01)
            rig.settle()
            let sibling = rig.agent.noteFiles.first { $0.contains("-conflict-") }
            Check.expect(sibling != nil, "the typing went to a conflict copy: \(rig.agent.noteFiles)")
            if let sibling { Check.equal(rig.agent.disk(sibling), "# Race\nuser typing\n") }
            Check.equal(rig.agent.disk(name), "# Race\nagent line\n")
        }

        Check.mainTest("switching notes during the write: the write finishes, the new note is not reloaded") {
            let rig = Rig()
            rig.open("2026-01-01-1200-a.md", "# A\n")
            rig.agent.seed("2026-01-01-1201-b.md", "# B\n")
            let read = rig.agent.read("2026-01-01-1200-a.md")!
            rig.agent.vault.writeDelayForTesting = 0.3
            let handler = rig.agent.handler!
            let caller = rig.agent.caller!
            var outcome: Result<JSONValue, AgentFailure>?
            Task { @MainActor in
                outcome = await handler.handle(method: "modify_note", params: .object([
                    "note_ref": .string(rig.agent.refOf("2026-01-01-1200-a.md")), "expected_version": .string(read.version),
                    "changes": try! JSONValue.from([NoteChange.append("x\n")]), "request_id": .string(uuid()),
                ]), caller: caller)
            }
            rig.settleUntilPrepared()
            rig.session.open("2026-01-01-1201-b.md")
            rig.settle(0.6)
            rig.agent.vault.writeDelayForTesting = 0
            Check.equal(outcome?.value(WriteResult.self)?.state, .saved)
            Check.equal(rig.session.currentFilename, "2026-01-01-1201-b.md")
            // The open of B queues behind the write on the vault's serial queue, so A may be reloaded
            // first (it was still the open note); what must never happen is A landing after B.
            Check.equal(rig.output.loads.last?.filename, "2026-01-01-1201-b.md")
            let lastA = rig.output.loads.lastIndex { $0.filename == "2026-01-01-1200-a.md" } ?? -1
            let firstB = rig.output.loads.firstIndex { $0.filename == "2026-01-01-1201-b.md" } ?? -1
            Check.expect(lastA < firstB, "A was reloaded over B")
            Check.equal(rig.agent.disk("2026-01-01-1200-a.md"), "# A\nx\n")
        }

        // The gate defers a save rather than refusing it, so it must not be held while anything but
        // the replace itself is pending. It used to be taken before the journal writes, which go to a
        // queue of their own: the person typed into A and switched to B meanwhile, the switch's save
        // of A waited behind the gate as a flag, B's load did not, and B replaced the buffer holding
        // the words. The flag then saved B, unchanged. The write reported success with no warning, and
        // the words were in no note and no conflict copy.
        Check.mainTest("typing, then switching notes, while the write is being recorded: the typing is saved, the write conflicts") {
            let rig = Rig()
            let a = "2026-01-01-1200-a.md"
            rig.open(a, "# A\n")
            rig.agent.seed("2026-01-01-1201-b.md", "# B\n")
            let read = rig.agent.read(a)!
            // 0.3 s per journal write: accepted at 0.3, the two snapshots by 0.9, prepared at 1.2.
            rig.agent.handler.journalDelayForTesting = 0.3
            let outcome = rig.startModify(a, version: read.version, .append("agent line\n"))
            rig.settle(0.6)
            rig.session.edited(text: "# A\nuser typing\n", caret: 10)
            rig.session.open("2026-01-01-1201-b.md")
            rig.settle(1.8)
            rig.agent.handler.journalDelayForTesting = 0
            Check.equal(rig.session.currentFilename, "2026-01-01-1201-b.md")
            Check.equal(rig.agent.disk(a), "# A\nuser typing\n", "the switch saved the typing")
            Check.equal(outcome()?.failureCode, .versionConflict, "the write, prepared against the old text, is refused")
            Check.equal(rig.agent.noteFiles.filter { $0.contains("-conflict-") }, [])
        }

        // ⌘N empties the buffer at once, with no load to queue behind the write — so even a gate held
        // only for the replace itself (as long as Git sync's merge, up to five seconds) can be
        // overtaken. The save the gate deferred is kept with its own note and written when the gate
        // opens.
        Check.mainTest("typing, then ⌘N, while the write is on its way to disk: the typing goes to a conflict copy") {
            let rig = Rig()
            let a = "2026-01-01-1200-a.md"
            rig.open(a, "# A\n")
            let read = rig.agent.read(a)!
            rig.agent.vault.writeDelayForTesting = 0.3
            let outcome = rig.startModify(a, version: read.version, .append("agent line\n"))
            rig.settleUntilPrepared()
            rig.session.edited(text: "# A\nuser typing\n", caret: 10)
            rig.session.create(title: "")
            rig.settle(1.0)
            rig.agent.vault.writeDelayForTesting = 0
            let write = outcome()?.value(WriteResult.self)
            Check.equal(write?.state, .saved)
            Check.expect(write?.warnings.contains { $0.code == "user_edited_during_write" } == true, "\(write?.warnings ?? [])")
            Check.equal(rig.agent.disk(a), "# A\nagent line\n")
            let sibling = rig.agent.noteFiles.first { $0.contains("-conflict-") }
            Check.expect(sibling != nil, "the typing went to a conflict copy: \(rig.agent.noteFiles)")
            if let sibling { Check.equal(rig.agent.disk(sibling), "# A\nuser typing\n") }
            Check.equal(rig.session.agentCurrentFilename, nil, "the panel is on the new draft")
        }

        Check.mainTest("typing, then ⌘N, while a write that fails is in flight: the typing is saved in place") {
            let rig = Rig()
            let a = "2026-01-01-1200-a.md"
            rig.open(a, "# A\n")
            let read = rig.agent.read(a)!
            rig.agent.vault.writeDelayForTesting = 0.3
            let outcome = rig.startModify(a, version: read.version, .append("agent line\n"))
            rig.settleUntilPrepared()
            // Changed behind everyone's back: the replace will find a different hash and refuse.
            rig.agent.seed(a, "# A\nfrom elsewhere\n")
            rig.session.edited(text: "# A\nuser typing\n", caret: 10)
            rig.session.create(title: "")
            rig.settle(1.0)
            rig.agent.vault.writeDelayForTesting = 0
            Check.equal(outcome()?.failureCode, .versionConflict)
            let withTyping = rig.agent.noteFiles.filter { rig.agent.disk($0) == "# A\nuser typing\n" }
            Check.equal(withTyping.count, 1, "the typing is on disk exactly once: \(rig.agent.noteFiles)")
        }

        Check.mainTest("a note whose name still follows its title is settled before its ref is handed out") {
            let rig = Rig()
            rig.session.create(title: "Draft title")
            rig.settle()
            let name = rig.session.currentFilename!
            _ = rig.agent.ok(.listNotes, [:], as: ListNotesResult.self)
            rig.typeAndSave("Completely different heading\n")
            Check.equal(rig.session.currentFilename, name, "no rename after the API saw the name")
            Check.equal(rig.agent.noteFiles, [name])
        }

        Check.mainTest("drafts are invisible to the API") {
            let rig = Rig()
            rig.session.create(title: "")
            rig.session.edited(text: "unsaved draft", caret: 3)
            Check.equal(rig.session.agentCurrentFilename, nil)
            Check.equal(rig.agent.ok(.listNotes, [:], as: ListNotesResult.self)?.total, 0)
        }
    }
}
