import AppKit
import Foundation
import PlumeKit

/// One panel: a window, a web view, and the note currently in it.
///
/// Deliberately not a singleton and deliberately not "the editor" — decision 14 says a note is an
/// independently ownable panel, and the way that survives contact with a v0.1 that shows one panel is
/// for this type to hold no static state and know nothing about how many of it exist. Everything it
/// needs — the vault, the shared state file — is handed in.
@MainActor
final class PanelController: NSObject {

    let panel = PanelWindow()
    let editor = EditorWebView(frame: .zero)

    let vault: any VaultServicing
    let state: StateStore
    let settings: SettingsStore
    var session: NoteSession!
    private lazy var router = EditorBridgeRouter(session: session, panel: self)

    /// Called when pins change, so the menu bar's pinned section can be rebuilt.
    var onPinsChanged: (() -> Void)?
    /// Called when the vault turns out to be gone (decision 13).
    var onVaultMissing: (() -> Void)?
    /// Called by ⌘K's Settings… row. The window belongs to the app, not to a panel — decision 16 —
    /// so the panel asks rather than owning one.
    var onOpenSettings: (() -> Void)?
    /// Called every time the panel is summoned. The release check hangs off this rather than off
    /// launch (decision 136): a summon is a keypress, so there is somebody at the keyboard.
    var onSummoned: (() -> Void)?

    private var panelID: UUID

    // MARK: Layout

    var lastContentHeight: CGFloat = PanelWindow.defaultHeight
    let autoSizeBadge = AutoSizeBadge()
    let spaceNotice = SpaceNotice()
    let dockSpaceAssignmentMonitor = DockSpaceAssignmentMonitor()
    /// The last persisted Dock observation; separate from the user's Plume preference.
    var detectedDockSpaceAssignment: DockSpaceAssignment { dockSpaceAssignmentMonitor.assignment }
    var appliedSpacePolicy: SpaceAssignmentPolicy?

    var effectiveSpacePolicy: SpaceAssignmentPolicy {
        SpaceAssignmentPolicy.resolve(
            settings: settings.value, dock: detectedDockSpaceAssignment, previous: appliedSpacePolicy
        )
    }
    /// A summon from another desktop of a panel kept to one it has not been filed on yet — parked at
    /// launch somewhere else. It comes up when you arrive; see `activeSpaceDidChange`.
    var summonOnArrival = false
    var mouseMonitors: [Any] = []
    var isHovered = false
    var isCloseHovered = false
    var switcherIsOpen = false
    var actionsIsOpen = false
    var actionsPanelHeight: CGFloat = 0

    /// Panel height while the switcher is open, measured by the panel rather than assumed here.
    ///
    /// This was a constant — `panelHeight(forOverlay: 54 + 430 + 34)` — and it was wrong twice over.
    /// It fed in the 54px top offset that `panelHeight(forOverlay:)` adds for itself, and it assumed
    /// a full 430px list whatever the vault held: ⌘P grew the panel to 691pt on a six-note vault and
    /// left a 370pt panel floating in the middle of it. ⌘K has reported its own height since
    /// decision 45; this is the switcher finally doing the same, which is also the last thing the
    /// two overlays did differently.
    var switcherPanelHeight: CGFloat = 0

    init(vault: any VaultServicing, state: StateStore, settings: SettingsStore) {
        self.vault = vault
        self.state = state
        self.settings = settings

        // Reuse the panel the last session left behind, so its remembered frames come back with it.
        if let existing = state.value.panels.first {
            panelID = existing.id
        } else {
            // **A panel that has never existed starts square, with auto-sizing off** — decision 129.
            //
            // The welcome note is 924pt at this width and the panel shows about 370, so the first
            // thing a new user meets is a note that plainly continues past the fold, ending on a tip
            // that ⇧⌘/ makes the panel follow its content. Auto-sizing on would have grown the panel to
            // the note and there would have been nothing to demonstrate; off, the feature teaches
            // itself by being switched on.
            //
            // **The guard is this branch, and it is the whole guard**: it runs only when `state.json`
            // holds no panel at all. An upgrade keeps its panels, so an existing user's auto-sizing is
            // never silently turned off by installing a new version — which would be a setting
            // changing under someone who had chosen it.
            //
            // `manualHeight` has to be set alongside the flag: `heightWanted` falls back to the
            // content height when it is nil, so `autoSizing = false` on its own is auto-sizing with
            // extra steps.
            let fresh = PanelState(
                autoSizing: false,
                manualHeight: Double(PanelWindow.defaultHeight)
            )
            panelID = fresh.id
            state.update { $0.panels = [fresh] }
        }

        super.init()

        session = NoteSession(
            panelID: panelID, vault: vault, state: state, settings: settings,
            scheduler: MainQueueScheduler(), output: self
        )

        panel.delegate = self
        panel.contentView = editor
        editor.frame = panel.contentLayoutRect
        editor.autoresizingMask = [.width, .height]
        editor.delegate = self
        editor.load()

        // Offscreen from the start: the web view has to be laid out and warm before the first
        // summon, and the first summon must not be the first time anything renders.
        //
        // Through the panel rather than by setting the origin here, because "offscreen" is a state
        // the panel defends and not just a coordinate — see `PanelWindow.parkBeforeFirstSummon`.
        panel.parkBeforeFirstSummon()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        dockSpaceAssignmentMonitor.onChange = { [weak self] _ in
            self?.applySpacePolicy()
            self?.sendSpaceAssignment()
        }
        dockSpaceAssignmentMonitor.start()
    }

