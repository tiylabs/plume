import AppKit
import PlumeKit

/// Design frame 3c — the Shortcuts tab.
///
/// A plain table, which is the design's own point: every future feature adds a row, never a new
/// control style. Every row is a binding the web layer installs inside a panel.
///
/// **This tab answers "what would you want to change", not "what keys exist".** Conflating the two
/// took it to sixteen rows in one column, three of which nobody would ever touch: the summon hotkey
/// was here *and* on General — the same recorder twice — and ⌘F and ⌥⌘F mean find and replace in
/// every editor anyone has used. The line now lives in `Settings.fixedShortcuts`, which carries the
/// reasoning; what matters here is that a key being absent from this tab does not make it absent
/// from the app. Each one still prints itself in ⌘K or in the control's own tooltip, and every one
/// of those reads the binding in force rather than a literal.
///
/// The summon hotkey is deliberately **not** here any more. It is the one Carbon binding (decision
/// 9) and the one key that has to work while Plume is not frontmost, so it keeps its recorder — on
/// General, where it always also was.
///
/// The count is `Settings.shortcutActions.count`; don't restate it here without changing it there.
/// `NSTabViewController` gives each tab its own height, so shrinking this one does not disturb the
/// others.
///
/// The rule that governs this list has not moved: a recordable row that binds nothing is a worse lie
/// than an absent row, so a row appears here only when `Settings.shortcutActions` has an entry doing
/// something. Recently Deleted is the one ⌘K row with no entry, because the design gives it no
/// shortcut and a blank waiting to be filled in is the same lie in a different shape.
@MainActor
final class ShortcutsSettingsViewController: NSViewController {

    private let settings: SettingsStore
    private var panelRecorders: [(action: String, recorder: PlumeShortcutRecorderView)] = []

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.tab.shortcuts")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let form = SettingsForm()

        // A caption and a card per group, whenever the group changes. These are ⌘K's own groups, so
        // the two places that list the same actions agree about which belong together.
        var group: String?
        var rows: [NSView] = []
        func flush() {
            guard let group, !rows.isEmpty else { return }
            form.header(Settings.groupName(group))
            form.card(rows)
            rows = []
        }
        for action in Settings.shortcutActions {
            if action.group != group {
                flush()
                group = action.group
            }
            let recorder = PlumeShortcutRecorderView(binding: settings.value.shortcut(action.key))
            recorder.onRecord = { [weak self] binding in
                self?.settings.update { $0.shortcuts[action.key] = binding }
            }
            panelRecorders.append((action.key, recorder))
            rows.append(SettingsRow(title: Settings.label(of: action.key), control: recorder))
        }
        flush()

        // No "click a shortcut to re-record it" caption. The rows are obviously buttons and they say
        // "Click to record" the moment one is focused.
        form.trailing(
            SettingsForm.push(tr("shortcuts.restore"), target: self, action: #selector(restoreDefaults))
        )

        // This is the one tab that does not fit the window every other tab wants, so the window is
        // sized by the others (see `SettingsWindowController`) and this one scrolls inside it. The
        // content hugs vertically: the rows must stay their own height rather than sharing out
        // whatever the scroll view has.
        let container = form.makeContentView()
        let scroll = NSScrollView()
        // AppKit uses the scroll view's background for the toolbar's scroll-edge appearance.
        // Match the other tabs' window background rather than leaving this page transparent.
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = container
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])

        view = scroll
    }

    func settingsChanged(_ new: Settings) {
        for entry in panelRecorders {
            entry.recorder.setBinding(new.shortcut(entry.action))
        }
    }

    /// Restores every binding this tab can record — and the summon hotkey with them.
    ///
    /// The summon row moved to General, but "Restore Defaults" still resets it: this button means
    /// "put my keys back", and leaving one recorded combination behind because its recorder now
    /// lives on another tab would be a surprise rather than a distinction.
    @objc private func restoreDefaults() {
        settings.update {
            $0.summonHotkey = .defaultSummon
            $0.shortcuts = Settings.standardShortcuts
        }
        settingsChanged(settings.value)
    }
}

/// The same recorder, for a shortcut that is a CodeMirror binding rather than a Carbon hotkey.
///
/// Separate from `HotkeyRecorderView` because the two produce different things and validate
/// differently: a global hotkey must carry a modifier or it would swallow that key system-wide, while
/// an in-panel binding must carry one for a much smaller reason — it lives in a text editor, so an
/// unmodified key is a character somebody wanted to type.
@MainActor
final class PlumeShortcutRecorderView: HotkeyRecorderViewBase {

    var onRecord: ((String) -> Void)?

    private var binding: String

    init(binding: String) {
        self.binding = binding
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setBinding(_ binding: String) {
        self.binding = binding
        needsDisplay = true
    }

    override var displayText: String { Self.symbols(for: binding) }

    override func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Mod") }
        guard !parts.isEmpty else { return false }

        guard let key = Self.bindingKey(for: keyCode) else { return false }
        parts.append(key)

        binding = parts.joined(separator: "-")
        onRecord?(binding)
        return true
    }

    /// CodeMirror names keys by `KeyboardEvent.key`, so this maps the hardware code to that name.
    private static func bindingKey(for keyCode: UInt16) -> String? {
        KeyCode.bindingName(for: UInt32(keyCode))
    }

    /// Renders `"Shift-Mod-p"` as `⇧⌘P`, in Apple's display order rather than the binding's.
    static func symbols(for binding: String) -> String {
        var pieces = binding.split(separator: "-").map(String.init)
        guard let key = pieces.popLast() else { return "" }

        let held = Set(pieces)
        var s = ""
        if held.contains("Ctrl") { s += "⌃" }
        if held.contains("Alt") { s += "⌥" }
        if held.contains("Shift") { s += "⇧" }
        if held.contains("Mod") || held.contains("Cmd") { s += "⌘" }
        return s + (key.count == 1 ? key.uppercased() : key)
    }
}
