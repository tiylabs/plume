import AppKit
import PlumeKit
import ServiceManagement

/// Wires the app together and owns everything with a process lifetime.
///
/// Deliberately thin. The panel knows how to be a panel, the vault service knows how to touch files,
/// and this type knows only the order things have to happen in on launch — which is the one piece of
/// logic that genuinely belongs to "the application" rather than to any part of it. The pieces with a
/// life of their own — the vault's lifecycle, the release check, the main menu — are `VaultCoordinator`,
/// `UpdateCoordinator` and `MainMenuBuilder`; this connects them.
@MainActor
final class AppCoordinator {

    private let settings = SettingsStore()
    private let state = StateStore()

    private var vault: VaultService!
    private var panelController: PanelController!
    private var menuBar: MenuBarController!
    private var hotkey: GlobalHotkey!
    private let gitSync = GitSyncController()
    private var settingsWindow: SettingsWindowController?

    private lazy var vaultCoordinator = VaultCoordinator(settings: settings, state: state)
    private var updates: UpdateCoordinator!
    private lazy var mainMenu = MainMenuBuilder(
        settings: { [unowned self] in settings.value },
        openSettings: { [unowned self] in openSettingsWindow() },
        newNote: { [unowned self] in
            panelController?.summon()
            panelController?.createNote(title: "")
        },
        browseNotes: { [unowned self] in panelController?.openSwitcher() },
        closePanel: { [unowned self] in panelController?.dismiss() }
    )

    /// Where `vault` is currently pointed, so a settings change can tell a vault move from any other
    /// edit. Read back from the service instead would mean hopping onto its queue to answer a
    /// question the main actor already knows.
    private var currentVaultURL: URL?

    func start() {
        // First, before a single string is looked up: every menu, alert and the welcome note below
        // reads the catalog, and `settings` is already loaded (it is a stored property).
        Localizer.start(preference: settings.value.language)

        mainMenu.install()
        applyDockIcon()

        // Decision 13, and the order matters: the vault has to be resolved before anything tries to
        // read a note out of it, and "create it" is only ever allowed to happen once.
        vaultCoordinator.resumeLaunch = { [weak self] in self?.start() }
        guard vaultCoordinator.prepare() else { return }

        vault = VaultService(vault: settings.value.vaultURL)
        currentVaultURL = settings.value.vaultURL
        panelController = PanelController(vault: vault, state: state, settings: settings)
        panelController.onPinsChanged = { [weak self] in self?.refreshMenuBar() }
        panelController.onVaultMissing = { [weak self] in self?.vaultCoordinator.handleMissing() }
        panelController.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
        panelController.onSummoned = { [weak self] in self?.updates.checkIfDue() }
        updates = UpdateCoordinator(
            settings: settings, state: state, panel: panelController, menuBar: { [weak self] in self?.menuBar }
        )
        wireVaultCoordinator()

        installMenuBarItem()
        installHotkey()
        vaultCoordinator.startWatching()
        applyLaunchAtLogin()
        startGitSync()

        settings.onChange = { [weak self] new in self?.settingsChanged(new) }
        // Decision 12's promise — "changing the hotkey is a one-line edit" — only holds if the edit
        // takes effect. The Settings window is the ordinary way in now, but the file is still there
        // and still documented, so it still has to work.
        settings.watchForHandEdits()

        vaultCoordinator.pruneStateForMissingNotes()

        // Decision 20's retention, enforced at the only moment it can be: Plume is not running most
        // of the time, so there is no timer that could have fired. Launch is when the clock is read.
        vault.purgeDeleted(keepingDays: settings.value.recentlyDeletedDays)

        installPresetThemes()
    }

    /// What the vault coordinator needs to tell the rest of the app.
    private func wireVaultCoordinator() {
        vaultCoordinator.vault = vault
        vaultCoordinator.panel = panelController
        vaultCoordinator.onVaultActivity = { [weak self] in self?.gitSync.vaultDidChange() }
        vaultCoordinator.onNotesChanged = { [weak self] names in
            self?.panelController?.vaultChanged(filenames: names)
            self?.refreshMenuBar()
        }
        vaultCoordinator.onPruned = { [weak self] in self?.refreshMenuBar() }
    }

