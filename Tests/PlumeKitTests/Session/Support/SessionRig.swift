import Foundation
import PlumeKit

/// A `NoteSession` wired to a fake vault, a recording output, a manual clock, and real stores over a
/// temporary folder.
@MainActor
final class SessionRig {
    let vault = FakeVault()
    let output = RecordingOutput()
    let clock = ManualScheduler()
    let state: StateStore
    let settings: SettingsStore
    let panelID = UUID()
    let folder: URL
    let vaultFolder: URL
    private(set) var session: NoteSession!

    init(vaultExists: Bool = true) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        vaultFolder = folder.appendingPathComponent("vault")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if vaultExists { try? FileManager.default.createDirectory(at: vaultFolder, withIntermediateDirectories: true) }

        state = StateStore(store: JSONFileStore<AppState>(url: folder.appendingPathComponent("state.json")), scheduler: clock)
        var initial = Settings()
        initial.vaultPath = vaultFolder.path
        let file = JSONFileStore<Settings>(url: folder.appendingPathComponent("settings.json"))
        try? file.save(initial)
        settings = SettingsStore(store: file, profile: .release, bundleURL: folder, homeDirectory: folder)
        state.update { $0.panels = [PanelState(id: panelID)] }

        session = NoteSession(
            panelID: panelID, vault: vault, state: state, settings: settings, scheduler: clock, output: output
        )
    }

    // MARK: Setup

    /// A note already in the vault, as if from an earlier session. Not opened.
    @discardableResult
    func seed(_ filename: String, _ text: String, lastOpened: Date? = nil, pinned: Bool = false) -> String {
        vault.files[filename] = FakeVault.File(text: text)
        if lastOpened != nil || pinned {
            state.update {
                var note = $0.note(filename)
                note.lastOpened = lastOpened
                note.isPinned = pinned
                $0.notes[filename] = note
            }
        }
        return filename
    }

    /// Opens `filename` and answers the load and the conflict check it triggers, so the session is
    /// settled on it and nothing is left pending.
    func open(_ filename: String) {
        session.open(filename)
        vault.releaseAll()
        output.clear()
    }

    /// Types, as the editor would report it.
    func type(_ text: String, caret: Int? = nil) {
        session.edited(text: text, caret: caret ?? text.utf16.count)
    }

    /// Lets the 500 ms debounce run out.
    func pause() { clock.advance(by: WritePolicy.debounce + 0.01) }

    /// The state entry for a note.
    func noteState(_ filename: String) -> NoteState { state.value.note(filename) }
    var panelNote: String? { state.panelState(id: panelID).noteFilename }
}

func isWrite(_ op: FakeVault.Op) -> Bool { if case .write = op { true } else { false } }
func isCreate(_ op: FakeVault.Op) -> Bool { if case .create = op { true } else { false } }
func isDelete(_ op: FakeVault.Op) -> Bool { if case .delete = op { true } else { false } }
func isLoad(_ op: FakeVault.Op) -> Bool { if case .load = op { true } else { false } }
func isRename(_ op: FakeVault.Op) -> Bool {
    switch op { case .rename, .renameFollowingTitle: true; default: false }
}
