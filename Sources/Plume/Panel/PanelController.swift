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

    private let vault: any VaultServicing
    private let state: StateStore
    private let settings: SettingsStore
    private var session: NoteSession!
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

    private var lastContentHeight: CGFloat = PanelWindow.defaultHeight
    private let autoSizeBadge = AutoSizeBadge()
    private let spaceNotice = SpaceNotice()
    private let dockSpaceAssignmentMonitor = DockSpaceAssignmentMonitor()
    /// The last persisted Dock observation; separate from the user's Plume preference.
    var detectedDockSpaceAssignment: DockSpaceAssignment { dockSpaceAssignmentMonitor.assignment }
    private var appliedSpacePolicy: SpaceAssignmentPolicy?

    private var effectiveSpacePolicy: SpaceAssignmentPolicy {
        SpaceAssignmentPolicy.resolve(
            settings: settings.value, dock: detectedDockSpaceAssignment, previous: appliedSpacePolicy
        )
    }
    /// A summon from another desktop of a panel kept to one it has not been filed on yet — parked at
    /// launch somewhere else. It comes up when you arrive; see `activeSpaceDidChange`.
    private var summonOnArrival = false
    private var mouseMonitors: [Any] = []
    private var isHovered = false
    private var isCloseHovered = false
    private var switcherIsOpen = false
    private var actionsIsOpen = false
    private var actionsPanelHeight: CGFloat = 0

    /// Panel height while the switcher is open, measured by the panel rather than assumed here.
    ///
    /// This was a constant — `panelHeight(forOverlay: 54 + 430 + 34)` — and it was wrong twice over.
    /// It fed in the 54px top offset that `panelHeight(forOverlay:)` adds for itself, and it assumed
    /// a full 430px list whatever the vault held: ⌘P grew the panel to 691pt on a six-note vault and
    /// left a 370pt panel floating in the middle of it. ⌘K has reported its own height since
    /// decision 45; this is the switcher finally doing the same, which is also the last thing the
    /// two overlays did differently.
    private var switcherPanelHeight: CGFloat = 0

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

    private var panelState: PanelState {
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

    private func showNews(_ text: String) {
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

    // MARK: - Desktop assignment

    /// One policy drives both collectionBehavior and the hotkey's desktop restriction. Reordering
    /// a system-managed window after a policy change lets Dock apply its binding to this existing
    /// panel, whose offscreen parking otherwise keeps it permanently in the window list.
    private func applySpacePolicy() {
        let policy = effectiveSpacePolicy
        let previous = appliedSpacePolicy
        appliedSpacePolicy = policy
        panel.showsOnEverySpace = policy.showsOnEverySpace
        if policy != previous { summonOnArrival = false }
        if policy.isSystemManaged, policy != previous {
            panel.reapplySystemSpaceAssignment()
        }
    }

    /// The desktop `oneSpace` keeps to, when that is the setting and the desktop still exists.
    ///
    /// A desktop removed in Mission Control takes the setting back to None, saved, so the ⌘K row
    /// says so too. A lookup that merely failed does not: `Spaces.isGone` only answers yes when it
    /// could see every desktop and this was not among them.
    private func assignedDesktop() -> Spaces.Desktop? {
        let policy = effectiveSpacePolicy
        guard policy.mode == .oneSpace, let uuid = policy.desktopUUID else { return nil }
        if let desktop = Spaces.desktop(uuid: uuid) { return desktop }
        if !policy.isSystemManaged, Spaces.isGone(uuid) {
            settings.update {
                $0.spaceAssignment = .unassigned
                $0.assignedSpace = nil
            }
        }
        return nil
    }

    /// The desktop the panel keeps to, when it keeps to one and that is not the one being looked at.
    /// Nil whenever the answer cannot be had, which is `oneSpace` behaving as None rather than as a
    /// summon that does nothing.
    private func assignedDesktopElsewhere() -> Spaces.Desktop? {
        guard let desktop = assignedDesktop(), let active = Spaces.active(), active.uuid != desktop.uuid
        else { return nil }
        return desktop
    }

    /// A summon of a panel kept to another desktop: up there if it was parked there, and a notice
    /// here either way. Nothing moves and the focus stays with the app you summoned from.
    private func summonElsewhere(on desktop: Spaces.Desktop) {
        if !isVisible {
            if Spaces.of(windowNumber: panel.windowNumber) == desktop, let frame = panel.rememberedFrame {
                panel.present(at: frame)
                applyContentHeight(heightWanted)
                // Still a new sitting with the note — see `summon`.
                editor.send(.resetHistory)
                onSummoned?()
                session.openLastUsedIfNothingOpen()
                startTrackingResizeEdge()
            } else {
                summonOnArrival = true
            }
        }
        spaceNotice.show(tr("notice.elsewhere", ["number": String(desktop.number)]))
    }

    /// Arriving on the desktop a panel keeps to files a parked panel there if it is not yet, and puts
    /// it up if a summon from elsewhere was waiting for it. Every arrival also tells the ⌘K row which
    /// desktop "This Desktop" would mean now.
    @objc private func activeSpaceDidChange() {
        applySpacePolicy()
        defer { sendSpaceAssignment() }
        guard let desktop = assignedDesktop(), Spaces.active() == desktop else { return }
        panel.parkOnActiveSpace()
        if summonOnArrival {
            summonOnArrival = false
            summon()
        }
    }

    /// What the ⌘K row shows: the choice, and the desktop "This Desktop" names — the one it keeps
    /// to, or the one it would keep to if chosen now. Without SkyLight that row is not offered.
    private func sendSpaceAssignment() {
        let assignment = settings.value.spaceAssignment
        let desktop = assignment == .oneSpace
            ? settings.value.assignedSpace.flatMap { Spaces.desktop(uuid: $0) }
            : Spaces.active()
        editor.send(.setSpaceAssignment(
            mode: assignment.rawValue, desktop: desktop?.number, canKeepToOne: Spaces.isAvailable
        ))
        sendDockSpaceAssignment()
    }

    /// System assignments own the menu's displayed result and disable Plume's choices.
    private func sendDockSpaceAssignment() {
        let mode: String
        var desktop: Spaces.Desktop?
        switch detectedDockSpaceAssignment {
        case .unassigned:
            mode = "unassigned"
        case .everySpace:
            mode = "everySpace"
        case .oneSpace(let uuid):
            mode = "oneSpace"
            desktop = Spaces.desktop(uuid: uuid)
        case .unknown(let reason):
            mode = reason == .notReadYet ? "checking" : "unknown"
        }
        editor.send(.setDockSpaceAssignment(mode: mode, desktop: desktop?.number))
    }

    private func rememberFrame() {
        // **`panel.screen` only — never `NSScreen.main` as a fallback.** `main` is "the screen with
        // the key window", which during a display wake is whichever monitor came back first, so a
        // panel whose own screen was momentarily nil had its frame filed under a display it had never
        // been on. Measured after one power cycle of two monitors: all four keys in `state.json`
        // held the same rect, the portrait panel's, including the main display's. Writing nothing is
        // strictly better — the frame that is already stored is still true (decision 131).
        guard let screen = panel.screen, let frame = panel.rememberedFrame else { return }
        var next = panelState
        next.frames[Self.displayKey(screen)] = StoredFrame(frame)
        next.lastSize = StoredSize(frame.size)
        panelState = next
    }

    /// The per-display key, off the display's **persistent UUID**.
    ///
    /// This read used to be `NSScreenNumber` — the `CGDirectDisplayID` — with a comment asserting
    /// that it "survives sleep and resolution changes". Measured on a two-monitor Mac 2026-09-10, it
    /// does not: one power cycle moved the two displays from 53 and 54 to 59 and 58, and the same
    /// `state.json` held 56 orphaned frames for two physical monitors. `CGDisplayCreateUUIDFromDisplayID`
    /// came back byte-identical across that cycle, which is what makes it the thing to file under.
    ///
    /// The ID is still the fallback, because a display can refuse a UUID (a virtual or captured one);
    /// a panel that forgets its size is a nuisance, and a crash is not.
    private static func displayKey(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
        let identity: String
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            identity = string
        } else {
            identity = "id\(id)"
        }
        return PanelGeometry.displayKey(
            uuid: identity,
            width: screen.frame.width,
            height: screen.frame.height
        )
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

    private func refreshSwitcherIfOpen() {
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

    // MARK: - Geometry

    /// The height the panel should be right now.
    ///
    /// With auto-sizing on that is the note's height; with it off it is the height the user dragged
    /// to, and the note scrolls (decision 40). **An open overlay overrides both**, because the
    /// switcher and ⌘K are drawn inside this window and a panel clipped by its own panel is not a
    /// size anyone asked for. Closing the overlay returns to whichever answer the mode gives.
    private var heightWanted: CGFloat {
        // The held height is the *current display's*, not the panel's — see
        // `PanelState.heldHeight(onDisplay:)`. Safe to read `panel.screen` here: every caller runs
        // with the panel on screen, and `applyContentHeight` declines outright when it is not.
        let held: Double? = (panel.screen ?? NSScreen.main)
            .flatMap { panelState.heldHeight(onDisplay: Self.displayKey($0)) }
        var wanted = panelState.autoSizing
            ? lastContentHeight
            : CGFloat(held ?? Double(lastContentHeight))
        if switcherIsOpen { wanted = max(wanted, switcherPanelHeight) }
        if actionsIsOpen { wanted = max(wanted, actionsPanelHeight) }
        return wanted
    }

    private func applyContentHeight(_ desired: CGFloat) {
        // Only while on screen. Offscreen the panel's frame is 30,000 points below every display, so
        // `grown` would measure it against a screen it is nowhere near and clamp every note to the
        // 120 pt minimum. The height is reconciled on the next summon instead.
        guard panel.isSummoned else { return }

        // Never while the user is dragging the resize handle. Auto-sizing and a live drag are two
        // things setting the same frame: the drag resizes the window, the web layer's ResizeObserver
        // reports a new content height, this sets the frame back, the observer fires again. The panel
        // flickers between the two answers for as long as the mouse is down. The drag's own height
        // is taken in `windowDidEndLiveResize`, so nothing is lost by staying out of the way.
        guard !panel.inLiveResize else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let current = panel.rememberedFrame ?? panel.frame

        let growth = PanelGeometry.grown(
            from: current,
            toContentHeight: desired,
            visibleFrame: screen.visibleFrame
        )
        guard abs(growth.frame.height - current.height) >= 1 else { return }
        panel.applyHeight(growth.frame)
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

    // MARK: - Hide from Screen Capture

    /// Frame 2a's "Hide While Screen Sharing", decided by decision 36.
    ///
    /// The design's label implies detection: notice a screen-sharing session, hide until it ends.
    /// `NSWindow.sharingType = .none` is better than that and simpler — the window is excluded from
    /// capture at the window-server level, so there is no session to detect, no race between the
    /// share starting and the panel reacting, and no Screen Recording permission, which decision 9
    /// would otherwise have made this row impossible to build at all.
    private func applyHiddenFromCapture() {
        let hidden = settings.value.hideFromScreenCapture
        panel.sharingType = hidden ? .none : .readOnly
        editor.send(.setHiddenFromCapture(hidden))
    }

    private func setHiddenFromCapture(_ hidden: Bool) {
        settings.update { $0.hideFromScreenCapture = hidden }
        // `settings.update` comes back through `applySettings`, but not synchronously, and the ⌘K
        // row's label is read the moment the panel next opens.
        applyHiddenFromCapture()

        // The one setting in Plume whose effect is invisible *by definition* — it changes what other
        // processes can see, so pressing ⇧⌘H changed nothing at all on screen and the only way to
        // find out whether it had worked was to take a screenshot. Same toast as ⌃X's, decision 50.
        editor.send(.showToast(hidden ? tr("toast.hiddenFromCapture") : tr("toast.visibleInCapture")))
    }

    // MARK: - Export

    /// Frame 2a's Export…, and the one row whose meaning had to be decided rather than implemented
    /// (decision 37). The note is already a file the user owns, and Reveal in Finder already reaches
    /// it, so "export the markdown" would be a save panel wrapped around a copy they could make in
    /// the Finder. What they cannot get anywhere else is the *rendered* note.
    func exportNote(text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = MarkdownDocument.title(of: text).isEmpty
            ? "\(tr("export.defaultName")).html"
            : "\(MarkdownDocument.title(of: text)).html"
        panel.canCreateDirectories = true
        panel.title = tr("export.title")

        // The one place other than "choose vault" (decision 27) where Plume activates on purpose:
        // a save panel behind every other window is a hang as far as the user is concerned. And
        // activating is not enough on its own — the panel is `.floating`, so the panel came up behind
        // it with the Save button under its edge until `stepAside` (see `PanelWindow`).
        PanelWindow.stepAside()
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { [weak self] response in
            PanelWindow.resumeFloating()
            guard response == .OK, let url = panel.url, let self else { return }
            let html = MarkdownExport.html(
                from: text,
                title: MarkdownDocument.title(of: text),
                accent: self.settings.value.accent,
                language: L10n.currentLanguage
            )
            try? html.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// The selected theme's stylesheet, or empty for Plume's own.
    ///
    /// Failure is silent and falls back to the default: a theme is a file the user dropped in a
    /// folder, so a malformed or deleted one is an ordinary Tuesday, not an error worth a banner.
    private func loadThemeCSS() -> String {
        let name = settings.value.markdownTheme
        guard !name.isEmpty else { return "" }
        let url = settings.themesFolder.appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - Messages from the page

/// What the page asks of the window. Each is the body of a case that used to sit in the one big
/// `switch`; `EditorBridgeRouter` now picks the owner and these are the panel's.
extension PanelController {

    // All three heights go through `heightWanted` rather than working out a height themselves.
    // Doing the arithmetic in the message handler was how closing an overlay came to ignore the
    // mode: it handed back the *note's* height, so a panel the user had dragged small stayed at
    // panel height once the note was taller than the drag — and, worse, typing resized a panel whose
    // whole point was that it had stopped resizing.
    func contentHeightReported(_ height: CGFloat) {
        lastContentHeight = height
        applyContentHeight(heightWanted)
    }

    func switcherToggled(open: Bool, height: CGFloat) {
        switcherIsOpen = open
        // Zero on open, because the rows are a round trip away and there is nothing to measure
        // yet; the first render sends the real one. Holding the previous value until then keeps
        // a re-opened switcher from collapsing the panel for a frame.
        if !open {
            switcherPanelHeight = 0
        } else if height > 0 {
            switcherPanelHeight = PanelGeometry.panelHeight(forOverlay: height)
        }
        applyContentHeight(heightWanted)
    }

    func actionsToggled(open: Bool, height: CGFloat) {
        if open { dockSpaceAssignmentMonitor.refresh() }
        actionsIsOpen = open
        // Its height is measured rather than assumed, because filtering changes it. What the panel
        // grows to is not that plus two literals — see `panelHeight(forOverlay:)`, which grows to a
        // height the placement rule in overlay.ts is happy with.
        actionsPanelHeight = open ? PanelGeometry.panelHeight(forOverlay: height) : 0
        applyContentHeight(heightWanted)
    }

    func dragRegionsReported(titleBar: CGRect, exclusions: [CGRect], close: CGRect) {
        editor.setDragRegions(titleBar: titleBar, exclusions: exclusions, close: close)
        // The dot may have moved under a stationary pointer — the pin entering the bar, the panel
        // resizing. Same reason `summon` seeds hover rather than waiting for an event.
        refreshCloseHover()
    }

    func toggleHideFromCapture() {
        setHiddenFromCapture(!settings.value.hideFromScreenCapture)
    }

    func chooseSpaceAssignment(_ mode: String) {
        guard !effectiveSpacePolicy.isSystemManaged else {
            sendSpaceAssignment()
            return
        }
        guard let assignment = Settings.SpaceAssignment(rawValue: mode) else { return }
        // "This Desktop" is the one the panel is on, which is the one being looked at: ⌘K is open
        // in it. A panel on every Space has no one desktop, so it is the active one there.
        let desktop = assignment == .oneSpace
            ? Spaces.of(windowNumber: panel.windowNumber) ?? Spaces.active()
            : nil
        guard assignment != .oneSpace || desktop != nil else { return }
        settings.update {
            $0.spaceAssignment = assignment
            $0.assignedSpace = desktop?.uuid
        }
        // `settings.update` reaches `applySettings` asynchronously; the choice should act at once.
        applySpacePolicy()
        sendSpaceAssignment()
        // What this changes is invisible until you switch Space, so without a line the row reads as
        // having done nothing at all.
        let toast = switch assignment {
        case .unassigned: tr("toast.spaceAssignment.unassigned")
        case .oneSpace: tr("toast.spaceAssignment.oneSpace", ["number": String(desktop?.number ?? 0)])
        case .everySpace: tr("toast.spaceAssignment.everySpace")
        }
        editor.send(.showToast(toast))
    }

    func toggleKeepOnTop() {
        // Spelled out before the update, never read inside the closure: see `toggleFooterCount`.
        let now = !settings.value.keepOnTop
        settings.update { $0.keepOnTop = now }
        // `settings.update` reaches `applySettings` asynchronously; the click should act at once.
        panel.keepsOnTop = now
        editor.holdsFocusedLook = now
        editor.send(.setKeepOnTop(now))
    }

    func toggleFooterCount() {
        // Read out of the store *before* the update, never inside the closure: `settings.update`
        // holds a modifying access for the length of it, so `settings.value` in there is a
        // simultaneous read of the same storage and Swift traps the process on the spot. Every
        // other toggle here spells the value out first for this reason (`toggleKeepOnTop`); this one
        // did not, and the crash is invisible to every suite because it needs the message to
        // actually arrive from a running panel.
        let next = settings.value.footerCount.other
        // No toast and no label to correct: the number itself changes under the pointer, which is
        // the whole of the feedback decision 73 asks for.
        settings.update { $0.footerCount = next }
    }

    func changeTextSize(_ action: String) {
        // Clamped to the same bounds `Settings` enforces on a hand-edited file, so the keyboard and
        // the file cannot disagree about what is a legal size. Writing it through `settings.update`
        // is what persists it and pushes it back down via `applySettings`.
        settings.update {
            switch action {
            case "in": $0.textSize = min($0.textSize + 1, Settings.textSizeRange.upperBound)
            case "out": $0.textSize = max($0.textSize - 1, Settings.textSizeRange.lowerBound)
            default: $0.textSize = Settings().textSize
            }
        }
    }

    func revealCurrentNoteInFinder() {
        guard let filename = currentFilename else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [settings.value.vaultURL.appendingPathComponent(filename)]
        )
    }

    func openLink(_ target: String) {
        // Decline quietly. There is nothing to say that the note does not already say — the link is
        // on screen — and the test for whether to speak is whether a string names what happened.
        // "Nothing happened" does not.
        guard let url = LinkTarget.resolve(target) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyAsMarkdown(_ text: String) {
        // The markdown *is* the note, so there is nothing to convert — which is the whole reason the
        // design has this row where Raycast has "copy deeplink".
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func sendDeletedRows() {
        vault.deletedRows { [weak self] rows in
            self?.editor.send(.showDeleted(rows))
        }
    }

    func restoreDeleted(_ storedName: String) {
        vault.restoreDeleted(storedName) { [weak self] restored in
            guard let self, let restored else { return }
            // Opening it is the point. A restore that puts the note back but leaves you looking at a
            // different one makes you go and find it again.
            self.open(restored)
        }
    }

    func forgetDeleted(_ storedName: String) {
        vault.forgetDeleted(storedName) { [weak self] ok in
            guard let self, ok else { return }
            // The list stays open — purging is a tidying pass, and closing the panel after each one
            // would make clearing several a chore. Re-fetch rather than removing the row in the web
            // layer, so what is on screen is the folder rather than our idea of it.
            self.sendDeletedRows()
        }
    }

    func requestNotes(_ query: String) { sendRows(query: query) }
    func openSettings() { onOpenSettings?() }
    func panelReady() {
        editor.markReady()
        applySettings()
        session.openLastUsedIfNothingOpen()
    }
    func closeRequested() { dismiss() }
    func goBack() { session.goBack() }
    func goForward() { session.goForward() }
    func headingMenuRequested(below button: CGRect, current level: Int?) { showHeadingMenu(below: button, current: level) }
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

// MARK: - Window

extension PanelController: NSWindowDelegate {

    /// A drag is what turns auto-sizing off — decision 40, and Raycast Notes' behaviour exactly.
    ///
    /// Only a *drag* reaches here: programmatic `setFrame` fires no live-resize notification. So
    /// this is unambiguously the user stating a height, and the only reading of that which is not a
    /// lie is "stop resizing my window". Under the old floor rule this method recorded the height
    /// and then immediately grew back past it on any note taller than the panel.
    ///
    /// An overlay is not a statement of intent: the switcher and ⌘K resize the panel themselves, and
    /// dragging while one is open would otherwise pin the panel at panel height forever.
    /// The pill goes away for the length of the drag and comes back at the new bottom edge.
    ///
    /// Leaving it up would pin it to where the panel's bottom *was*, so it would sit in the middle of
    /// the window being resized — and no mouse-moved events arrive during a drag to correct it,
    /// because the pointer is reported as dragging rather than moving.
    func windowWillStartLiveResize(_ notification: Notification) {
        autoSizeBadge.suppressDuringResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        defer { refreshAutoSizeBadge() }
        guard !switcherIsOpen, !actionsIsOpen else { return }

        var next = panelState
        next.autoSizing = false
        next.manualHeight = Double(panel.frame.height)
        panelState = next
        rememberFrame()

        // The mode changed without anyone pressing the row, so the row's label is now a lie until
        // it is told. This is the only path that turns auto-sizing off silently, which is exactly
        // why it is the one that must announce it.
        editor.send(.setAutoSizing(false))
    }

    /// ⇧⌘/ — frame 2a's thirteenth row, and Raycast's key for it.
    ///
    /// Turning it back on drops the dragged height, so the panel immediately fits its note again;
    /// that snap is the feedback that the mode changed.
    func toggleAutoSizing() {
        var next = panelState
        next.autoSizing.toggle()
        next.manualHeight = next.autoSizing ? nil : Double(panel.frame.height)
        panelState = next

        editor.send(.setAutoSizing(next.autoSizing))
        applyContentHeight(heightWanted)
        rememberFrame()
    }

    var isAutoSizing: Bool { panelState.autoSizing }

    // MARK: - The auto-size pill

    /// Watches the pointer only while the panel is on screen.
    ///
    /// Two monitors because one is not enough: the global one sees events delivered to *other* apps,
    /// which is where the pointer is most of the time given Plume never activates (decision 9), and
    /// the local one sees events that land on the panel itself. Neither needs a permission — the
    /// accessibility gate is on keyboard taps, not mouse observation.
    private func startTrackingResizeEdge() {
        guard mouseMonitors.isEmpty else { return }
        let refresh: @Sendable (NSEvent) -> Void = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshAutoSizeBadge() } }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: refresh) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            refresh(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func stopTrackingResizeEdge() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        autoSizeBadge.hide()
    }

    /// Hover state, decided in Swift rather than in the page.
    ///
    /// The web layer's own `mouseenter`/`mouseleave` only fired once the panel had been clicked: a
    /// WKWebView in a window that is not key gets no mouse events at all, so the chrome stayed dim
    /// no matter where the pointer went — in exactly the situation decision 41 exists for, which is
    /// the panel sitting over another app you are working in. These monitors already watch the
    /// pointer for the pill and do not care which app is active, so hover comes from the same place.
    private func refreshHover() {
        guard panel.isSummoned else { return }
        let inside = isPointerOnPanel(NSEvent.mouseLocation)
        if inside != isHovered {
            isHovered = inside
            editor.send(.setHover(inside))
        }
        // Outside the guard on purpose: the pointer moving *within* an already-hovered panel is
        // precisely the movement that takes it onto the dot, and an early return here would mean the
        // dot only ever lit on the stroke that entered the window.
        refreshCloseHover()
        refreshPointer()
    }

    /// Decision 120: the page is told where the pointer is, so the tooltip can name what is under it.
    ///
    /// The same read as `refreshHover` and `refreshCloseHover`, generalised. Those two exist because
    /// the page receives no mouse events in Plume's real configuration, and each fixed one control by
    /// pushing Swift's answer in; the tooltip is the third thing with that problem and it had gone
    /// unnoticed because it works perfectly once the panel has been clicked — which is the one state
    /// nobody tests, since the point of the panel is that you never have to click it.
    ///
    /// Sent on every move rather than on enter and leave: the page decides which control it is over,
    /// and a bare "still inside" tells it nothing about moving from ⌘P to ⌘K.
    private func refreshPointer() {
        guard panel.isSummoned, isHovered, let p = editor.pointerInPage() else { return }
        editor.send(.setPointer(x: Double(p.x), y: Double(p.y)))
    }

    /// Decision 107: the close dot lights when the pointer is on it.
    ///
    /// Same read as `refreshHover`, one control down. `:hover` cannot do this — measured on
    /// 2026-09-01: with the panel in its real configuration (an accessory app's non-activating panel,
    /// not key, another app frontmost) the page received **zero** `mousemove` events with the cursor
    /// parked on the dot, and `:hover` matched nothing. The same probe with an ordinary key, active
    /// window saw 22 moves and eight `:hover` matches, so that is the app's situation rather than
    /// the apparatus. It is decision 41's finding exactly, which is why the plumbing was already here.
    private func refreshCloseHover() {
        let inside = isHovered
            && panel.isSummoned
            && (editor.closeButtonScreenRect()?.contains(NSEvent.mouseLocation) ?? false)
        guard inside != isCloseHovered else { return }
        isCloseHovered = inside
        editor.send(.setCloseHover(inside))
    }

    private func refreshAutoSizeBadge() {
        refreshHover()
        guard panel.isSummoned else {
            autoSizeBadge.hide()
            return
        }
        // Never over an open overlay: the switcher and ⌘K own the panel's whole height while they are
        // up, so the pill would be captioning a panel rather than the note.
        let frame = panel.frame
        let pointer = NSEvent.mouseLocation
        let near = !switcherIsOpen && !actionsIsOpen
            && AutoSizeBadge.isNearResizeEdge(pointer, of: frame)
            && isExposed(PanelGeometry.bottomEdgeProbe(nearest: pointer, of: frame))
        autoSizeBadge.update(near: frame, autoSizing: panelState.autoSizing, visible: near)
    }

    /// Decision 181: the pointer is on the panel only where the panel can be seen. Another app's
    /// floating window, Plume's own Settings, or the panel being on another Space all leave the
    /// rectangle where it was and the panel out of reach.
    private func isPointerOnPanel(_ point: CGPoint) -> Bool {
        panel.isSummoned && panel.frame.contains(point) && isExposed(point)
    }

    /// The window a click at `point` would reach is the panel's. Click-through windows, the pill
    /// among them, are not counted.
    private func isExposed(_ point: CGPoint) -> Bool {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber
    }

    /// Rule 3, "stay put": the drag is the only thing that moves a panel, so the drag is the only
    /// thing worth recording. Persisting here rather than only at dismiss means the position also
    /// survives a crash or a force-quit.
    func windowDidMove(_ notification: Notification) {
        guard panel.isSummoned else { return }
        rememberFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        editor.setFocused(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        editor.setFocused(false)
        // Decision 10's second immediate flush. Clicking away from the panel is exactly the moment a
        // half-typed thought must already be on disk.
        flush(trigger: .lostFocus)
        state.save()
    }
}

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
