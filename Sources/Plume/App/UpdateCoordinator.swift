import AppKit
import PlumeKit

/// The daily release check, and where its answer goes.
///
/// Holds exactly what it uses — the two stores, the panel it may toast into, and the menu bar it may
/// light — and nothing else, so it can be read without knowing what the rest of the app is.
@MainActor
final class UpdateCoordinator {

    private let settings: SettingsStore
    private let state: StateStore
    private let panel: PanelController
    /// A closure rather than the controller: the menu bar item can be switched off in Settings, and
    /// then there is no one to tell.
    private let menuBar: () -> MenuBarController?

    init(
        settings: SettingsStore,
        state: StateStore,
        panel: PanelController,
        menuBar: @escaping () -> MenuBarController?
    ) {
        self.settings = settings
        self.state = state
        self.panel = panel
        self.menuBar = menuBar
    }

    /// The newer version the last check found, re-derived from `state.json` on the way out.
    ///
    /// **Persisted, and compared again here.** Held only in memory it vanished on relaunch and the
    /// menu bar item — the half that is supposed to wait — did not come back until the next daily
    /// check, up to a day later. Re-comparing rather than trusting the stored string is what makes
    /// upgrading clear it immediately: the file still says `v0.6.6` on the first launch of v0.6.6,
    /// and `ReleaseCheck.pending` answers nil, so nothing is shown.
    var latestAvailableVersion: String? {
        guard BuildProfile.current.allowsSystemIntegration else { return nil }
        return ReleaseCheck.pending(
            remembered: state.value.availableUpdate, running: ReleaseFetcher.runningVersion
        )
    }

    /// Asks GitHub whether there is a newer release, at most once a day, on summon.
    ///
    /// **Decision 136, and it amends decision 94's "nothing on launch, nothing scheduled".** The
    /// half that survives is the important one: this is not a timer and not a launch hook, so it
    /// only ever runs with somebody at the keyboard — a summon is a keypress. Nothing is
    /// downloaded, installed or opened, and nothing about the machine is sent.
    ///
    /// The notice is in two parts on purpose. The **toast** is the part that fires: once a day, on
    /// the summon that ran the check, for as long as the running build is behind. A badge on a menu
    /// bar icon is not something you can count on being seen — the icon may not fit in a crowded
    /// menu bar, and `showMenuBarIcon` can be off. The **menu item and the dot** are the part that
    /// waits, and they are derived from the comparison rather than from a flag, so they cannot be
    /// stale.
    func checkIfDue() {
        guard BuildProfile.current.allowsSystemIntegration else { return }
        guard ReleaseCheck.shouldCheck(
            enabled: settings.value.checkForUpdates,
            lastChecked: state.value.lastUpdateCheck
        ) else { return }

        // Stamped before the request rather than after it, so a machine that is offline all week
        // asks once a day rather than on every summon.
        state.update { $0.lastUpdateCheck = Date() }

        ReleaseFetcher.fetchStatus { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.record(status)
                    self.announce()
                }
            }
        }
    }

    /// Where every check's answer goes, whichever caller asked — the summon check above, or the
    /// button under Settings → About.
    ///
    /// The button used to keep its answer to itself: it said "v0.6.6 is available" and the menu bar
    /// never lit. It also stamps the daily check, because pressing it *is* a check, so the summon
    /// after it does not ask again — and does not toast what the reader was just told.
    func record(_ status: ReleaseCheck.Status) {
        // `$0` inside the block, never `state.value`: reading the store during `state.update` is a
        // simultaneous access to storage already held for modification, and Swift traps the
        // process (decision 124, found by pressing the word count once).
        state.update {
            $0.availableUpdate = ReleaseCheck.remembered(after: status, previously: $0.availableUpdate)
            $0.lastUpdateCheck = Date()
        }
        menuBar()?.setUpdateAvailable(latestAvailableVersion)
    }

    /// The daily toast, while there is something newer.
    ///
    /// From what is remembered, not from this check's answer alone: a check that could not reach
    /// the network on the day still knows what yesterday's found, and saying it again is the point.
    ///
    /// Named, and nothing after it (decision 76). Where to get it is the menu bar item; the toast's
    /// job is to say there is something.
    ///
    /// Only into a panel that is actually on screen. The check runs on summon, so it normally is —
    /// but the answer arrives over the network, and a dismissal in that second would otherwise fire
    /// a notice into a parked window where nobody would ever see it. Skipped, it comes round again
    /// with tomorrow's check.
    func announce() {
        guard let version = latestAvailableVersion, panel.isVisible else { return }
        panel.showToast(tr("update.toast", ["version": version]), dwell: PanelController.newsDwell)
    }
}
