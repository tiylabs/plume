import AppKit
import Foundation
import PlumeKit

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
    func startTrackingResizeEdge() {
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

    func stopTrackingResizeEdge() {
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
    func refreshCloseHover() {
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
    func isPointerOnPanel(_ point: CGPoint) -> Bool {
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
