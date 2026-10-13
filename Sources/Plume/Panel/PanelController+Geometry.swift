import AppKit
import Foundation
import PlumeKit

/// How tall the panel should be right now, and where it sits.
extension PanelController {

    /// The height the panel should be right now.
    ///
    /// With auto-sizing on that is the note's height; with it off it is the height the user dragged
    /// to, and the note scrolls (decision 40). **An open overlay overrides both**, because the
    /// switcher and ⌘K are drawn inside this window and a panel clipped by its own panel is not a
    /// size anyone asked for. Closing the overlay returns to whichever answer the mode gives.
    var heightWanted: CGFloat {
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

    func applyContentHeight(_ desired: CGFloat) {
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
}
