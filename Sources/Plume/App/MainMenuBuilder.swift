import AppKit
import PlumeKit

/// The application's main menu.
///
/// An accessory app never shows a menu bar, but `NSApp.mainMenu` is still what routes ⌘C, ⌘V and ⌘Z
/// to the first responder. This builds it, and keeps the two File items whose keys are rebindable
/// pointed at whatever they are bound to now.
///
/// It owns no behaviour: each item sends one of the four closures it was given, so the menu does not
/// need to know what a panel or a settings window is.
@MainActor
final class MainMenuBuilder: NSObject {

    private let settings: () -> Settings
    private let openSettings: () -> Void
    private let newNote: () -> Void
    private let browseNotes: () -> Void
    private let closePanel: () -> Void

    init(
        settings: @escaping () -> Settings,
        openSettings: @escaping () -> Void,
        newNote: @escaping () -> Void,
        browseNotes: @escaping () -> Void,
        closePanel: @escaping () -> Void
    ) {
        self.settings = settings
        self.openSettings = openSettings
        self.newNote = newNote
        self.browseNotes = browseNotes
        self.closePanel = closePanel
    }

    /// An accessory app never shows a menu bar, but `NSApp.mainMenu` is still what routes ⌘C, ⌘V and
    /// ⌘Z to the first responder. Without this the panel would be a text editor you cannot paste into.
    func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: tr("menu.settings"),
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: tr("menu.file"))
        newNoteItem = fileMenu.addItem(withTitle: tr("menu.newNote"), action: #selector(newNoteAction), keyEquivalent: "")
        newNoteItem?.target = self
        browseNotesItem = fileMenu.addItem(withTitle: tr("menu.browseNotes"), action: #selector(browseNotesAction), keyEquivalent: "")
        browseNotesItem?.target = self
        applyShortcuts()
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: tr("menu.closePanel"), action: #selector(closePanelAction), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("menu.edit"))
        editMenu.addItem(withTitle: tr("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: tr("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }


    /// The two File-menu items whose keys are rebindable. See `applyMenuShortcuts`.
    private var newNoteItem: NSMenuItem?
    private var browseNotesItem: NSMenuItem?

    /// Points the File menu at whatever New Note and Browse Notes are actually bound to.
    ///
    /// These were `keyEquivalent: "n"` and `"p"`, spelled here and nowhere near
    /// `Settings.shortcutActions` — so they were the two rebindable actions that could not be
    /// rebound. Recording a new key in the Shortcuts tab moved the editor's binding and left the
    /// menu holding ⌘N, which means the old key kept working and the recorder could not free it.
    /// Exactly the class of defect decisions 47 and 49 are about: a key printed in one place and
    /// meaning something else in another.
    func applyShortcuts() {
        let map: [(NSMenuItem?, String)] = [
            (newNoteItem, "newNote"),
            (browseNotesItem, "browseNotes"),
        ]
        for (item, action) in map {
            guard let item else { continue }
            guard let combo = Settings.menuKeyEquivalent(for: settings().shortcut(action)) else {
                // A binding this cannot express — the item keeps its title and loses its key rather
                // than advertising one it does not have.
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                continue
            }
            item.keyEquivalent = combo.key
            var mask: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.command) { mask.insert(.command) }
            if combo.modifiers.contains(.shift) { mask.insert(.shift) }
            if combo.modifiers.contains(.option) { mask.insert(.option) }
            if combo.modifiers.contains(.control) { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func newNoteAction() { newNote() }
    @objc private func browseNotesAction() { browseNotes() }
    @objc private func closePanelAction() { closePanel() }
}
