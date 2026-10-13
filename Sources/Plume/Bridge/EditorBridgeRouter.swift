import AppKit
import PlumeKit

/// Decides who answers each message the page sends.
///
/// There are thirty-one messages and four kinds of owner, and this is the only place that knows which
/// is which — a message is one line here, and the work is in the owner. The split is by what the
/// message is *about*:
///
///   - the note on screen          → `NoteSession`
///   - the window                  → `PanelController`
///   - what the user has chosen    → `PanelController`'s settings handlers (they write `SettingsStore`
///                                    and act at once; the store pushes the change back down)
///   - the vault's lists           → `PanelController`, which asks `VaultServicing`
///   - the rest of the system      → `PanelController`'s small system actions
///
/// Adding a message is a case in `BridgeMessage`, a line here, and the compiler checks the `switch`
/// is exhaustive; `BridgeContractTests` checks the names against the page.
@MainActor
struct EditorBridgeRouter {

    let session: NoteSession
    let panel: PanelController

    func route(_ message: BridgeMessage) {
        switch message {

        // The page is up.
        case .ready: panel.panelReady()

        // The note on screen.
        case .edited(let text, let caret): session.edited(text: text, caret: caret)
        case .caret(let caret, let scrollLine): session.caretMoved(caret, scrollLine: scrollLine)
        case .openNote(let filename): session.open(filename)
        case .createNote(let title): session.create(title: title)
        case .togglePin(let filename): session.togglePin(filename)
        case .deleteNote(let filename): session.delete(filename)
        case .duplicateNote(let text): session.duplicate(text: text)
        case .renameFile: panel.renameFileByHand()
        case .navigate(let back): back ? session.goBack() : session.goForward()

        // The window: its size, its place, its overlays.
        case .close: panel.closeRequested()
        case .contentHeight(let height): panel.contentHeightReported(height)
        case .switcherOpen(let open, let height): panel.switcherToggled(open: open, height: height)
        case .actionsOpen(let open, let height): panel.actionsToggled(open: open, height: height)
        case .dragRegions(let titleBar, let exclusions, let close):
            panel.dragRegionsReported(titleBar: titleBar, exclusions: exclusions, close: close)
        case .toggleAutoSizing: panel.toggleAutoSizing()
        case .toggleKeepOnTop: panel.toggleKeepOnTop()
        case .toggleHideFromCapture: panel.toggleHideFromCapture()
        case .setSpaceAssignment(let mode): panel.chooseSpaceAssignment(mode)
        case .headingMenu(let button, let level): panel.headingMenuRequested(below: button, current: level)

        // What the user has chosen.
        case .textSize(let action): panel.changeTextSize(action)
        case .toggleFooterCount: panel.toggleFooterCount()

        // The vault's lists: the switcher, and Recently Deleted.
        case .requestNotes(let query): panel.requestNotes(query)
        case .requestDeleted: panel.sendDeletedRows()
        case .restoreDeleted(let storedName): panel.restoreDeleted(storedName)
        case .forgetDeleted(let storedName): panel.forgetDeleted(storedName)

        // The rest of the system.
        case .openLink(let target): panel.openLink(target)
        case .revealInFinder: panel.revealCurrentNoteInFinder()
        case .copyAsMarkdown(let text): panel.copyAsMarkdown(text)
        case .exportNote(let text): panel.exportNote(text: text)
        case .openSettings: panel.openSettings()
        }
    }
}
