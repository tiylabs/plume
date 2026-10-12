import AppKit
import PlumeKit

/// Design frame 2c — the General tab.
///
/// Everything here is about how Plume behaves before you have typed anything: how you summon it, how
/// it goes away, and whether it announces itself in the menu bar and the Dock.
///
/// One thing the frame draws that this tab does not: "Notes folder". Turn 2 put it here, and Turn 3
/// then added a whole Storage tab that opens with the same control. Two Change… buttons onto the
/// same open panel is a duplicate rather than a convenience, so it lives in Storage — the tab named
/// after it — and this tab ends at the Dock.
@MainActor
final class GeneralSettingsViewController: NSViewController {

    private let settings: SettingsStore
    private var recorder: HotkeyRecorderView!
    private var noteOrder: NSPopUpButton!
    private var languagePopUp: NSPopUpButton!
    private var dismissPopUp: NSPopUpButton!

    /// "System default" first, then every language found in `Locales/`, each in its own script.
    /// Built from `L10n.availableLanguages`, so a new language directory appears here with no edit.
    private var languageChoices: [String] {
        [L10n.systemPreference] + L10n.availableLanguages.map(\.code)
    }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.tab.general")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let form = SettingsForm()
        let current = settings.value

        // ---- language ----------------------------------------------------------------------
        // First, and in a card of its own: it is the row you most need to be able to find when the
        // window is in a language you cannot read. Language names are never translated — each is
        // written in its own script for exactly that reason.
        languagePopUp = SettingsForm.popUp(
            [tr("general.language.system")] + L10n.availableLanguages.map(\.name),
            target: self,
            action: #selector(languageChanged)
        )
        languagePopUp.selectItem(at: languageChoices.firstIndex(of: current.language) ?? 0)
        form.card([SettingsRow(title: tr("general.language"), control: languagePopUp)])

        // ---- summon and dismiss ------------------------------------------------------------
        recorder = HotkeyRecorderView(hotkey: current.summonHotkey)
        recorder.onRecord = { [weak self] hotkey in
            self?.settings.update { $0.summonHotkey = hotkey }
        }

        // Two choices of one setting, so a pop-up row like every other choice in the window rather
        // than the only radio group in it.
        dismissPopUp = SettingsForm.popUp(
            [tr("general.dismiss.toggle"), tr("general.dismiss.escape")],
            target: self,
            action: #selector(dismissModeChanged)
        )
        dismissPopUp.selectItem(at: current.dismissMode == .sameHotkeyToggles ? 0 : 1)

        form.card([
            SettingsRow(title: tr("general.summonHotkey"), control: recorder),
            SettingsRow(title: tr("general.dismiss"), control: dismissPopUp),
        ])

        // ---- behaviour ---------------------------------------------------------------------
        // No Spaces row. `spaceAssignment` is a ⌘K row (decision 93) and ⌘K is where the panel's
        // own toggles live — the format bar, auto-sizing and hiding from screen capture all persist
        // to `settings.json` exactly the same way and none of them has a row here.
        let login = SettingsForm.toggle(
            current.launchAtLogin, target: self, action: #selector(launchAtLoginChanged)
        )
        login.isEnabled = BuildProfile.current.allowsSystemIntegration
        let menuBar = SettingsForm.toggle(
            current.showMenuBarIcon, target: self, action: #selector(showMenuBarIconChanged)
        )
        let dock = SettingsForm.toggle(
            current.showDockIcon, target: self, action: #selector(showDockIconChanged)
        )

        // The switch on the **network call**, not on the notice — which is why it is a row at all.
        // Decision 126 says a setting whose control already lives in ⌘K does not get a second
        // entrance here; this one has no other entrance, and it is the only thing in Plume that
        // talks to the network (decisions 94, 136). Somebody who wants an app that makes no
        // requests should be able to have one without editing JSON.
        let updates = SettingsForm.toggle(
            current.checkForUpdates, target: self, action: #selector(checkForUpdatesChanged)
        )

        updates.isEnabled = BuildProfile.current.allowsSystemIntegration

        // Behaviour, not appearance, so it is here rather than in Appearance: it changes which note
        // ⌘P puts under your finger, which is the same kind of question as how the panel is dismissed.
        noteOrder = SettingsForm.popUp(
            Settings.NoteOrder.allCases.map(\.label), target: self, action: #selector(noteOrderChanged)
        )
        noteOrder.selectItem(at: Settings.NoteOrder.allCases.firstIndex(of: current.noteOrder) ?? 0)

        form.card([
            SettingsRow(title: tr("general.startAtLogin"), control: login),
            SettingsRow(title: tr("general.showMenuBarIcon"), control: menuBar),
            SettingsRow(title: tr("general.showDockIcon"), control: dock),
            SettingsRow(title: tr("general.checkUpdates"), control: updates),
            SettingsRow(title: tr("general.sortNotes"), control: noteOrder),
        ])

        view = form.makeContentView()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let choices = languageChoices
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < choices.count else { return }
        settings.update { $0.language = choices[sender.indexOfSelectedItem] }
    }

    @objc private func noteOrderChanged(_ sender: NSPopUpButton) {
        let cases = Settings.NoteOrder.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < cases.count else { return }
        settings.update { $0.noteOrder = cases[sender.indexOfSelectedItem] }
    }

    /// Keeps the recorder honest when the hotkey changed somewhere else — a hand edit to
    /// `settings.json` while this window is open, or Restore Defaults on the Shortcuts tab.
    func settingsChanged(_ new: Settings) {
        recorder?.setHotkey(new.summonHotkey)
        if let index = languageChoices.firstIndex(of: new.language) {
            languagePopUp?.selectItem(at: index)
        }
        dismissPopUp?.selectItem(at: new.dismissMode == .sameHotkeyToggles ? 0 : 1)
        if let index = Settings.NoteOrder.allCases.firstIndex(of: new.noteOrder) {
            noteOrder?.selectItem(at: index)
        }
    }

    // MARK: - Actions

    @objc private func dismissModeChanged(_ sender: NSPopUpButton) {
        settings.update {
            $0.dismissMode = sender.indexOfSelectedItem == 0 ? .sameHotkeyToggles : .escapeOnly
        }
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        settings.update { $0.launchAtLogin = sender.state == .on }
    }

    @objc private func checkForUpdatesChanged(_ sender: NSSwitch) {
        settings.update { $0.checkForUpdates = sender.state == .on }
    }

    @objc private func showMenuBarIconChanged(_ sender: NSSwitch) {
        settings.update { $0.showMenuBarIcon = sender.state == .on }
    }

    @objc private func showDockIconChanged(_ sender: NSSwitch) {
        settings.update { $0.showDockIcon = sender.state == .on }
    }
}
