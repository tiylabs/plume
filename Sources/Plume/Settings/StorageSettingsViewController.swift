import AppKit
import PlumeKit

/// Design frame 3a — the Storage tab.
///
/// Decision 21 is the load-bearing part: **Off and iCloud Drive pick where the vault lives, not a
/// protocol.** Both are folder locations, and no server, account or sync code stands behind either.
///
/// **Git repository is the exception, and the first row with an engine behind it.** It does not move
/// the vault: the notes folder *becomes* the working tree and `origin` is the address typed here (see
/// `GitSyncEngine`). That is a reversal of decision 7's "no sync code ships", made deliberately and
/// guarded three ways: it is off until someone verifies an address and presses *Enable Sync*, it
/// holds no credentials of its own (the system `git` and its keys do the authenticating), and it
/// refuses to start inside iCloud Drive, which would sync `.git` out from under itself.
///
/// Selecting an iCloud row still has to actually move the vault, and that is the one genuinely
/// destructive thing in this window. It goes through a confirmation that names both paths and says
/// what happens to the notes, in the same posture as decision 27: at a filesystem moment, use the
/// system's own chrome and tell the truth.
@MainActor
final class StorageSettingsViewController: NSViewController {

    private let settings: SettingsStore

    /// Called when the vault location changed, so the app can re-point the watcher and the index.
    var onVaultChanged: ((URL) -> Void)?

    /// Called immediately before *Move Notes* touches a file, so the buffer can be written while it
    /// still knows where it lives. See `adopt`.
    var onWillMoveNotes: (() -> Void)?

    /// Called for *Sync Now*.
    var onSyncNow: (() -> Void)?

    /// Called with the height this tab needs whenever it changes — which is when the Git rows appear
    /// or a longer verification result arrives. The window is one size for every tab (see
    /// `SettingsWindowController`), so this tab asks it to grow rather than being clipped.
    var onContentHeightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0

    private var pathField: NSTextField!
    private var syncPopUp: NSPopUpButton!
    private var syncRow: SettingsRow!

    // Git
    private var gitConfigCard: SettingsCard!
    private var gitInfoCard: SettingsCard!
    private var gitActions: NSView!
    private var addressField: NSTextField!
    private var branchField: NSTextField!
    private var infoRow: SettingsRow!
    private var verifyButton: NSButton!
    private var statusValue: NSTextField!
    private var enableButton: NSButton!
    private var syncNowButton: NSButton!
    private var stopButton: NSButton!

    /// The popup says Git although sync is not enabled yet — the person is filling in the address.
    /// Not persisted: until *Enable Sync*, choosing Git changes nothing about where the notes are.
    private var gitChosen = false
    private var verifying = false
    private var verificationText = ""
    /// What the last passing verification was for. Editing either field makes it stale, and *Enable
    /// Sync* needs it to match what is in the fields now.
    private var verifiedKey: String?
    private var syncStatus: GitSyncStatus?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.tab.storage")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Plume` — or `…/Plume-dev` in a debug build.
    ///
    /// Built from the literal container name rather than from `url(forUbiquityContainerIdentifier:)`,
    /// which decision 13 measured returning nil here: unsigned means no ubiquity entitlement. The
    /// folder is still perfectly writable — Plume is just a non-sandboxed app writing into a synced
    /// directory, which is the whole architecture.
    ///
    /// **The folder name comes from `BuildProfile`** (decision 133). It was a literal here, so this
    /// one control reached past decision 99's separation and offered to move a scratch vault into
    /// the daily one.
    static var iCloudDriveVault: URL {
        URL(fileURLWithPath: (BuildProfile.current.iCloudVaultPath as NSString).expandingTildeInPath)
    }

    static func isInICloudDrive(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/com~apple~CloudDocs/")
    }

