import AppKit
import Foundation
import PlumeKit

/// Which desktop the panel lives on, and what happens when it is summoned from another one.
extension PanelController {

    /// One policy drives both collectionBehavior and the hotkey's desktop restriction. Reordering
    /// a system-managed window after a policy change lets Dock apply its binding to this existing
    /// panel, whose offscreen parking otherwise keeps it permanently in the window list.
    func applySpacePolicy() {
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
    func assignedDesktopElsewhere() -> Spaces.Desktop? {
        guard let desktop = assignedDesktop(), let active = Spaces.active(), active.uuid != desktop.uuid
        else { return nil }
        return desktop
    }

    /// A summon of a panel kept to another desktop: up there if it was parked there, and a notice
    /// here either way. Nothing moves and the focus stays with the app you summoned from.
    func summonElsewhere(on desktop: Spaces.Desktop) {
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
    @objc func activeSpaceDidChange() {
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
    func sendSpaceAssignment() {
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

    func rememberFrame() {
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
    static func displayKey(_ screen: NSScreen) -> String {
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
}
