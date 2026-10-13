import AppKit
import Foundation
import PlumeKit

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
    func headingMenuRequested(below button: CGRect, current level: Int?) { showHeadingMenu(below: button, current: level) }
}