    override func loadView() {
        let form = SettingsForm()
        let current = settings.value

        // ---- location ----------------------------------------------------------------------
        pathField = SettingsForm.pathField(current.vaultPath)
        let change = SettingsForm.push(tr("storage.change"), target: self, action: #selector(chooseFolder))
        let folderControl = NSStackView(views: [pathField, change])
        folderControl.orientation = .horizontal
        folderControl.spacing = 8
        // Fixed rather than a minimum: a field free to grow pushes Change… past the card edge.
        pathField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        form.card([
            SettingsRow(title: tr("storage.notesFolder"), control: folderControl),
            SettingsRow(title: tr("storage.format"), control: SettingsForm.value("Markdown (.md)")),
        ])

        // ---- sync --------------------------------------------------------------------------
        // A pop-up row, not a radio group: the choices are mutually exclusive and it keeps this card
        // the same shape as every other.
        syncPopUp = SettingsForm.popUp(
            [tr("storage.sync.off"), tr("storage.sync.icloud"), tr("storage.sync.git")],
            target: self,
            action: #selector(syncChanged)
        )
        syncRow = SettingsRow(title: tr("storage.sync"), control: syncPopUp)
        form.card([syncRow])

        // ---- git ---------------------------------------------------------------------------
        addressField = Self.textField(
            current.gitSync.remoteURL, placeholder: tr("storage.git.address.placeholder"), width: 250, owner: self
        )
        branchField = Self.textField(
            current.gitSync.branch, placeholder: tr("storage.git.branch.placeholder"), width: 150, owner: self
        )
        gitConfigCard = form.card([
            SettingsRow(title: tr("storage.git.address"), control: addressField),
            SettingsRow(title: tr("storage.git.branch"), control: branchField),
        ])

        verifyButton = SettingsForm.push(tr("storage.git.verify"), target: self, action: #selector(verify))
        statusValue = SettingsForm.value("")
        statusValue.lineBreakMode = .byTruncatingTail
        let infoControl = NSStackView(views: [verifyButton, statusValue])
        infoRow = SettingsRow(title: tr("storage.git.connection"), control: infoControl)
        gitInfoCard = form.card([infoRow])

        enableButton = SettingsForm.push(tr("storage.git.enable"), target: self, action: #selector(enableSync))
        enableButton.keyEquivalent = "\r"
        syncNowButton = SettingsForm.push(tr("storage.git.syncNow"), target: self, action: #selector(syncNowTapped))
        stopButton = SettingsForm.push(tr("storage.git.stop"), target: self, action: #selector(stopSync))
        // The explanation of how sync behaves lives in a tooltip on this glyph rather than in a
        // paragraph under the buttons: it is read once, and a paragraph is read every time.
        let info = NSImageView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: tr("storage.git.info"))
                ?? NSImage()
        )
        info.contentTintColor = .secondaryLabelColor
        info.toolTip = tr("storage.git.footnote")
        info.setAccessibilityLabel(tr("storage.git.info"))
        info.setAccessibilityHelp(tr("storage.git.footnote"))

        let buttons = NSStackView(views: [info, syncNowButton, stopButton, enableButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        gitActions = form.trailing(buttons)

        // ---- recently deleted --------------------------------------------------------------
        let retention = SettingsForm.popUp(
            Settings.recentlyDeletedOptions.map { tr("storage.keepDays", ["days": String($0)]) },
            target: self,
            action: #selector(retentionChanged)
        )
        retention.selectItem(
            at: Settings.recentlyDeletedOptions.firstIndex(of: current.recentlyDeletedDays) ?? 1
        )

        form.card([
            SettingsRow(title: tr("storage.recentlyDeleted"), control: retention),
        ])

        view = form.makeContentView()
        refresh(current)
    }

    // MARK: - Keeping "last synced" honest

    private var clock: Timer?

    /// "Last synced 3 minutes ago" is text computed from a date, and the date does not change between
    /// cycles — so with nothing else to prompt a redraw it said "now" for as long as the tab stayed
    /// open. A slow tick re-reads it while the tab is on screen, and stops when it is not.
    override func viewWillAppear() {
        super.viewWillAppear()
        refreshGit(settings.value)
        clock?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.value.gitSync.enabled else { return }
                self.refreshGit(self.settings.value)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        clock?.invalidate()
        clock = nil
    }

    func settingsChanged(_ new: Settings) {
        refresh(new)
    }

    private func refresh(_ current: Settings) {
        pathField?.stringValue = current.vaultPath
        let iCloud = Self.isInICloudDrive(current.vaultURL)
        let git = current.gitSync.enabled || gitChosen
        syncPopUp?.selectItem(at: git ? 2 : (iCloud ? 1 : 0))
        // The explanation only exists while there is something to say; hidden, it takes no height.
        syncRow?.explanationLabel.stringValue = iCloud && !git ? tr("storage.syncedNote") : ""
        syncRow?.explanationLabel.isHidden = !(iCloud && !git)
        refreshGit(current)
    }

    private func refreshGit(_ current: Settings) {
        guard gitConfigCard != nil else { return }
        let shown = current.gitSync.enabled || gitChosen
        let enabled = current.gitSync.enabled
        [gitConfigCard, gitInfoCard, gitActions].forEach { $0?.isHidden = !shown }

        if enabled {
            addressField.stringValue = current.gitSync.remoteURL
            branchField.stringValue = current.gitSync.branch
        }
        // Fixed while sync runs: changing the address of a live sync is stopping it and starting
        // another, and the buttons below say so.
        addressField.isEnabled = !enabled
        branchField.isEnabled = !enabled

        verifyButton.isHidden = enabled
        verifyButton.isEnabled = !verifying
        verifyButton.title = verifying ? tr("storage.git.verifying") : tr("storage.git.verify")
        statusValue.isHidden = !enabled
        infoRow.titleLabel.stringValue = enabled ? tr("storage.git.status") : tr("storage.git.connection")

        let detail: String
        if enabled {
            let status = syncStatus ?? .idle(lastSync: nil)
            statusValue.stringValue = GitSyncWording.headline(status)
            detail = GitSyncWording.detail(status)
        } else {
            detail = verificationText.isEmpty ? tr("storage.git.verify.hint") : verificationText
        }
        infoRow.explanationLabel.stringValue = detail
        infoRow.explanationLabel.isHidden = detail.isEmpty

        enableButton.isHidden = enabled
        enableButton.isEnabled = !verifying && verifiedKey != nil && verifiedKey == currentKey
        syncNowButton.isHidden = !enabled
        syncNowButton.isEnabled = syncStatus?.isSyncing != true
        stopButton.isHidden = !enabled

        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        if abs(height - reportedHeight) > 0.5 {
            reportedHeight = height
            onContentHeightChanged?(height)
        }
    }

    /// Pushed in by the app whenever the sync's status changes.
    func syncStatusChanged(_ status: GitSyncStatus?) {
        syncStatus = status
        refreshGit(settings.value)
    }

    // MARK: - Git

    private static func textField(
        _ value: String, placeholder: String, width: CGFloat, owner: NSTextFieldDelegate
    ) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = owner
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private var currentAddress: String { addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentBranch: String { branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentKey: String { currentAddress + "\n" + currentBranch }

    @objc private func verify() {
        guard !verifying else { return }
        let address = currentAddress, branch = currentBranch
        let key = currentKey
        verifying = true
        verifiedKey = nil
        verificationText = ""
        refreshGit(settings.value)

        // `GitRunner()` is built here, per press, so installing the Command Line Tools after being
        // told to — and pressing Verify again — works without relaunching.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitSyncValidation.run(address: address, branch: branch, runner: GitRunner())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.verifying = false
                    self.verificationText = Self.describe(result)
                    // Only if the fields still say what was checked.
                    self.verifiedKey = result.passed && key == self.currentKey ? key : nil
                    self.refreshGit(self.settings.value)
                }
            }
        }
    }

    /// One line per step, ✓ or ✗; a pass is just "Ready to sync" and the branch's own note.
    private static func describe(_ result: GitSyncValidation) -> String {
        if result.passed {
            let branch = result.entries.last?.detail ?? ""
            return [tr("storage.git.verified"), branch].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return result.entries.map { entry in
            (entry.passed ? "✓ " : "✗ ") + entry.step.label
                + (entry.detail.isEmpty ? "" : " — " + entry.detail)
        }.joined(separator: "\n")
    }

    @objc private func enableSync() {
        let address = currentAddress, branch = currentBranch
        guard verifiedKey == currentKey else { return }

        let vault = settings.value.vaultURL
        let alert = NSAlert()
        alert.messageText = tr("storage.git.enable.title", ["address": address])
        var detail = tr("storage.git.enable.detail", ["path": Self.tilde(vault)])
        let existing = GitSyncEngine(vault: vault, remoteURL: address, runner: GitRunner()).existingOrigin()
        if let existing, existing != address {
            detail += "\n\n" + tr("storage.git.enable.originChanges", ["old": existing])
        }
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("storage.git.enable"))
        alert.addButton(withTitle: tr("common.cancel"))
        guard PlumePanel.steppingAside({ alert.runModal() }) == .alertFirstButtonReturn else { return }

        settings.update { $0.gitSync = GitSyncSettings(enabled: true, remoteURL: address, branch: branch) }
        refresh(settings.value)
    }

    @objc private func stopSync() {
        guard confirmStop() else { return }
        settings.update { $0.gitSync.enabled = false }
        gitChosen = false
        verifiedKey = nil
        verificationText = ""
        refresh(settings.value)
    }

    @objc private func syncNowTapped() { onSyncNow?() }

    private func confirmStop() -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("storage.git.stop.title")
        alert.informativeText = tr("storage.git.stop.detail")
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("storage.git.stop"))
        alert.addButton(withTitle: tr("common.cancel"))
        return PlumePanel.steppingAside { alert.runModal() } == .alertFirstButtonReturn
    }

    // MARK: - Actions

    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        let days = Settings.recentlyDeletedOptions[sender.indexOfSelectedItem]
        settings.update { $0.recentlyDeletedDays = days }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("folderPanel.prompt")
        panel.message = tr("folderPanel.message")
        panel.directoryURL = settings.value.vaultURL

        guard PlumePanel.steppingAside({ panel.runModal() }) == .OK, let chosen = panel.url else { return }
        // Picking a folder by hand is a statement about where the notes already are, so nothing
        // moves — unlike the Sync radio, which is a statement about where they should be.
        adopt(chosen, movingNotes: false)
    }

    @objc private func syncChanged(_ sender: NSPopUpButton) {
        let choice = sender.indexOfSelectedItem
        let current = settings.value

        if choice == 2 {
            // The repository is the notes folder, and iCloud would sync `.git` itself.
            if Self.isInICloudDrive(current.vaultURL) {
                let alert = NSAlert()
                alert.messageText = tr("storage.git.icloud.title")
                alert.informativeText = tr("storage.git.icloud.detail")
                alert.alertStyle = .warning
                _ = PlumePanel.steppingAside { alert.runModal() }
                refresh(current)
                return
            }
            gitChosen = true
            refresh(current)
            return
        }

        if current.gitSync.enabled {
            guard confirmStop() else {
                refresh(current)
                return
            }
            settings.update { $0.gitSync.enabled = false }
            gitChosen = false
            // "Off" while syncing with Git means *stop syncing*, not "move my notes to the default
            // folder": the folder is wherever the repository was put, and it stays.
            if choice == 0 {
                refresh(settings.value)
                return
            }
        }
        gitChosen = false
        refresh(settings.value)

        let destination = choice == 1 ? Self.iCloudDriveVault
            : URL(fileURLWithPath: (Settings.defaultVaultPath as NSString).expandingTildeInPath)
        let source = settings.value.vaultURL

        guard destination.standardizedFileURL != source.standardizedFileURL else { return }

        let noteCount = (try? VaultIO.listNotes(in: source))?.count ?? 0

        // Decision 76, reaching the one modal it had not. This ran to three paragraphs, and the
        // third — "Nothing about this turns on a sync service. It only chooses which folder the
        // notes live in…" — was decision 21's *argument*, which belongs in the brief rather than in
        // front of somebody who has just clicked a radio button. The first paragraph restated the
        // title. What decision 30 actually requires is the source, the destination and the count,
        // and all three survive in one sentence each.
        let alert = NSAlert()
        alert.messageText = tr("storage.move.title", ["destination": Self.short(destination)])
        //
        // Only one of the two paths is spelled out, and it is the **source** — because that is the
        // one notes can be left behind in, and therefore the one you would have to go and find. The
        // destination is named in the title and was just chosen in a radio or an open panel. Spelled
        // out, `~/Library/Mobile Documents/com~apple~CloudDocs/Plume` took six of the alert's lines
        // on its own, which is most of what "too much to read" meant.
        alert.informativeText = noteCount == 0
            ? tr("storage.move.none", ["path": Self.tilde(destination)])
            : L10n.plural(
                "storage.move.some",
                count: noteCount,
                ["destination": Self.short(destination), "source": Self.tilde(source)]
            )
        alert.alertStyle = .informational
        if noteCount > 0 { alert.addButton(withTitle: tr("storage.move.move")) }
        // "Just Point There" was jargon for a thing the user was not thinking about — pointing. The
        // question on screen is what happens to the *notes*, so both answers are verbs about the
        // notes and the pair reads as one choice.
        alert.addButton(withTitle: noteCount > 0 ? tr("storage.move.leave") : tr("common.continue"))
        alert.addButton(withTitle: tr("common.cancel"))

        let response = PlumePanel.steppingAside { alert.runModal() }
        let cancel: NSApplication.ModalResponse = noteCount > 0 ? .alertThirdButtonReturn : .alertSecondButtonReturn
        guard response != cancel else {
            refresh(settings.value)  // put the pop-up back where it was
            return
        }

        adopt(destination, movingNotes: noteCount > 0 && response == .alertFirstButtonReturn)
    }

    // MARK: - Moving

    private func adopt(_ destination: URL, movingNotes: Bool) {
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
            if movingNotes {
                // Decision 56, reached from the one direction its amendment missed.
                //
                // The flush that protects this path is the one `settings.update` below triggers —
                // and it runs *after* the files have already moved, so it writes to the old vault
                // under a name that is no longer there, `VaultIO.write` reads that as "missing" and
                // recreates it, and you are left with a resurrected copy in the old folder holding
                // your newest text while the moved copy is stale.
                //
                // Flushing first is not quite the whole fix, and the gap survived a release
                // (decision 140): `flush` *enqueues* on the vault queue and returns, and the loop
                // below is `FileManager` on this thread, so the move overtook the write it was
                // meant to wait for and the fault above happened anyway. `onWillMoveNotes` drains
                // the queue as well as flushing it, which is what makes "first" true.
                onWillMoveNotes?()
                try moveNotes(from: settings.value.vaultURL, to: destination)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("storage.useFailed")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            _ = PlumePanel.steppingAside { alert.runModal() }
            refresh(settings.value)
            return
        }

        settings.update { $0.vaultPath = Self.tildified(destination) }
        onVaultChanged?(destination)
        refresh(settings.value)
    }

    /// Moves every `.md` file across, and stops at the first failure rather than continuing.
    ///
    /// A half-moved vault is recoverable — both folders are right there and every note is a plain
    /// file — but only if the move stops and says so. Carrying on past an error would scatter the
    /// notes across two folders and report success.
    private func moveNotes(from source: URL, to destination: URL) throws {
        for note in try VaultIO.listNotes(in: source) {
            let target = destination.appendingPathComponent(note.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                // Same filename on both sides. Frozen filenames (decision 2) make this a genuine
                // collision rather than a coincidence, so leave both alone and let the user look.
                continue
            }
            try FileManager.default.moveItem(at: note, to: target)
        }
    }

    private static func tildified(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func short(_ url: URL) -> String {
        isInICloudDrive(url) ? tr("storage.sync.icloud") : url.lastPathComponent
    }

    /// A path a person can read in a sentence. `/Users/colemei/Plume` is four words of noise before
    /// the one that matters.
    private static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

extension StorageSettingsViewController: NSTextFieldDelegate {
    /// Editing the address or branch makes the last verification stale.
    func controlTextDidChange(_ notification: Notification) {
        if verifiedKey != currentKey { verifiedKey = nil }
        if !verificationText.isEmpty && verifiedKey == nil { verificationText = "" }
        refreshGit(settings.value)
    }
}