    // MARK: - Plume state

    var panelState: PanelState {
        get { state.panelState(id: panelID) }
        set { state.updatePanel(id: panelID) { $0 = newValue } }
    }

    var isPinned: Bool { session.isPinned }

    // MARK: - Summon and dismiss

    var isVisible: Bool { panel.isSummoned }

    /// Up on the Space being looked at. A panel kept to its Space (93) can be up on another one, and a
    /// route that acts on the panel has to bring it here first (180) or it acts where nobody can see.
    private var isHere: Bool { isVisible && panel.isOnActiveSpace }

    /// Puts a message over the note for a moment. `dwell` is for a toast that is not a receipt —
    /// see the editor's `showToast` and decision 136.
    func showToast(_ text: String, dwell: Int? = nil) {
        editor.send(.showToast(text, dwell: dwell))
    }

    /// How long a toast that is news stays up, against a receipt's 1900 ms (decision 136).
    static let newsDwell = 5000

    /// A toast that is news about something that happened while nobody was looking (decision 176).
    /// Into a parked panel it would fade unseen, so it waits for the next summon instead.
    private var pendingNews: String?

    func showNews(_ text: String) {
        if isVisible {
            showToast(text, dwell: Self.newsDwell)
        } else {
            pendingNews = text
        }
    }

    /// When the last toggle ran, so one press cannot be delivered twice — see the note on the menu
    /// bar's summon item. Carbon and AppKit can both hand us the same combination while the Settings
    /// window is frontmost, and two toggles in a row is a summon that immediately dismisses itself.
    private var lastToggle = Date.distantPast

    /// The hotkey. Decision 180: it reads the focus as well as whether the panel is up, and the pin
    /// plays no part.
    func toggle() {
        guard Date().timeIntervalSince(lastToggle) > 0.25 else { return }
        lastToggle = Date()

        applySpacePolicy()
        let elsewhere = assignedDesktopElsewhere()
        switch HotkeyPress.resolve(
            isUp: isVisible,
            onActiveSpace: panel.isOnActiveSpace,
            hasFocus: panel.isKeyWindow,
            dismissMode: settings.value.dismissMode,
            keptElsewhere: elsewhere != nil
        ) {
        case .summon:
            summon()
        case .bringHere:
            dismiss()
            summon()
        case .focus:
            refocus()
        case .dismiss:
            dismiss()
        case .elsewhere:
            if let elsewhere { summonElsewhere(on: elsewhere) }
        }
    }

    /// The caret back in a panel that is already up, without starting a new sitting: undo history and
    /// the unsettled name (103) carry on, which a dismiss and a summon would both reset.
    private func refocus() {
        // Above another app's floating window at the same level, which ordering alone does not do
        // for a non-activating panel.
        panel.bringToFront()
        editor.focusEditor()
    }

    func summon() {
        dockSpaceAssignmentMonitor.refresh()
        applySpacePolicy()
        // Kept to one desktop and summoned from another: it stays where it is, and says so. Every
        // route in comes through here — the menu bar, the Dock icon, a note opened from a menu.
        if let desktop = assignedDesktopElsewhere() {
            summonElsewhere(on: desktop)
            return
        }

        // The active display is the one the pointer is on — Spotlight's convention, and the only
        // definition that matches where the user is looking.
        //
        // `NSScreen.main` is the fallback rather than the first choice on purpose: it means "the
        // screen with the key window", and Plume's whole trick is not owning the key window, so it
        // reports whichever display the *other* app is on. That is right often enough to hide the
        // bug and wrong exactly when the user has moved.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let frame = PanelGeometry.restore(
            remembered: panelState.frames[Self.displayKey(screen)]?.rect,
            lastSize: panelState.lastSize?.size,
            titleBarHeight: PanelWindow.titleBarHeight,
            activeVisibleFrame: screen.visibleFrame,
            defaultWidth: PanelWindow.defaultWidth,
            defaultHeight: max(PanelGeometry.minimumHeight, lastContentHeight)
        )

