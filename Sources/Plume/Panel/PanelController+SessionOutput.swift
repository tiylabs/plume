import AppKit
import Foundation
import PlumeKit

// MARK: - Session output

extension PanelController: NoteSessionOutput {

    var isPanelVisible: Bool { isVisible }

    func load(_ note: LoadedNote) {
        editor.send(.loadNote(filename: note.filename, text: note.text, caret: note.caret, pinned: note.pinned))
    }

    func currentNoteRenamed(to filename: String) { editor.send(.setNoteFilename(filename)) }
    func pinnedChanged(_ pinned: Bool) { editor.send(.setPinned(pinned)) }

    func show(_ banner: Banner?) {
        if let banner {
            editor.send(.showBanner(kind: banner.kind, text: banner.text))
        } else {
            editor.send(.hideBanner)
        }
    }

    func toast(_ text: String) { editor.send(.showToast(text)) }
    func news(_ text: String) { showNews(text) }
    func focusEditor() { editor.focusEditor() }
    func pinsChanged() { onPinsChanged?() }
    func switcherNeedsRefresh() { refreshSwitcherIfOpen() }
    func vaultIsGone() { onVaultMissing?() }
}
