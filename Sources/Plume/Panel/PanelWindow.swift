import AppKit
import PlumeKit

/// The window a note lives in.
///
/// Every unusual thing about it exists to satisfy one line of the bar — *summoning never activates
/// the app or changes the menu bar* — and design frame 1g's six behaviour rules. Measured on this
/// machine: an `.accessory` app **can** own a key window, and a `.nonactivatingPanel` shown with
/// `makeKeyAndOrderFront` leaves `frontmostApplication` and `menuBarOwningApplication` with the other
/// app, which is what the bar actually asks for. So don't check this with `NSApp.isActive`; it lies.
///
/// Borderless because the panel draws its own rounding, hairline and material in CSS (see the comment
/// at the top of `plume.css`) — the window is a transparent hole the web view fills.
@MainActor
final class PlumePanel: NSPanel {

    /// Rule 2's width. Resizing is allowed between `PanelGeometry.minimumWidth` and
    /// `maximumWidth` — the content has its own measure, so past that a wider panel buys gutters
    /// rather than longer lines, and it used to be draggable to the full width of a display.
    ///
    /// **460, not 692.** 692 was the width at which `--content-measure` (680px) exactly touches both
    /// edges, which made it the widest *useful* panel — and it was then also shipped as the default,
    /// which is a different question nobody had asked. A panel at its own maximum measure is a
    /// document window; measured side by side at 400/460/520/692 with the welcome note in it, 692
    /// reads as one, and the note's structure is lost across 85 characters of line. 460 gives a 416pt
    /// column, about 55 characters — inside the classic comfortable measure, and the shape a person
    /// actually reaches for. The maximum is untouched: drag it to 724 whenever a note wants it.
    ///
    /// The format bar was the thing to check before moving, and it fits: all sixteen controls at 400,
    /// with room. See decision 129.
    static let defaultWidth: CGFloat = 460

    /// Square with `defaultWidth`, and it is a real size rather than a placeholder now — decision 129
    /// ships the first run with auto-sizing off, so this is the panel a new user actually sees.
    static let defaultHeight: CGFloat = 460

    /// The title bar is the drag handle (rule 3), and its height is the one number Swift needs from
    /// the design tokens to decide whether a remembered frame is still reachable.
    static let titleBarHeight: CGFloat = 40

    /// Somewhere no display reaches. Dismiss moves the window here rather than hiding it, because
    /// `setIsVisible(false)` **suspends the WKWebView** — measured, with rAF gaps of 653 ms and
    /// 3991 ms — and a suspended web view cannot meet a 100 ms summon. Offscreen keeps it warm
    /// (34–39 ms) and, unlike `alphaValue = 0`, cannot swallow a click meant for another app.
    private static let offscreenOrigin = CGPoint(x: -30_000, y: -30_000)

    private var onscreenFrame: CGRect?

    /// Whether the panel is meant to be on screen, held rather than derived.
    ///
    /// `isSummoned` used to read the origin alone, which made "dismissed" a fact about geometry that
    /// anything moving the window could overwrite — and something does. See `reparkAfterScreenChange`.
    private var parked = false

    override var canBecomeKey: Bool { true }

    /// Never main. Main window status is what drives the menu bar, and Plume's whole trick is not
    /// touching it.
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        applyLevel()
        // Without this an accessory app's panel vanishes the moment you click back into your editor,
        // which is the opposite of a panel you can type into while reading something else.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        // The drag handle is a Swift overlay over the web view's title bar, not
        // `isMovableByWindowBackground`: a full-window WKWebView consumes mouse events, so the
        // background drag would never fire — and if it did, it would fire in the text too.
        isMovableByWindowBackground = false

        // Off, or the panel would appear in a screen recording's window list and in Mission Control
        // as a window you can miss. It is a HUD over your work, not a document.
        isExcludedFromWindowsMenu = true

        // A panel whose whole point is that it sits over other apps must not need a click to focus
        // and a second click to place the caret.
        acceptsMouseMovedEvents = true

        // A resizable window with no floor can be dragged to nothing, and a panel dragged to nothing
        // is unrecoverable: there is no title bar left to grab and no close dot left to click.
        // `PanelGeometry.minimumHeight` is the same floor auto-sizing already respects — title bar,
        // one line, footer — and the width keeps the three title bar buttons and the footer's word
        // count from colliding.
        minSize = NSSize(width: Self.minimumWidth, height: PanelGeometry.minimumHeight)

        // Both axes are capped now. Width past the content's measure is gutters
        // (`PanelGeometry.maximumWidth`); height had no cap at all until a rotated 1080×1920 display
        // showed what "the screen is the ceiling" means on a screen that is 1920 tall — see
        // `PanelGeometry.maximumHeight`, which is derived from the width cap rather than picked.
        maxSize = NSSize(width: PanelGeometry.maximumWidth, height: PanelGeometry.maximumHeight)