    /// Copies the bundled preset themes into the Themes folder, the first time there is no folder.
    ///
    /// Decision 19 says a theme is a CSS file in a folder, and the folder shipped empty — so the
    /// mechanism existed and had nothing in it to select, which reads as a feature that does not
    /// work rather than one waiting for you to write CSS. The presets are the worked examples.
    ///
    /// **Only when the folder is absent**, never file by file. A preset the user deleted is a
    /// decision, and an app that puts it back every launch is arguing with them; a preset they
    /// edited is theirs, and overwriting it would be worse. Absent folder means first run — or a
    /// user who cleared it out entirely, who gets them back, which is the one case where restoring
    /// is the friendlier reading.
    private func installPresetThemes() {
        let folder = settings.themesFolder
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Themes"),
            let presets = try? FileManager.default.contentsOfDirectory(
                at: bundled, includingPropertiesForKeys: nil
            )
        else { return }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for preset in presets where preset.pathExtension == "css" {
            try? FileManager.default.copyItem(
                at: preset,
                to: folder.appendingPathComponent(preset.lastPathComponent)
            )
        }
    }

    // MARK: - Settings

    /// Re-applies everything after a settings change, from either the window or a hand edit.
    ///
    /// Everything, rather than a diff: there are a dozen settings and re-applying all of them costs
    /// less than the bookkeeping to know which one moved — and gets the case where several changed at
    /// once, which Restore Defaults does by design.
    func settingsChanged(_ new: Settings) {
        // The vault path is the one setting that is not a preference — it is which files the app is
        // looking at. Everything else here re-applies in place; this has to re-point the service,
        // restart the watcher and reopen a note, in that order.
        //
        // Missing from the first version of this method, which made decision 32's promise a
        // half-truth: every key in settings.json reloaded live except the one whose stale value is
        // most visible, and a hand-edited vaultPath silently did nothing until the next launch.
        if new.vaultURL.standardizedFileURL != currentVaultURL?.standardizedFileURL {
            // Write what is on screen before the service points anywhere else — decision 56's rule,
            // reached from the other direction. Without it, an edit still inside the 500 ms debounce
            // when the vault path changes is written against the *new* folder under the old note's
            // name, or not at all. Safe rather than a race for the same reason: vault I/O is one
            // serial queue, so this write runs with the old location before `setVault` changes it.
            panelController?.flush(trigger: .noteSwitched)
            currentVaultURL = new.vaultURL
            vault?.setVault(new.vaultURL)
            vaultCoordinator.startWatching()
            panelController?.openLastUsedNote()
        }

        // Before anything below rebuilds UI, so it all comes out in the new language.
        if Localizer.apply(preference: new.language) { languageChanged() }

        if hotkey?.registered != new.summonHotkey { installHotkey() }
        mainMenu.applyShortcuts()
        applyDockIcon()
        applyLaunchAtLogin()
        applyMenuBarIconVisibility()
        panelController?.applySettings()
        settingsWindow?.settingsChanged(new)
        menuBar?.rebuild(hotkey: new.summonHotkey)
        // Shortening the retention should take effect now rather than at the next launch — the
        // reason someone reaches for that control is usually that they want something gone.
        vault?.purgeDeleted(keepingDays: new.recentlyDeletedDays)
        gitSync.configure(with: new)
    }

