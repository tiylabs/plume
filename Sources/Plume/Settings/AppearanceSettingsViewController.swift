import AppKit
import PlumeKit

/// Design frame 3b — the Appearance tab.
///
/// Decision 19 is what makes the theme row worth building: **a theme is a CSS file in a folder.** The
/// dropdown lists whatever is in the themes folder, so Typora-style theming arrives with no new UI
/// and no new code whenever somebody drops a stylesheet in there. That is the entire mechanism.
@MainActor
final class AppearanceSettingsViewController: NSViewController {

    private let settings: SettingsStore

    private var appearanceControl: NSSegmentedControl!
    private var swatches: [AccentSwatchButton] = []
    private var themePopUp: NSPopUpButton!
    private var sizeField: NSTextField!
    private var transparencySlider: NSSlider!
    private var transparencyField: NSTextField!

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.tab.appearance")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static let appearances: [Settings.Appearance] = [.system, .light, .dark]

    override func loadView() {
        let form = SettingsForm()
        let current = settings.value

        // ---- light / dark ------------------------------------------------------------------
        appearanceControl = NSSegmentedControl(
            labels: [tr("appearance.system"), tr("appearance.light"), tr("appearance.dark")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(appearanceChanged)
        )
        appearanceControl.selectedSegment =
            Self.appearances.firstIndex(of: current.appearance) ?? 0

        // ---- accent ------------------------------------------------------------------------
        swatches = Settings.accentOptions.map { option in
            let swatch = AccentSwatchButton(
                hex: option.hex, darkHex: option.darkHex, name: Settings.accentName(option.id)
            )
            swatch.target = self
            swatch.action = #selector(accentChanged(_:))
            return swatch
        }
        let swatchRow = NSStackView(views: swatches)
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 8

        // ---- panel transparency -------------------------------------------------------------
        transparencySlider = NSSlider(
            value: Settings.transparencySliderValue(forOpacity: current.panelOpacity), minValue: 0, maxValue: 100,
            target: self, action: #selector(transparencyChanged)
        )
        transparencySlider.isContinuous = true
        transparencySlider.controlSize = .small
        transparencySlider.setAccessibilityLabel(tr("appearance.transparency"))
        transparencySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        transparencyField = NSTextField(labelWithString: "")
        transparencyField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        transparencyField.alignment = .right
        transparencyField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let transparencyControl = NSStackView(views: [transparencySlider, transparencyField])
        transparencyControl.orientation = .horizontal
        transparencyControl.spacing = 8

        form.header(tr("appearance.group.look"))
        form.card([
            SettingsRow(title: tr("appearance.appearance"), control: appearanceControl),
            SettingsRow(title: tr("appearance.accent"), control: swatchRow),
            SettingsRow(title: tr("appearance.transparency"), control: transparencyControl),
        ])

        // ---- markdown theme ----------------------------------------------------------------
        themePopUp = SettingsForm.popUp([], target: self, action: #selector(themeChanged))
        // No ellipsis: it opens the folder in the Finder and that is the whole action. An ellipsis
        // promises that something will be asked of you before the command completes — a name, a
        // file, a choice you can still back out of — and nothing is asked here. Every other one in
        // Plume earns it: Browse Notes… and Actions… ask which, Rename File… asks for a name,
        // Export… and Choose Folder… put up a panel, and Settings… is Apple's own convention.
        let openThemes = SettingsForm.push(
            tr("appearance.theme.open"), target: self, action: #selector(openThemesFolder)
        )

        // ---- text size ---------------------------------------------------------------------
        let stepper = NSStepper()
        stepper.minValue = 10
        stepper.maxValue = 32
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = Int(current.textSize)
        stepper.target = self
        stepper.action = #selector(textSizeChanged)

        // Monospaced digits and a fixed width: "9 px" → "10 px" must not nudge the stepper sideways.
        sizeField = NSTextField(labelWithString: "\(Int(current.textSize)) px")
        sizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeField.alignment = .right
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let sizeControl = NSStackView(views: [sizeField, stepper])
        sizeControl.orientation = .horizontal
        sizeControl.spacing = 6

        form.header(tr("appearance.group.markdown"))
        form.card([
            // Dropdown, then the way to add one; the sentence explaining what a theme is sits under
            // the title, where the explanation of every row lives.
            SettingsRow(
                title: tr("appearance.theme"),
                explanation: tr("appearance.theme.note"),
                control: themePopUp
            ),
            SettingsRow(title: tr("appearance.theme.folder"), control: openThemes),
            SettingsRow(
                title: tr("appearance.textSize"),
                explanation: tr("appearance.textSize.hint"),
                control: sizeControl
            ),
        ])

        view = form.makeContentView()
        reloadThemes()
        refresh(current)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Someone may have dropped a CSS file in since the window was last opened, and the folder is
        // the entire interface for adding one.
        reloadThemes()
    }

    func settingsChanged(_ new: Settings) {
        refresh(new)
    }

    private func refresh(_ current: Settings) {
        appearanceControl?.selectedSegment = Self.appearances.firstIndex(of: current.appearance) ?? 0
        let accent = Settings.accentColours(for: current.accent).light
        for swatch in swatches { swatch.isChosen = swatch.hex == accent }
        sizeField?.stringValue = "\(Int(current.textSize)) px"
        let transparency = Settings.transparencySliderValue(forOpacity: current.panelOpacity).rounded()
        transparencySlider?.doubleValue = transparency
        transparencyField?.stringValue = "\(Int(transparency))%"
        selectTheme(current.markdownTheme)
    }

    // MARK: - Themes

    private var themeFiles: [String] = []

    private func reloadThemes() {
        let folder = settings.themesFolder
        themeFiles = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".css") && !$0.hasPrefix(".") }
            .sorted()

        themePopUp?.removeAllItems()
        // "Default", not "Plume Default". Every item in this window is Plume's; saying so on one of
        // them is the app naming itself inside its own settings.
        themePopUp?.addItem(withTitle: tr("appearance.theme.default"))
        for file in themeFiles {
            themePopUp?.addItem(withTitle: (file as NSString).deletingPathExtension)
        }
        selectTheme(settings.value.markdownTheme)
    }

    private func selectTheme(_ filename: String) {
        guard let index = themeFiles.firstIndex(of: filename) else {
            themePopUp?.selectItem(at: 0)
            return
        }
        themePopUp?.selectItem(at: index + 1)
    }

    @objc private func openThemesFolder() {
        let folder = settings.themesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Actions

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        let choice = Self.appearances[sender.selectedSegment]
        settings.update { $0.appearance = choice }
    }

    @objc private func accentChanged(_ sender: AccentSwatchButton) {
        settings.update { $0.accent = sender.hex }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let file = index == 0 ? "" : themeFiles[index - 1]
        settings.update { $0.markdownTheme = file }
    }

    @objc private func textSizeChanged(_ sender: NSStepper) {
        settings.update { $0.textSize = Double(sender.integerValue) }
    }

    @objc private func transparencyChanged(_ sender: NSSlider) {
        let transparency = sender.doubleValue.rounded()
        sender.doubleValue = transparency
        transparencyField.stringValue = "\(Int(transparency))%"
        settings.update { $0.panelOpacity = Settings.opacity(forTransparencySliderValue: transparency) }
    }
}