        applyCollectionBehaviour()
        observeScreenChanges()
    }

    // MARK: - Staying parked across a display change

    /// AppKit rescues windows that sit on no display, and a dismissed panel is exactly that.
    ///
    /// Dismiss parks the window at `offscreenOrigin` rather than hiding it, because
    /// `setIsVisible(false)` suspends the WebContent process and a suspended web view cannot meet the
    /// 100 ms summon bar. The cost of that trick is that the window is, as far as AppKit is
    /// concerned, a window the user has lost: when the screen configuration changes — a monitor
    /// sleeping and waking, a lid closing and opening, a display unplugged — it walks the window list
    /// and moves anything outside every screen back onto the main one. So closing and reopening a
    /// laptop put a dismissed panel on the desktop, unasked, with nobody having summoned it.
    ///
    /// **Measured, by flipping the display mode with `CGConfigureDisplayWithDisplayMode` and logging
    /// every frame call.** Two things came out of it that guesswork got wrong:
    ///
    /// - **`constrainFrameRect` is not the hook.** It *is* consulted — with `(240, 752)`, the origin
    ///   AppKit had already picked — and returning the rect unchanged changed nothing: the very next
    ///   call was `setFrame` to `(240, 784)`. Overriding it to decline the rescue reads exactly like
    ///   a fix and is not one, so there is no override here.
    /// - **The notification arrives after the move, which is what makes it work.** By the time this
    ///   fires the origin already reads `(240, 784)`, so re-parking has something to undo. Both
    ///   happen in the same millisecond, so nothing is drawn on screen in between.
    ///
    /// The other half of the fix is that `parked` has to be true in the first place. It was not:
    /// `PlumeController.init` parked the panel at startup with a bare `setFrameOrigin` on its own copy
    /// of the literal, so a panel that had never been summoned was offscreen with `parked` false and
    /// this guard switched off. That is now `parkBeforeFirstSummon`.
    ///
    /// A panel that is genuinely on screen is left alone, and should be: it may have been on the
    /// display that just went away, and AppKit bringing it back is the right answer there.
    ///
    /// The remembered frame is untouched — `onscreenFrame` is where the panel returns to, and a
    /// display change must not silently redefine it. `PanelGeometry` reconciles it against the
    /// connected displays at summon time, which is the right moment: the answer depends on the
    /// screens attached *then*, not on the screens attached when the lid shut.
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reparkAfterScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func reparkAfterScreenChange() {
        guard parked, frame.origin != Self.offscreenOrigin else { return }
        setFrameOrigin(Self.offscreenOrigin)
    }

    /// Lives in `PanelGeometry` so the clamp and the window agree; kept here as the name the rest
    /// of the shell already uses.
    static var minimumWidth: CGFloat { PanelGeometry.minimumWidth }

    // MARK: - Spaces

    /// Assigned to every Space (`SpaceAssignment.everySpace`), every panel joins every Space, pinned or not.
    ///
    /// This reverses the Space half of rule 5, and the reason is that the rule was built on a
    /// conflation the design record itself makes. "Pinned" means two different things in two
    /// different frames: in 1c it is a note sorted to the top of the switcher, and in 1g it is a
    /// window that ignores dismiss *and* follows Space switches. Wiring one control to all three
    /// made the Space behaviour a side effect of a list-ordering choice, which is not a thing anyone
    /// could predict — and it showed up exactly as you would expect, as an unpinned panel refusing to
    /// come to the Space you were on.
    ///
    /// `.moveToActiveSpace` was also the wrong tool for it. It is evaluated when a window is ordered
    /// front, and this window is never ordered out — dismiss parks it offscreen so the WebContent
    /// process stays warm, which is what keeps the 100 ms bar reachable. A window already in the
    /// window list gets re-fronted without AppKit reconsidering its Space, so the rule failed
    /// silently rather than loudly.
    ///
    /// `.canJoinAllSpaces` has neither problem: the panel is on every Space already, so summoning is
    /// only ever a matter of moving it back on screen. Pinning keeps the meaning that is actually
    /// about the note — top of the switcher. Decision 180 took the dismiss-hotkey half off it too.
    ///
    /// `.fullScreenAuxiliary` joins a fullscreen app as an overlay rather than forcing a Space
    /// switch out of it.
    /// The effective assignment's every-Space flag: an explicit Dock binding takes precedence
    /// over Plume's saved preference. The controller resolves that policy.
    ///
    /// Off drops `.canJoinAllSpaces`, so the panel belongs to the Space it is on rather than being
    /// drawn on all of them. `.ignoresCycle` and `.fullScreenAuxiliary` stay either way — the panel
    /// is never a ⌘Tab candidate, and it still overlays a fullscreen app rather than forcing a
    /// Space switch out of one.
    ///
    /// Off is the default, so it is the initial value too: the panel is ordered in offscreen at
    /// startup, before `applySettings` runs. See `Settings.spaceAssignment` for why off.
    var showsOnEverySpace = false {
        didSet { if showsOnEverySpace != oldValue { applyCollectionBehaviour() } }
    }

    /// Whether the panel stays above other applications (`Settings.keepOnTop`). Off, it is an
    /// ordinary-level window: summoning still brings it to the front, but it goes behind whatever
    /// is clicked next.
    var keepsOnTop = false {
        didSet { if keepsOnTop != oldValue { applyLevel() } }
    }

    /// Set while a window the app put in front on purpose (Settings, a save panel) is up; see
    /// `stepAside`. Kept apart from `keepsOnTop` so that stepping aside never forgets the choice.
    private var steppedAside = false {
        didSet { if steppedAside != oldValue { applyLevel() } }
    }

    /// `isFloatingPanel` owns the level — setting `level` alone leaves it back at `.floating` — so
    /// the two always move together.
    private func applyLevel() {
        let floating = (keepsOnTop || raisedWhileFocused) && !steppedAside
        isFloatingPanel = floating
        level = floating ? .floating : .normal
    }

    /// Held from the moment the panel is summoned until it loses key status.
    ///
    /// **Why a level change and not a better `order` call.** Measured, with a plain foreground app
    /// whose window overlaps the panel: at `.normal` the panel is ordered front, reports
    /// `isKeyWindow` and `isVisible`, and then — within 20 to 50 ms — the window server settles it
    /// *behind* the frontmost app's window, because Plume never activates and that app does. It is
    /// the app's window that wins the tie at the same level, so `orderFrontRegardless` repeated
    /// every 30 ms for a second changed nothing. Nothing moved the panel; it was covered.
    ///
    /// Where the other app's window does not overlap the panel the tie never matters, which is why
    /// this only ever showed over a window sharing the panel's area.
    ///
    /// So the panel sits one level up for as long as it is the thing being typed into, and drops back
    /// to `.normal` when it resigns key — which is exactly the `keepOnTop == false` promise, "it
    /// comes forward when summoned and then goes behind whatever you click next".
    private var raisedWhileFocused = false {
        didSet { if raisedWhileFocused != oldValue { applyLevel() } }
    }

    /// Brings the panel in front of everything, including a window of the app that is frontmost.
    /// The one place that orders the panel front, so every route in agrees on how.
    func bringToFront() {
        raisedWhileFocused = true
        makeKeyAndOrderFront(nil)
        // `orderFrontRegardless` is the one that crosses a Space boundary without activating the
        // app. `makeKeyAndOrderFront` alone gives the panel key status on the Space it is already on.
        orderFrontRegardless()
    }

    override func resignKey() {
        super.resignKey()
        // Not while parked: a dismissed panel is offscreen and its level is nobody's business.
        raisedWhileFocused = false
    }

    func applyCollectionBehaviour() {
        var behaviour: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        if showsOnEverySpace { behaviour.insert(.canJoinAllSpaces) }
        collectionBehavior = behaviour
    }

    /// Re-enter the window list with the resolved collectionBehavior so macOS can apply Dock's
    /// app binding. Keep the same frame, parked state, document and focus; never activate the app
    /// or request that Mission Control switch desktops.
    func reapplySystemSpaceAssignment() {
        let hadFocus = isKeyWindow
        orderOut(nil)
        orderFrontRegardless()
        if hadFocus && isSummoned && isOnActiveSpace { makeKey() }
    }

    // MARK: - Summon and dismiss

    var isSummoned: Bool { onscreenFrame != nil && !parked }

    /// Puts the panel back where it was, on the Space you are on now.
    ///
    /// - Parameter frame: where to appear. Rule 3 — "only a drag moves a panel" — so this is the
    ///   remembered frame, already reconciled against the connected displays by `PanelGeometry`.
    func summon(at frame: CGRect) {
        onscreenFrame = frame
        parked = false
        setFrame(frame, display: false)

        // Re-assert the collection behaviour on every summon, not just when the setting changes.
        //
        // `.moveToActiveSpace` is evaluated when a window is *ordered front*, and this window is
        // never ordered out — dismiss parks it offscreen so the web view stays warm (measured:
        // `setIsVisible(false)` suspends it). A window that is already in the window list can be
        // re-fronted without AppKit reconsidering which Space it belongs on, which is rule 1
        // silently failing: summon on another Space and nothing appears.
        //
        // Kept to a Space (93) and summoned from another one, the panel comes to the Space you are on
        // and belongs to it from then on (180). Only a window ordered in again is placed afresh.
        if !showsOnEverySpace && !isOnActiveSpace { orderOut(nil) }

        bringToFront()
    }

    /// Puts a parked panel back on screen on the desktop it is on, which is not the one being looked
    /// at — a panel kept to one desktop (`SpaceAssignment.oneSpace`), summoned from another.
    ///
    /// No ordering and no key. Ordering front is what would carry it across a Space boundary, and
    /// the focus belongs to the app you summoned from, where you still are. It is on screen when you
    /// get there.
    func present(at frame: CGRect) {
        guard parked else { return }
        onscreenFrame = frame
        parked = false
        setFrame(frame, display: false)
    }

    /// Re-files a parked panel on the desktop being looked at, still offscreen.
    ///
    /// For a panel kept to one desktop that is not on it — it was parked at launch wherever Plume
    /// happened to start. Arriving on its desktop puts it there, so the next summon finds it home and
    /// a summon from elsewhere can `present` it in place. Ordering out and back in is the only
    /// public way to place a window on a Space (see `summon`).
    func parkOnActiveSpace() {
        guard parked, !showsOnEverySpace, !isOnActiveSpace else { return }
        orderOut(nil)
        orderFront(nil)
    }

    /// Parks the panel before it has ever been summoned.
    ///
    /// The web view has to be laid out and warm before the first summon, so the window is ordered
    /// front offscreen at startup rather than shown later. That has to go through here rather than
    /// through a bare `setFrameOrigin`: `parked` is what every guard in this file reads, and a window
    /// sitting at `offscreenOrigin` with `parked` still false is a panel AppKit is free to rescue onto
    /// the desktop at the next display change, which is exactly what it did.
    func parkBeforeFirstSummon() {
        parked = true
        setFrameOrigin(Self.offscreenOrigin)
        orderFront(nil)
    }

    /// Moves the panel out of sight without letting the web view go to sleep.
    ///
    /// - Returns: the frame it was occupying, for `state.json`.
    @discardableResult
    func dismiss() -> CGRect? {
        let was = frame
        guard !parked else { return onscreenFrame }
        parked = true
        raisedWhileFocused = false
        onscreenFrame = was
        setFrameOrigin(Self.offscreenOrigin)
        return was
    }

    /// The frame the panel would return to, in screen coordinates.
    ///
    /// While the panel is on screen this is simply its live frame, and that is the whole point: the
    /// user drags the window with the mouse, so AppKit — not this class — is the only thing that
    /// knows where it ended up. Returning the origin stashed at summon time instead meant every drag
    /// was thrown away and the panel reappeared wherever it was last *programmatically* placed.
    var rememberedFrame: CGRect? {
        parked ? onscreenFrame : frame
    }

    /// Resizes while offscreen or onscreen without losing track of where "onscreen" is.
    func applyHeight(_ frame: CGRect) {
        if parked {
            onscreenFrame = frame
            setContentSize(frame.size)
        } else {
            onscreenFrame = frame
            setFrame(frame, display: true)
        }
    }
}