    /// Re-says everything that was built in the old language.
    ///
    /// The main menu and the status-item menu are rebuilt; the web editor is told in
    /// `applySettings`, which the caller runs right after. A window that is already open cannot be
    /// re-labelled in place — its controls were created with the old strings — so the Settings
    /// window is closed and dropped, and `openSettingsWindow` makes a fresh one the next time. That
    /// is also what lets it be reopened *immediately*: the user changed the language from inside it
    /// and would otherwise be left looking at a window half in each.
    private func languageChanged() {
        mainMenu.install()
        let wasOpen = settingsWindow?.window?.isVisible == true
        settingsWindow?.close()
        settingsWindow = nil
        if wasOpen { DispatchQueue.main.async { [weak self] in self?.openSettingsWindow() } }
    }

    /// Decision 16's window, replacing the settings *file* the menu item used to open.
    ///
    /// That substitute was honest while there was no window — better than an item greyed out for a
    /// whole release — and it retires here rather than lingering as a second way to do the same job.
    func openSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings,
                // Before *Move Notes* moves anything, so what is on screen is written while the
                // buffer still points at a file that exists (decision 73).
                //
                // And *waited for*. `flush` enqueues on the vault queue and returns; the two vault
                // re-points either side of this one get away with that because `setVault` is on
                // that same queue, so the enqueued write is ordered before it for free — which is
                // what their comments say. `moveNotes` is plain `FileManager` on the main thread
                // and joins no queue, so there the ordering has to be taken rather than inherited:
                // without the drain the files move first, the queued write then lands in the old
                // vault under a name no longer in it, `VaultIO.write` reads that as missing and
                // recreates it, and the old folder is left holding the newest text while the moved
                // copy is stale and the panel reloads showing the stale one.
                onWillMoveNotes: { [weak self] in
                    self?.panelController.flush(trigger: .noteSwitched)
                    self?.vault.drain()
                },
                onUpdateStatus: { [weak self] in self?.updates.record($0) },
                onSyncNow: { [weak self] in self?.gitSync.syncNow() }
            ) { [weak self] url in
                guard let self else { return }
                // Same as the hand-edited path above, and this is the one people actually use: the
                // Sync radio and "Notes folder" both land here, and *Move Notes* (decision 30) moves
                // the file the buffer is pointing at.
                self.panelController.flush(trigger: .noteSwitched)
                self.vault.setVault(url)
                self.vaultCoordinator.startWatching()
                self.panelController.openLastUsedNote()
                self.refreshMenuBar()
            }
        }
        settingsWindow?.syncStatusChanged(gitSync.status)
        settingsWindow?.present()
    }

    /// The Dock icon is off by default (Plume lives in the menu bar) and switches the activation
    /// policy at runtime rather than through `Info.plist`, so turning it on does not need a relaunch.
    private func applyDockIcon() {
        let wanted: NSApplication.ActivationPolicy = settings.value.showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    private func applyMenuBarIconVisibility() {
        if settings.value.showMenuBarIcon {
            if menuBar == nil { installMenuBarItem() }
        } else {
            menuBar = nil
        }
    }

    func willTerminate() {
        panelController?.stopDockSpaceDetection()
        // Decision 10's third immediate flush. Everything else is recoverable; unsaved text is not.
        panelController?.flush(trigger: .quitting)
        // And wait for it. Decision 10 lists quit as an immediate flush, but "immediate" only meant
        // "enqueued immediately" — see `VaultService.drain`. A draft note exists nowhere but in the
        // buffer until that write lands, which is what makes the difference load-bearing.
        vault?.drain()
        // After the drain, so the commit includes the text that was just written.
        gitSync.shutdown()
        state.save()
        vaultCoordinator.stopWatching()
    }

    /// Plume has no Dock icon by default, but if `showDockIcon` is on, clicking it should summon
    /// rather than do nothing.
    func reopened() {
        panelController?.summon()
    }

    // MARK: - Hotkey

    private func installHotkey() {
        hotkey = GlobalHotkey { [weak self] in self?.panelController.toggle() }

        guard hotkey.register(settings.value.summonHotkey) else {
            let combo = settings.value.summonHotkey.displayString
            NSLog("Plume: could not register %@ — another app already owns it", combo)

            // Not fatal, and not a modal on launch either: the menu bar item still summons the panel,
            // and an app that blocks the screen at login over a hotkey conflict is worse than one
            // you have to click once.
            menuBar?.rebuild(hotkey: settings.value.summonHotkey)
            return
        }
    }

    // MARK: - Git sync

    private func startGitSync() {
        gitSync.beforeCycle = { [weak self] in
            // What is on screen, on disk, before git reads the folder — and waited for, for the
            // reason `onWillMoveNotes` waits: `flush` only enqueues.
            self?.panelController.flush(trigger: .reloadPending)
            self?.vault.drain()
        }
        gitSync.onStatusChange = { [weak self] status in
            self?.menuBar?.setSyncStatus(status)
            self?.settingsWindow?.syncStatusChanged(status)
        }
        gitSync.configure(with: settings.value)
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        guard settings.value.showMenuBarIcon else { return }

        menuBar = MenuBarController(hotkey: settings.value.summonHotkey)
        menuBar.pinnedNotes = { [weak self] in self?.pinnedNotes() ?? [] }
        menuBar.onShow = { [weak self] in self?.panelController.summon() }
        menuBar.onNewNote = { [weak self] in
            self?.panelController.summon()
            self?.panelController.createNote(title: "")
        }
        menuBar.onBrowse = { [weak self] in self?.panelController.openSwitcher() }
        menuBar.onActions = { [weak self] in self?.panelController.openActions() }
        menuBar.onSettings = { [weak self] in self?.openSettingsWindow() }
        menuBar.onOpenRelease = { NSWorkspace.shared.open(ReleaseFetcher.releasePage(for: $0)) }
        menuBar.onSyncNow = { [weak self] in self?.gitSync.syncNow() }
        menuBar.onOpenSyncSettings = { [weak self] in
            self?.openSettingsWindow()
            self?.settingsWindow?.showStorage()
        }
        menuBar.noteTitle = { [weak self] in self?.titles[$0] }
        menuBar.onOpenConflict = { [weak self] file in
            guard let self else { return }
            if NoteFilename.isNoteFile(file) {
                self.panelController.summon()
                self.panelController.open(file)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([self.settings.value.vaultURL.appendingPathComponent(file)])
            }
        }
        menuBar.setSyncStatus(gitSync.status)
        // An item installed after a check has already run — the icon can be switched back on in
        // Settings — starts out knowing what the last check found.
        menuBar.setUpdateAvailable(updates.latestAvailableVersion)
        // Summon first: the pinned section exists so a pinned note is one click away from anywhere,
        // and opening one into a panel that is still offscreen would be a click that does nothing.
        menuBar.onOpenNote = { [weak self] filename in
            self?.panelController.summon()
            self?.panelController.open(filename)
        }
    }

    /// Note titles by filename, kept warm for the menu bar.
    ///
    /// The menu builds synchronously when it opens, and a title is the first line of a file — so it
    /// has to already be here. Refreshed whenever the vault changes, which is also the only time it
    /// can go stale.
    private var titles: [String: String] = [:]

    private func refreshMenuBar() {
        vault.titles { [weak self] titles in
            guard let self else { return }
            self.titles = titles
            self.menuBar?.rebuild(hotkey: self.settings.value.summonHotkey)
        }
    }

    private func pinnedNotes() -> [(filename: String, title: String)] {
        state.value.notes
            .filter(\.value.isPinned)
            .sorted { ($0.value.lastOpened ?? .distantPast) > ($1.value.lastOpened ?? .distantPast) }
            .map { (filename: $0.key, title: titles[$0.key] ?? "") }
    }

    // MARK: - Login item

    private func applyLaunchAtLogin() {
        guard BuildProfile.current.allowsSystemIntegration else { return }
        do {
            switch (settings.value.launchAtLogin, SMAppService.mainApp.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                break
            case (true, _):
                try SMAppService.mainApp.register()
            case (false, _):
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Plume: could not update the login item — %@", String(describing: error))
        }
    }
}
