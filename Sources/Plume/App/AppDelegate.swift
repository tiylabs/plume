import AppKit
import PlumeKit
import ServiceManagement

/// Wires the app together and owns everything with a process lifetime.
///
/// Deliberately thin. The panel knows how to be a panel, the vault service knows how to touch files,
/// and this type knows only the order things have to happen in on launch — which is the one piece of
/// logic that genuinely belongs to "the application" rather than to any part of it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = SettingsStore()
    private let state = StateStore()

    private var vault: VaultService!
    private var panelController: PanelController!
    private var menuBar: MenuBarController!
    private var hotkey: GlobalHotkey!
    private var watcher: VaultWatcher?
    private let gitSync = GitSyncController()
    private var settingsWindow: SettingsWindowController?

    /// Where `vault` is currently pointed, so a settings change can tell a vault move from any other
    /// edit. Read back from the service instead would mean hopping onto its queue to answer a
    /// question the main actor already knows.
    private var currentVaultURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, before a single string is looked up: every menu, alert and the welcome note below
        // reads the catalog, and `settings` is already loaded (it is a stored property).
        Localizer.start(preference: settings.value.language)

        installMainMenu()
        applyDockIcon()

        // Decision 13, and the order matters: the vault has to be resolved before anything tries to
        // read a note out of it, and "create it" is only ever allowed to happen once.
        guard prepareVault() else { return }

        vault = VaultService(vault: settings.value.vaultURL)
        currentVaultURL = settings.value.vaultURL
        panelController = PanelController(vault: vault, state: state, settings: settings)
        panelController.onPinsChanged = { [weak self] in self?.refreshMenuBar() }
        panelController.onVaultMissing = { [weak self] in self?.handleVaultMissing() }
        panelController.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
        panelController.onSummoned = { [weak self] in self?.checkForUpdateIfDue() }

        installMenuBarItem()
        installHotkey()
        startWatching()
        applyLaunchAtLogin()
        startGitSync()

        settings.onChange = { [weak self] new in self?.settingsChanged(new) }
        // Decision 12's promise — "changing the hotkey is a one-line edit" — only holds if the edit
        // takes effect. The Settings window is the ordinary way in now, but the file is still there
        // and still documented, so it still has to work.
        settings.watchForHandEdits()

        pruneStateForMissingNotes()

        // Decision 20's retention, enforced at the only moment it can be: Plume is not running most
        // of the time, so there is no timer that could have fired. Launch is when the clock is read.
        vault.purgeDeleted(keepingDays: settings.value.recentlyDeletedDays)

        installPresetThemes()
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
    private func settingsChanged(_ new: Settings) {
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
            startWatching()
            panelController?.openLastUsedNote()
        }

        // Before anything below rebuilds UI, so it all comes out in the new language.
        if Localizer.apply(preference: new.language) { languageChanged() }

        if hotkey?.registered != new.summonHotkey { installHotkey() }
        applyMenuShortcuts()
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
        installMainMenu()
        let wasOpen = settingsWindow?.window?.isVisible == true
        settingsWindow?.close()
        settingsWindow = nil
        if wasOpen { DispatchQueue.main.async { [weak self] in self?.openSettingsWindow() } }
    }

    /// Decision 16's window, replacing the settings *file* the menu item used to open.
    ///
    /// That substitute was honest while there was no window — better than an item greyed out for a
    /// whole release — and it retires here rather than lingering as a second way to do the same job.
    private func openSettingsWindow() {
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
                onUpdateStatus: { [weak self] in self?.recordUpdateStatus($0) },
                onSyncNow: { [weak self] in self?.gitSync.syncNow() }
            ) { [weak self] url in
                guard let self else { return }
                // Same as the hand-edited path above, and this is the one people actually use: the
                // Sync radio and "Notes folder" both land here, and *Move Notes* (decision 30) moves
                // the file the buffer is pointing at.
                self.panelController.flush(trigger: .noteSwitched)
                self.vault.setVault(url)
                self.startWatching()
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

    func applicationWillTerminate(_ notification: Notification) {
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
        watcher?.stop()
    }

    /// Plume has no Dock icon by default, but if `showDockIcon` is on, clicking it should summon
    /// rather than do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panelController?.summon()
        return true
    }

    // MARK: - Vault

    /// - Returns: false when the app cannot continue without the user choosing a folder, in which
    ///   case the chooser has been put on screen and launch resumes from its completion.
    private func prepareVault() -> Bool {
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
                presentVaultChooser(
                    message: tr("vault.createFailed", ["path": url.path]),
                    detail: error.localizedDescription
                )
                return false
            }

        case .vaultMissing(let missing):
            presentVaultChooser(
                message: tr("vault.missing.title"),
                detail: tr("vault.missing.detail", ["path": missing.path])
            )
            return false

        case .pathIsNotADirectory(let path):
            presentVaultChooser(
                message: tr("vault.notFolder.title"),
                detail: tr("vault.notFolder.detail", ["path": path.path])
            )
            return false
        }
    }

    private func handleVaultMissing() {
        guard case .vaultMissing = VaultLifecycle.situation(
            vault: settings.value.vaultURL,
            everCreated: state.value.vaultEverCreated
        ) else { return }

        presentVaultChooser(
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
    private func presentVaultChooser(message: String, detail: String) {
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

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("folderPanel.prompt")
        panel.message = tr("folderPanel.message")

        guard PanelWindow.steppingAside({ panel.runModal() }) == .OK, let chosen = panel.url else {
            presentVaultChooser(message: message, detail: detail)
            return
        }

        settings.update { $0.vaultPath = chosen.path }
        state.update { $0.vaultEverCreated = true }

        if vault == nil {
            applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        } else {
            vault.setVault(chosen)
            startWatching()
            panelController.openLastUsedNote()
        }
    }

    private func startWatching() {
        watcher?.stop()
        // Captured once, outside the `@Sendable` handler: that handler runs on the watcher's queue and
        // hands `self` to the main queue twice, which Swift 6.2's region checker rejects when each
        // hop captures `self` separately. The delegate lives for the process (see `main.swift`).
        let box = WeakDelegate(self)
        let watcher = VaultWatcher { paths in
            // Git's own bookkeeping is not the notes changing; counting it would have every sync
            // cycle look like somebody typing.
            if paths.contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.value?.gitSync.vaultDidChange() }
                }
            }
            let names = VaultWatcher.noteFilenames(in: paths)
            guard !names.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.panelController?.vaultChanged(filenames: names)
                    box.value?.refreshMenuBar()
                }
            }
        }
        watcher.start(watching: settings.value.vaultURL)
        self.watcher = watcher
    }

    /// Drops caret offsets and pins for notes that are no longer in the vault.
    ///
    /// Only ever from a listing that succeeded, and never for a note that is merely evicted —
    /// `AppState.forgetNotes` documents why: a slow sync is not a deletion.
    private func pruneStateForMissingNotes() {
        vault.present { [weak self] present in
            guard let self, !present.isEmpty else { return }
            self.state.update { $0.forgetNotes(missingFrom: present) }
            self.refreshMenuBar()
        }
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
        menuBar.onOpenRelease = { NSWorkspace.shared.open(UpdateChecker.releasePage(for: $0)) }
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
        menuBar.setUpdateAvailable(latestAvailableVersion)
        // Summon first: the pinned section exists so a pinned note is one click away from anywhere,
        // and opening one into a panel that is still offscreen would be a click that does nothing.
        menuBar.onOpenNote = { [weak self] filename in
            self?.panelController.summon()
            self?.panelController.open(filename)
        }
    }

    // MARK: - Updates

    /// The newer version the last check found, re-derived from `state.json` on the way out.
    ///
    /// **Persisted, and compared again here.** Held only in memory it vanished on relaunch and the
    /// menu bar item — the half that is supposed to wait — did not come back until the next daily
    /// check, up to a day later. Re-comparing rather than trusting the stored string is what makes
    /// upgrading clear it immediately: the file still says `v0.6.6` on the first launch of v0.6.6,
    /// and `ReleaseCheck.pending` answers nil, so nothing is shown.
    private var latestAvailableVersion: String? {
        guard BuildProfile.current.allowsSystemIntegration else { return nil }
        return ReleaseCheck.pending(
            remembered: state.value.availableUpdate, running: UpdateChecker.runningVersion
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
    private func checkForUpdateIfDue() {
        guard BuildProfile.current.allowsSystemIntegration else { return }
        guard ReleaseCheck.shouldCheck(
            enabled: settings.value.checkForUpdates,
            lastChecked: state.value.lastUpdateCheck
        ) else { return }

        // Stamped before the request rather than after it, so a machine that is offline all week
        // asks once a day rather than on every summon.
        state.update { $0.lastUpdateCheck = Date() }

        UpdateChecker.fetchStatus { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recordUpdateStatus(status)
                    self.announceUpdate()
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
    private func recordUpdateStatus(_ status: ReleaseCheck.Status) {
        // `$0` inside the block, never `state.value`: reading the store during `state.update` is a
        // simultaneous access to storage already held for modification, and Swift traps the
        // process (decision 124, found by pressing the word count once).
        state.update {
            $0.availableUpdate = ReleaseCheck.remembered(after: status, previously: $0.availableUpdate)
            $0.lastUpdateCheck = Date()
        }
        menuBar?.setUpdateAvailable(latestAvailableVersion)
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
    private func announceUpdate() {
        guard let version = latestAvailableVersion, panelController.isVisible else { return }
        panelController.showToast(tr("update.toast", ["version": version]), dwell: PanelController.newsDwell)
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

    // MARK: - Main menu

    /// An accessory app never shows a menu bar, but `NSApp.mainMenu` is still what routes ⌘C, ⌘V and
    /// ⌘Z to the first responder. Without this the panel would be a text editor you cannot paste into.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: tr("menu.settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: tr("menu.file"))
        newNoteItem = fileMenu.addItem(withTitle: tr("menu.newNote"), action: #selector(newNote), keyEquivalent: "")
        newNoteItem?.target = self
        browseNotesItem = fileMenu.addItem(withTitle: tr("menu.browseNotes"), action: #selector(browseNotes), keyEquivalent: "")
        browseNotesItem?.target = self
        applyMenuShortcuts()
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: tr("menu.closePanel"), action: #selector(closePanel), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("menu.edit"))
        editMenu.addItem(withTitle: tr("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: tr("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// The two File-menu items whose keys are rebindable. See `applyMenuShortcuts`.
    private var newNoteItem: NSMenuItem?
    private var browseNotesItem: NSMenuItem?

    /// Points the File menu at whatever New Note and Browse Notes are actually bound to.
    ///
    /// These were `keyEquivalent: "n"` and `"p"`, spelled here and nowhere near
    /// `Settings.shortcutActions` — so they were the two rebindable actions that could not be
    /// rebound. Recording a new key in the Shortcuts tab moved the editor's binding and left the
    /// menu holding ⌘N, which means the old key kept working and the recorder could not free it.
    /// Exactly the class of defect decisions 47 and 49 are about: a key printed in one place and
    /// meaning something else in another.
    private func applyMenuShortcuts() {
        let map: [(NSMenuItem?, String)] = [
            (newNoteItem, "newNote"),
            (browseNotesItem, "browseNotes"),
        ]
        for (item, action) in map {
            guard let item else { continue }
            guard let combo = Settings.menuKeyEquivalent(for: settings.value.shortcut(action)) else {
                // A binding this cannot express — the item keeps its title and loses its key rather
                // than advertising one it does not have.
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                continue
            }
            item.keyEquivalent = combo.key
            var mask: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.command) { mask.insert(.command) }
            if combo.modifiers.contains(.shift) { mask.insert(.shift) }
            if combo.modifiers.contains(.option) { mask.insert(.option) }
            if combo.modifiers.contains(.control) { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
    }

    @objc private func newNote() {
        panelController?.summon()
        panelController?.createNote(title: "")
    }

    @objc private func browseNotes() {
        panelController?.openSwitcher()
    }

    @objc private func closePanel() {
        panelController?.dismiss()
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }
}

/// A weak reference that may cross into the watcher's `@Sendable` handler. It is only ever read inside
/// `MainActor.assumeIsolated`, on the main queue, which is where the delegate lives.
private final class WeakDelegate: @unchecked Sendable {
    weak var value: AppDelegate?
    init(_ value: AppDelegate) { self.value = value }
}