extension PlumePanel {

    /// Steps every panel out of the way of a window the app has put in front on purpose.
    ///
    /// A panel the user has kept on top sits at `.floating` so it stays above other applications. A save
    /// panel, an `NSAlert` and the Settings window are ordinary windows at `.normal`, so **all four
    /// moments Plume deliberately activates** (decisions 16, 27, 37 and the Sync alert of decision
    /// 30) put their window *behind* the panel. Measured on the running app: the Export panel's Save
    /// button sat under the panel's edge, and Settings opened with its first rows covered.
    ///
    /// The panel is lowered rather than the other window raised, and that is the whole design.
    /// Raising Settings to `.floating` would leave it above every *other* app's windows too, which
    /// is exactly the behaviour Plume reserves for the panel. Lowering is also scoped by construction:
    /// it lasts only as long as the window that asked for it.
    ///
    /// `isFloatingPanel` is cleared as well, because it owns the level — setting `level` alone left
    /// the panel back at `.floating` and the save panel still behind it.
    static func stepAside() {
        for plume in NSApp.windows.compactMap({ $0 as? PlumePanel }) {
            plume.steppedAside = true
        }
    }

    /// Puts them back. Safe to call when nothing stepped aside.
    static func resumeFloating() {
        for plume in NSApp.windows.compactMap({ $0 as? PlumePanel }) {
            plume.steppedAside = false
        }
    }

    /// The scoped form, for anything that runs modal.
    static func steppingAside<T>(_ body: () throws -> T) rethrows -> T {
        stepAside()
        defer { resumeFloating() }
        return try body()
    }
}