        panel.summon(at: frame)
        // Decision 41: the chrome follows the cursor, and summoning moves the panel rather than the
        // cursor — so a panel that opens under a stationary pointer gets no `mouseenter` and would
        // sit dimmed until the mouse moved. Only Swift knows the new frame and the pointer at once.
        isHovered = isPointerOnPanel(NSEvent.mouseLocation)
        editor.send(.setHover(isHovered))
        refreshCloseHover()
        // The height the note wanted may have moved while the panel was away — an external edit, or a
        // note switched from the menu bar. Reconciling here rather than waiting for the web layer's
        // next report keeps the first frame the user sees the right size.
        applyContentHeight(heightWanted)

        editor.setFocused(true)
        // A summon is a new sitting with the note, and undo belongs to the sitting — see
        // `resetHistory`. Without it ⌘Z reaches back across the dismissal and can empty a note that
        // was written in one burst.
        editor.send(.resetHistory)
        editor.focusEditor()

        // Re-assert key status once the current event has finished.
        //
        // Summoning from the menu bar item ran inside `NSMenu`'s own tracking loop, and a menu
        // restores key status to whatever held it before when it closes — undoing the
        // `makeKeyAndOrderFront` above. The panel appeared, correctly, and then quietly did not take
        // a single keystroke, which looked like the hotkey working and the menu item being broken.
        // Idempotent on the hotkey path, which never had the problem.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isSummoned else { return }
            self.panel.bringToFront()
            self.editor.focusEditor()
        }

        onSummoned?()

        if let news = pendingNews {
            pendingNews = nil
            showToast(news, dwell: Self.newsDwell)
        }

        session.openLastUsedIfNothingOpen()

        startTrackingResizeEdge()
    }

    func stopDockSpaceDetection() {
        dockSpaceAssignmentMonitor.stop()
    }

    func dismiss() {
        flush(trigger: .dismissed)
        // Decision 103's freeze list, first entry. The write above still lands; only the *name*
        // stops following, so a note comes back on the next summon under the name you left it with.
        session.left()
        rememberFrame()
        panel.dismiss()
        editor.setFocused(false)
        stopTrackingResizeEdge()

        // Hands the front back to whatever was there. Summoning never activated the app — measured:
        // `frontmostApplication` stays with the other app throughout — so in the common case this is
        // a no-op, and in the case where a click into the panel *did* activate us, it is the fix.
        if NSApp.isActive { NSApp.deactivate() }
    }

    // MARK: - Rename by hand

    /// ⌘K's "Rename File…" — the escape hatch for a title improved an hour later.
    ///
    /// The dialog is AppKit and stays here; what happens to the name after is `NoteSession.rename`.
    /// Only the slug is editable. The timestamp is the creation time and the real content of the
    /// naming scheme, so it is shown and not offered; a rename that could rewrite it would be a
    /// different feature.
    func renameFileByHand() {
        guard let filename = currentFilename else { return }

        let stem = (filename as NSString).deletingPathExtension
        let prefix = NoteSession.frozenPrefix(of: filename)
        let hasTimestamp = !prefix.isEmpty
        let editable = String(stem.dropFirst(prefix.count))

        // A dialog you have to type into has to be reachable, and Plume never activates on its own —
        // so this joins Settings and the vault chooser as a place where it does. `steppingAside` is
        // decision 91: the panel floats above everything, including this, until it is told not to.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = tr("rename.title")
        // The frozen half, shown so it is clear what is not on offer.
        alert.informativeText = hasTimestamp
            ? "\(prefix)…\u{2009}.\(NoteFilename.fileExtension)"
            : filename
        alert.addButton(withTitle: tr("rename.button"))
        alert.addButton(withTitle: tr("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = editable
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard PanelWindow.steppingAside({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        session.rename(toTyped: field.stringValue)
    }

    // MARK: - Switcher

    func refreshSwitcherIfOpen() {
        guard switcherIsOpen else { return }
        sendRows(query: lastQuery)
    }

    private var lastQuery = ""

    func sendRows(query: String) {
        lastQuery = query
        vault.rows(
            query: query,
            state: state.value,
            current: currentFilename,
            order: settings.value.noteOrder
        ) { [weak self] snapshot in
            guard let self else { return }
            self.editor.send(.showNotes(snapshot.rows, total: snapshot.total, query: snapshot.query))
        }
    }

    // MARK: - Notes
    //
    // The note on screen — what is in the buffer, when it is written, what its file is called — is
    // `NoteSession`, in PlumeKit. These are the panel's handles on it.

    var currentFilename: String? { session.currentFilename }
    func openLastUsedNote() { session.openLastUsed() }
    func open(_ filename: String) { session.open(filename) }
    func createNote(title: String) { session.create(title: title) }
    func flush(trigger: WritePolicy.Trigger) { session.flush(trigger: trigger) }
    func vaultChanged(filenames: [String]) { session.vaultChanged(filenames: filenames) }

    func openSwitcher() {
        if !isHere { summon() }
        editor.send(.openSwitcher)
    }

    func openActions() {
        if !isHere { summon() }
        editor.send(.openActions)
    }

    // MARK: - Settings

    func applySettings() {
        editor.panelOpacity = settings.value.panelOpacity
        // A borderless transparent window's shadow is cast by its rectangular backing, so over glass
        // it showed as a square black frame around the rounded panel. Glass has its own edge.
        panel.hasShadow = !editor.usesGlass
        applySpacePolicy()
        panel.keepsOnTop = settings.value.keepOnTop
        editor.holdsFocusedLook = settings.value.keepOnTop
        editor.send(.setKeepOnTop(settings.value.keepOnTop))
        applyHiddenFromCapture()
        // Not a setting — panel state — but this runs on `ready`, which is the one moment the web
        // layer needs telling. Its ⌘K label is otherwise wrong until the row is pressed once.
        editor.send(.setAutoSizing(panelState.autoSizing))
        sendSpaceAssignment()

        // The material picks its light or dark variant from the window's appearance, so the two have
        // to be told the same thing — otherwise a dark-mode panel gets a light blur behind dark text.
        panel.appearance = settings.value.appearance.nsAppearance

        let accent = Settings.accentColours(for: settings.value.accent)
        editor.send(.applySettings(PanelSettingsPayload(
            appearance: settings.value.appearance.rawValue,
            accent: accent.light,
            accentDark: accent.dark,
            textSize: settings.value.textSize,
            footerCount: settings.value.footerCount.rawValue,
            panelOpacity: settings.value.panelOpacity,
            glass: editor.usesGlass,
            shortcuts: settings.value.shortcuts,
            // Decision 19: a theme is a CSS file, so what crosses the bridge is the file's
            // contents. Read here rather than fetched by the web layer — the page is loaded from
            // a file URL with read access scoped to the bundle, and widening that scope to reach
            // Application Support would be a much bigger hole than passing a string.
            themeCSS: loadThemeCSS(),
            // The language in effect; the editor swaps its own catalog (compiled in from the
            // same `Locales/` files) and re-renders. See `Editor/src/i18n.ts`.
            language: L10n.currentLanguage
        )))

        // `settings.json` reloads live (decision 32), and the switcher is the one surface whose
        // *content* a setting changes. An open list would otherwise keep the old order until it was
        // closed and reopened, which reads as the setting not having taken.
        if switcherIsOpen { sendRows(query: lastQuery) }
    }

}

// MARK: - Web layer

extension PanelController: EditorWebViewDelegate {

    func editor(_ editor: EditorWebView, didReceive message: BridgeMessage) {
        router.route(message)
    }

    /// The format bar's heading list, as a real menu hanging below the button.
    ///
    /// Native for two reasons the web layer cannot solve. It has to render *past the panel's bottom
    /// edge* — the format bar is the last row, and anything drawn in the web view is clipped to the
    /// window, which is why the DOM version had to open upward over the note. And it has to go away
    /// on its own: an outside click, Escape, the app deactivating, the panel being dismissed. AppKit
    /// owns all of that; hand-rolling it in the page means remembering every one of those cases.
    func showHeadingMenu(below button: CGRect, current: Int?) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for level in 1...3 {
            let item = NSMenuItem(
                title: tr("heading.level", ["level": String(level)]),
                action: #selector(chooseHeading(_:)),
                keyEquivalent: "\(level)"
            )
            item.keyEquivalentModifierMask = [.option, .command]
            item.target = self
            item.tag = level
            // A tick on the level the caret is already in, so the menu reports state as well as
            // offering actions.
            item.state = current == level ? .on : .off
            menu.addItem(item)
        }

        // CSS pixels, top-left origin, into the view's bottom-left coordinates. The anchor is the
        // button's bottom-left corner, so the menu drops from directly under it — and AppKit flips it
        // upward by itself when the panel is close enough to the bottom of the screen that it would
        // not fit.
        let anchor = CGPoint(x: button.minX, y: editor.bounds.height - button.maxY)
        menu.popUp(positioning: nil, at: anchor, in: editor)
    }

    @objc private func chooseHeading(_ sender: NSMenuItem) {
        editor.send(.setHeadingLevel(sender.tag))
        editor.focusEditor()
    }
}
