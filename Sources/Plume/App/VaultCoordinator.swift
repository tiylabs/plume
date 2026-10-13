import AppKit
import PlumeKit

/// Which folder the notes are in, and what to do when it is not there.
///
/// Decision-13 territory: the vault is resolved before anything reads a note, "create it" is only ever
/// allowed to happen once, and a vault that has simply gone is *asked about*, never recreated. This is
/// also where the folder is watched, because a watcher is a property of which folder it is.
///
/// The three things it has to tell the rest of the app — Git sync that the vault is active, the panel
/// that notes changed, the menu bar that the pins may have moved — are closures, so it knows nothing
/// of any of them.
@MainActor
final class VaultCoordinator {

    private let settings: SettingsStore
    private let state: StateStore

    /// Set once the service exists. Nil during launch, before the vault has been resolved.
    var vault: VaultService?
    var panel: PanelController?

    /// Continue launching: called when the chooser is dismissed by choosing a folder, at a point
    /// where launch had stopped for the want of one.
    var resumeLaunch: () -> Void = {}
    /// Anything in the vault changed that is not Git's own bookkeeping.
    var onVaultActivity: () -> Void = {}
    /// Note files changed.
    var onNotesChanged: ([String]) -> Void = { _ in }
    /// Pruning finished: the menu bar's titles may be stale.
    var onPruned: () -> Void = {}

    private var watcher: VaultWatcher?

    init(settings: SettingsStore, state: StateStore) {
        self.settings = settings
        self.state = state
    }

    func stopWatching() { watcher?.stop() }

    /// - Returns: false when the app cannot continue without the user choosing a folder, in which
    ///   case the chooser has been put on screen and launch resumes from its completion.
    func prepare() -> Bool {
        let url = settings.value.vaultURL
        switch VaultLifecycle.situation(vault: url, everCreated: state.value.vaultEverCreated) {
        case .ready:
            state.update { $0.vaultEverCreated = true }
            return true

        case .firstLaunch:
            do {
                try VaultLifecycle.create(vault: url)
                state.update { $0.vaultEverCreated = true }
                return true
            } catch {
                presentChooser(
                    message: tr("vault.createFailed", ["path": url.path]),
                    detail: error.localizedDescription
                )
                return false
            }

        case .vaultMissing(let missing):
            presentChooser(
                message: tr("vault.missing.title"),
                detail: tr("vault.missing.detail", ["path": missing.path])
            )
            return false

        case .pathIsNotADirectory(let path):
            presentChooser(
                message: tr("vault.notFolder.title"),
                detail: tr("vault.notFolder.detail", ["path": path.path])
            )
            return false
        }
    }

    func handleMissing() {
        guard case .vaultMissing = VaultLifecycle.situation(
            vault: settings.value.vaultURL,
            everCreated: state.value.vaultEverCreated
        ) else { return }

        presentChooser(
            message: tr("vault.missing.title"),
            detail: tr("vault.missing.detailShort", ["path": settings.value.vaultURL.path])
        )
    }

    /// The "choose vault" state (decision 13), as a panel rather than a designed panel.
    ///
    /// The design record never drew this one and the brief says so. Using AppKit's own alert and open
    /// panel here is a deliberate choice, not a shortcut: this is the one moment Plume is allowed to
    /// activate, the user is at their least patient, and a familiar system dialog says "your files
    /// are a filesystem problem, and you are in charge of it" better than bespoke chrome would.
    private func presentChooser(message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("vault.chooseFolder"))
        alert.addButton(withTitle: tr("vault.quit"))

        guard PanelWindow.steppingAside({ alert.runModal() }) == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = tr("folderPanel.prompt")
        picker.message = tr("folderPanel.message")

        guard PanelWindow.steppingAside({ picker.runModal() }) == .OK, let chosen = picker.url else {
            presentChooser(message: message, detail: detail)
            return
        }

        settings.update { $0.vaultPath = chosen.path }
        state.update { $0.vaultEverCreated = true }

        if let vault, let panel {
            vault.setVault(chosen)
            startWatching()
            panel.openLastUsedNote()
        } else {
            resumeLaunch()
        }
    }

    func startWatching() {
        watcher?.stop()
        // Captured once, outside the `@Sendable` handler: that handler runs on the watcher's queue and
        // hands `self` to the main queue twice, which Swift 6.2's region checker rejects when each
        // hop captures `self` separately. The coordinator lives for the process (the delegate holds it).
        let box = WeakCoordinator(self)
        let watcher = VaultWatcher { paths in
            // Git's own bookkeeping is not the notes changing; counting it would have every sync
            // cycle look like somebody typing.
            if paths.contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.value?.onVaultActivity() }
                }
            }
            let names = VaultWatcher.noteFilenames(in: paths)
            guard !names.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.value?.onNotesChanged(names) }
            }
        }
        watcher.start(watching: settings.value.vaultURL)
        self.watcher = watcher
    }

    /// Drops caret offsets and pins for notes that are no longer in the vault.
    ///
    /// Only ever from a listing that succeeded, and never for a note that is merely evicted —
    /// `AppState.forgetNotes` documents why: a slow sync is not a deletion.
    func pruneStateForMissingNotes() {
        vault?.present { [weak self] present in
            guard let self, !present.isEmpty else { return }
            self.state.update { $0.forgetNotes(missingFrom: present) }
            self.onPruned()
        }
    }
}

/// A weak reference that may cross into the watcher's `@Sendable` handler. It is only ever read inside
/// `MainActor.assumeIsolated`, on the main queue, which is where the coordinator lives.
private final class WeakCoordinator: @unchecked Sendable {
    weak var value: VaultCoordinator?
    init(_ value: VaultCoordinator) { self.value = value }
}
