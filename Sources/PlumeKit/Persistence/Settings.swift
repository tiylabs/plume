import Foundation

/// The things the user chooses, as opposed to the things Plume remembers (`AppState`).
///
/// Kept in a separate `settings.json` because the two files have different owners. State is written
/// constantly by the app and is nobody's business to edit; settings are written rarely and are, per
/// decision 12, explicitly meant to be edited by hand.
///
/// That hand-editing is no longer a stand-in for missing UI. The hotkey recorder shipped (decision
/// 15) and so did the Settings window, and decision 32 promoted this file rather than retiring it:
/// it is a peer of the window, the only interface that survives a feature having no control yet, the
/// only one usable over SSH or from dotfiles — and it reloads live.
public struct Settings: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    // MARK: Storage

    /// Where the notes live. Stored with `~` intact so the file reads the way the user thinks about
    /// it, and so a vault under the home directory survives the account being renamed.
    public var vaultPath: String

    /// `~/Documents/Plume`, unless this is a scratch build — see `BuildProfile`, which is also why
    /// this is computed rather than a literal.
    public static var defaultVaultPath: String { BuildProfile.current.defaultVaultPath }

    public var vaultURL: URL {
        URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
    }

    /// How long a deleted note stays recoverable (decision 20). The Storage tab's control.
    ///
    /// This replaced `deleteAfterDays`, which was the opposite feature wearing the same shape: that
    /// one deleted notes for the crime of being old, which is the thing a notes app must never do to
    /// a thought you had four months ago. This one only ever counts from the moment you asked.
    public var recentlyDeletedDays: Int

    public static let recentlyDeletedOptions = [7, 30, 90]

    /// Syncing the notes folder through a Git remote. Off by default, and while it is off Plume makes
    /// no network request on its behalf — the only one it ever makes is the update check.
    public var gitSync: GitSyncSettings

    // MARK: Hotkey

    public var summonHotkey: Hotkey

    public enum DismissMode: String, Codable, Equatable, Sendable {
        /// The design's default: the summon hotkey toggles the panel away again.
        case sameHotkeyToggles
        /// For people who bind summon to something they also want to press while the panel is open.
        case escapeOnly
    }

    public var dismissMode: DismissMode

    // MARK: In-panel shortcuts

    /// The shortcuts that work inside a panel, keyed by action — design frame 3c's table.
    ///
    /// Only the summon hotkey is global (Carbon, `GlobalHotkey`); these are ordinary key bindings the
    /// web layer installs, so they are stored as CodeMirror binding strings — `"Mod-p"` — rather than
    /// as `Hotkey`, which exists to carry Carbon key codes.
    ///
    /// A dictionary rather than one field per action for the reason the design gives for the table
    /// being a plain table: every future feature adds a row, never a new control. Unknown keys are
    /// kept on load so a newer Plume's settings file survives a downgrade.
    public var shortcuts: [String: String]

    /// The rebindable in-panel shortcuts: action key, the binding Plume ships with, and the group
    /// heading the row sits under.
    ///
    /// Listed in the order the Shortcuts tab shows them, which is ⌘K's order, grouped the way ⌘K
    /// groups them. One list of rows sorted by nothing in particular is hard to look anything up in,
    /// and the panel had already settled what belongs beside what.
    ///
    /// **Only the actions that exist.** The one row still absent is Open in New Panel, which belongs
    /// to multi-panel; a recordable row that binds nothing is worse than an absent one. Adding one
    /// back is one entry here, which is what happened when the action panel and Find in Note landed.
    /// Most of these are also ⌘K rows, so the shortcut printed beside a row and the shortcut in this
    /// table are the same binding rather than two things that have to be kept in step.
    ///
    /// **Not every shortcut Plume has** — see `fixedShortcuts` for the rest, and the note there for
    /// where the line falls. This table is "what you might plausibly want to change", which is a
    /// different question from "what keys exist", and conflating the two is what took the tab to
    /// sixteen rows in one column.
    ///
    /// **These defaults are habit-compatible with Raycast Notes, and that is deliberate.** Raycast
    /// Notes is what Plume was built against and what its user is leaving, so every action both apps
    /// have carries the same key — checked row by row against Raycast's own ⌘K panel. Plume's extra
    /// rows sit on chords Raycast leaves free.
    ///
    /// So treat this table as frozen. A key here that reads better in isolation still costs a
    /// switcher their muscle memory, and a shortcut some *other* app has claimed system-wide is what
    /// the recorder is for — not a reason to move the shipped default.
    ///
    /// **`group` is a catalog key suffix, `label` is `shortcut.<key>`.** Names are looked up when the
    /// tab is drawn (`label(of:)`, `groupName(_:)`), not stored here, so switching language
    /// re-labels the rows instead of leaving them in the language the process started in.
    public static let shortcutActions:
        [(key: String, standard: String, group: String)] = [
            ("navigateBack", "Mod-[", "notes"),
            ("navigateForward", "Mod-]", "notes"),

            ("copyAsMarkdown", "Shift-Mod-c", "note"),
            ("revealInFinder", "Alt-Mod-r", "note"),
            ("exportNote", "Shift-Mod-e", "note"),
            ("deleteNote", "Ctrl-x", "note"),
            ("pinPlume", "Shift-Mod-p", "note"),

            ("autoSizing", "Shift-Mod-/", "panel"),
            ("formatBar", "Alt-Mod-,", "panel"),
            ("spaceBehaviour", "Alt-Mod-s", "panel"),
            ("hideFromCapture", "Shift-Mod-h", "panel"),
        ]

    /// The name a Shortcuts row shows for `key`, in the language in effect.
    public static func label(of key: String) -> String { L10n.t("shortcut.\(key)") }

    /// The heading above a group of Shortcuts rows.
    public static func groupName(_ group: String) -> String { L10n.t("shortcutGroup.\(group)") }

    /// Shortcuts that exist, work, and get no recorder row.
    ///
    /// **Two questions decide which table a key goes in, and neither of them is taste.**
    ///
    /// *Can it be taken from you?* Only a system-wide hotkey registration can — an ordinary
    /// shortcut in another app cannot reach Plume while the panel is key. And a plain ⌘+letter is
    /// essentially never registered globally, because doing so would break every text field on the
    /// machine. ⇧⌘ and ⌥⌘ combinations are exactly what utilities do claim: ⇧⌘E was dead for three
    /// releases here because a window manager held it, which is the whole argument for the recorder
    /// (decisions 15, 31) and the reason Export keeps its row.
    ///
    /// *Is there another way in?* If a key stops working and nothing else reaches the feature, the
    /// feature is gone. Every key below still prints itself somewhere the user looks: five of the
    /// six carry a ⌘K row, and Find and Replace carries the find bar's disclosure tooltip. **⌘[ and
    /// ⌘] deliberately have neither** (decision 51 gave them no ⌘K row), so the Shortcuts tab is
    /// their only home in the app and they stay above.
    ///
    /// Fixed means *no recorder*, not *impossible*: `settings.json` can still carry any of these,
    /// because decision 32 makes the file a peer of the window rather than a fallback for it. That
    /// costs nothing now that every printed key reads the binding in force rather than a literal.
    public static let fixedShortcuts: [(key: String, standard: String)] = [
        ("newNote", "Mod-n"),
        ("duplicateNote", "Mod-d"),
        ("browseNotes", "Mod-p"),
        ("findInNote", "Mod-f"),
        ("findReplace", "Alt-Mod-f"),
        ("actionPanel", "Mod-k"),
    ]

    /// Every shortcut Plume binds, recorder or not. What the defaults table, the ⌘K panel and the
    /// File menu all read — none of them cares which table a key came from.
    public static var allShortcuts: [(key: String, standard: String)] {
        shortcutActions.map { ($0.key, $0.standard) } + fixedShortcuts
    }

    public static var standardShortcuts: [String: String] {
        Dictionary(uniqueKeysWithValues: allShortcuts.map { ($0.key, $0.standard) })
    }

    /// The binding for `action`, falling back to what Plume ships with.
    public func shortcut(_ action: String) -> String {
        shortcuts[action] ?? Settings.standardShortcuts[action] ?? ""
    }

    /// A CodeMirror binding string as an `NSMenuItem` key equivalent.
    ///
    /// The File menu carries New Note and Browse Notes so that ⌘N and ⌘P still work while the
    /// Settings window is frontmost, and it used to spell their keys as literals — which made them
    /// the two rebindable actions that could not actually be rebound: the Shortcuts tab moved the
    /// editor's binding and the menu went on holding the old key. Reading the same table both
    /// places is what stops that.
    ///
    /// Returns nil for a binding this cannot express, which a menu item then simply does not carry.
    public static func menuKeyEquivalent(
        for binding: String
    ) -> (key: String, modifiers: Set<Modifier>)? {
        var parts = binding.split(separator: "-").map(String.init)
        guard let key = parts.popLast(), key.count == 1 else { return nil }

        var modifiers: Set<Modifier> = []
        for part in parts {
            switch part.lowercased() {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "mod", "cmd", "meta": modifiers.insert(.command)
            default: return nil
            }
        }
        return (key.lowercased(), modifiers)
    }

    /// Named here rather than as `NSEvent.ModifierFlags` so `Settings` stays free of AppKit.
    public enum Modifier: Sendable { case command, shift, option, control }

    // MARK: Language

    /// A language code from `Locales/` (`en`, `zh-Hans`), or `system` to follow macOS.
    ///
    /// A string rather than an enum, and that is the extensibility: a language is a directory under
    /// `Locales/`, so the set of legal values is whatever shipped, not something this file lists.
    /// An unknown value — a language removed in a later build, a typo — resolves like `system`
    /// instead of failing the load (see `L10n.resolve`).
    public var language: String

    // MARK: Launch

    public var launchAtLogin: Bool
    public var showMenuBarIcon: Bool

    /// Off by default — Plume lives in the menu bar. On, it takes a Dock icon and joins ⌘Tab, which
    /// some people want and which costs nothing to offer.
    public var showDockIcon: Bool

    // MARK: Appearance

    public enum Appearance: String, Codable, Equatable, Sendable {
        case system, light, dark
    }

    /// Light and dark both ship in v0.1 (design frame 1f), and the Appearance tab switches them.
    public var appearance: Appearance

    /// The selected accent's light hex, or a custom hex from the hand-editable settings file.
    /// Reserved for interactive state and list markers (decisions 22 and 28) — never body text.
    /// Built-in colours resolve to paired light/dark tones; custom colours are kept as supplied.
    public var accent: String

    public static let defaultAccent = "#8a570f"

    /// Seven restrained hues. Light tones meet 4.5:1 even on a selected light row (#e2e2e4);
    /// dark tones meet it on a selected dark row (#353539). Names come from the locale catalog.
    public static let accentOptions: [(id: String, name: String, hex: String, darkHex: String)] = [
        ("amber", "Amber", defaultAccent, "#e3b565"),
        ("rose", "Rose", "#a83d60", "#e991ad"),
        ("forest", "Forest", "#306d45", "#8ac69c"),
        ("teal", "Teal", "#146c6e", "#70c4c5"),
        ("indigo", "Indigo", "#4858b0", "#9eacf0"),
        ("violet", "Violet", "#794aa5", "#c6a1e8"),
        ("graphite", "Graphite", "#5c636f", "#acb2bd"),
    ]

    /// Resolve the previous palette without rewriting the user's file. A custom hex still works.
    public static func accentColours(for hex: String) -> (light: String, dark: String) {
        let legacyIDs = [
            "#c98a1f": "amber", "#5b67d8": "indigo",
            "#2f9e8f": "teal", "#6e7480": "graphite",
        ]
        let value = hex.lowercased()
        if let option = accentOptions.first(where: {
            $0.hex == value || $0.id == legacyIDs[value]
        }) {
            return (option.hex, option.darkHex)
        }
        return (hex, hex)
    }

    public static func accentName(_ id: String) -> String { L10n.t("accent.\(id)") }

    /// What "recent" means in the ⌘P switcher (decision 104).
    ///
    /// Three answers because there are three honest ones, and the one Plume shipped with was the
    /// least defensible of them: `max(mtime, lastOpened)`, which every open stamped — including the
    /// open at launch — so notes you had only *looked* at climbed to the top and read as today's.
    public enum NoteOrder: String, Codable, Equatable, Sendable, CaseIterable {
        /// The file's own modification date. The default: it is the only one of the three that means
        /// the same thing on every machine the vault reaches, and it survives sync intact.
        case modified
        /// The later of the mtime and the last time Plume opened the note — what shipped through
        /// v0.6.2, kept because "the notes I have been in" is a real way to work.
        case opened
        /// The creation time frozen into the filename by decision 2. Free, and immune to a sync
        /// daemon rewriting either timestamp.
        case created

        public var label: String {
            switch self {
            case .modified: return L10n.t("noteOrder.modified")
            case .opened: return L10n.t("noteOrder.opened")
            case .created: return L10n.t("noteOrder.created")
            }
        }
    }

    public var noteOrder: NoteOrder

    /// What the footer counts, which is a click on the number rather than a control anywhere.
    ///
    /// Words is the design's figure and the default. Characters is here because `countWords` splits
    /// on whitespace, and a note written in Chinese or Japanese has no whitespace to split on — it
    /// counts one "word" per sentence, which is not a wrong number so much as an unrelated one.
    ///
    /// A setting rather than a per-session toggle for the reason `hideFromScreenCapture` is one: the
    /// reason anyone changes it outlives the panel. No Settings row, like every other toggle that
    /// belongs to the panel rather than to the app.
    public enum FooterCount: String, Codable, Equatable, Sendable, CaseIterable {
        case words
        case characters

        public var other: FooterCount { self == .words ? .characters : .words }
    }

    public var footerCount: FooterCount

    /// Filename of the markdown theme CSS in the themes folder, or empty for Plume's own.
    ///
    /// Decision 19: a theme *is* a CSS file in a folder, so this is a filename rather than an enum —
    /// which is what lets a theme arrive without any new UI or any new code.
    public var markdownTheme: String

    /// Editor body text size in points. ⌘= / ⌘− adjust it from any panel, ⌘0 resets it.
    public var textSize: Double

    /// The only legal range, named once so the keyboard and a hand-edited file agree.
    public static let textSizeRange: ClosedRange<Double> = 10...32

    /// Background opacity only; note text and controls stay fully opaque.
    /// 0 is transparent, 1 is opaque. The Settings slider presents the inverse as transparency.
    public var panelOpacity: Double

    /// Half of the full 0...1: below 0.5 the panel is too see-through to read, so the slider's whole
    /// travel is spent on the half that is usable. A saved value below it clamps up to it.
    public static let panelOpacityRange: ClosedRange<Double> = 0.5...1
    public static let defaultPanelOpacity: Double = 1
    /// What the pre-slider "translucent panels" switch meant when it was on.
    public static let legacyTranslucentPanelOpacity: Double = 0.75

    /// The Settings slider's position, 0...100 (shown as a percentage of transparency), for an
    /// opacity. Stretched over `panelOpacityRange`, so 100 is the most transparent the panel gets
    /// rather than fully invisible.
    public static func transparencySliderValue(forOpacity opacity: Double) -> Double {
        (1 - opacity) / (1 - panelOpacityRange.lowerBound) * 100
    }

    /// The inverse of `transparencySliderValue(forOpacity:)`.
    public static func opacity(forTransparencySliderValue value: Double) -> Double {
        1 - value / 100 * (1 - panelOpacityRange.lowerBound)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case translucentPanes
        case showOnEverySpace
    }

    /// Frame 2a's "Hide While Screen Sharing", as `NSWindow.sharingType` (decision 36).
    ///
    /// A setting rather than a per-session toggle because the reason anyone turns it on — I present
    /// from this machine — outlives the panel, and a protection that quietly lapses on restart is
    /// worse than one that was never offered.
    public var hideFromScreenCapture: Bool

    /// Which Space the panel belongs to — the Dock's own three answers to *Assign To*, so that the
    /// two read the same way. The Dock's menu cannot reach the panel itself: `.canJoinAllSpaces`
    /// overrides it, and without that flag a Dock binding pins the window where Plume cannot move it.
    ///
    /// Decision 33 is not reversed by any of this: its complaint was that Space behaviour was a *side
    /// effect of pinning*, not that any one behaviour was wrong. This is the explicit control it was
    /// asking for.
    public enum SpaceAssignment: String, Codable, Equatable, Sendable, CaseIterable {
        /// The Dock's *None*, and the default. The panel belongs to the Space it is on, holding one
        /// train of thought there, and summoned from another Space it comes to the one you are on
        /// (180).
        case unassigned
        /// The Dock's *This Desktop*. The panel keeps to `assignedSpace`, and summoning it from
        /// anywhere else says where it is rather than moving it.
        case oneSpace
        /// The Dock's *All Desktops*: decision 33's `.canJoinAllSpaces`, so the panel is already
        /// everywhere and summoning is only ever a matter of moving it back on screen.
        case everySpace
    }

    /// **Why not `everySpace` by default.** A window on every Space is drawn above both desktops for
    /// the whole of a Space swipe and only drops behind the destination's windows once the swipe
    /// lands. Measured on macOS 27: holding a swipe halfway keeps the panel on top for as long as the
    /// fingers stay down, focused or not, and Stickies assigned to All Desktops does exactly the same.
    /// Nothing an app can observe arrives before the swipe ends, so it cannot be made to stop.
    ///
    /// Replaces `showOnEverySpace`, a Bool whose `false` was always the Dock's *None* and never *This
    /// Desktop*; a file that still holds it reads as `everySpace` or `unassigned` accordingly.
    public var spaceAssignment: SpaceAssignment

    /// The desktop `oneSpace` keeps to, as the Space's UUID — the identifier macOS itself files Dock
    /// bindings under, and the one that survives a restart and desktops being reordered. Nil for the
    /// other two, and `oneSpace` without one reads as `unassigned`.
    public var assignedSpace: String?

    /// Whether the panel stays above other applications' windows (the title bar's thumbtack).
    ///
    /// Off is the default: the panel is an ordinary-level window, so it comes forward when summoned
    /// and then goes behind whatever you click next like any other window. On is `.floating`, which
    /// is what the panel used to be unconditionally. A setting rather than per-session state for the
    /// reason `hideFromScreenCapture` is one — a choice to keep it up outlives the process, and one
    /// that silently lapses on relaunch is not a choice that was kept.
    public var keepOnTop: Bool

    /// Whether Plume asks GitHub, about once a day on summon, whether a newer release exists.
    ///
    /// **This is the switch on the network call, not on the notice.** Off means no request leaves
    /// the machine; the About tab's button still works, because pressing it is asking.
    ///
    /// On by default, and that is a deliberate reversal of decision 94's *nothing on launch,
    /// nothing scheduled*. The reason it changes: Plume is unsigned and installed by hand or by a
    /// cask, so a user on an old build has no way to find out that the thing annoying them was
    /// fixed a month ago — and the release they most need to hear about is the one they are not
    /// running. What is kept from 94 is everything else: nothing is downloaded, nothing is
    /// installed, nothing is opened, and no request is made on launch or on a timer.
    public var checkForUpdates: Bool

    // MARK: Defaults

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        vaultPath: String = Settings.defaultVaultPath,
        recentlyDeletedDays: Int = 30,
        gitSync: GitSyncSettings = GitSyncSettings(),
        summonHotkey: Hotkey = BuildProfile.current.defaultSummonHotkey,
        dismissMode: DismissMode = .sameHotkeyToggles,
        shortcuts: [String: String] = Settings.standardShortcuts,
        language: String = L10n.systemPreference,
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true,
        showDockIcon: Bool = false,
        appearance: Appearance = .system,
        accent: String = Settings.defaultAccent,
        markdownTheme: String = "",
        noteOrder: NoteOrder = .modified,
        footerCount: FooterCount = .words,
        textSize: Double = 15,
        panelOpacity: Double = Settings.defaultPanelOpacity,
        hideFromScreenCapture: Bool = false,
        spaceAssignment: SpaceAssignment = .unassigned,
        assignedSpace: String? = nil,
        keepOnTop: Bool = false,
        checkForUpdates: Bool = BuildProfile.current.allowsSystemIntegration
    ) {
        self.schemaVersion = schemaVersion
        self.vaultPath = vaultPath
        self.recentlyDeletedDays = recentlyDeletedDays
        self.gitSync = gitSync
        self.summonHotkey = summonHotkey
        self.dismissMode = dismissMode
        self.shortcuts = shortcuts
        self.language = language
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.showDockIcon = showDockIcon
        self.appearance = appearance
        self.accent = accent
        self.markdownTheme = markdownTheme
        self.noteOrder = noteOrder
        self.footerCount = footerCount
        self.textSize = textSize
        self.panelOpacity = min(max(panelOpacity, Self.panelOpacityRange.lowerBound), Self.panelOpacityRange.upperBound)
        self.hideFromScreenCapture = hideFromScreenCapture
        self.spaceAssignment = spaceAssignment
        self.assignedSpace = spaceAssignment == .oneSpace ? assignedSpace : nil
        self.keepOnTop = keepOnTop
        self.checkForUpdates = checkForUpdates
    }

    /// Every key is optional on the way in. This file is meant to be hand-edited, which means it
    /// will sometimes be hand-broken: a missing key, a stray comma removed along with the line it
    /// was on. One bad field should cost that field's value, not the launch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? d.vaultPath
        recentlyDeletedDays =
            try c.decodeIfPresent(Int.self, forKey: .recentlyDeletedDays) ?? d.recentlyDeletedDays
        // A malformed `gitSync` block costs the sync setting, not the file.
        gitSync = (try? c.decodeIfPresent(GitSyncSettings.self, forKey: .gitSync)) ?? d.gitSync
        summonHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .summonHotkey) ?? d.summonHotkey
        dismissMode = try c.decodeIfPresent(DismissMode.self, forKey: .dismissMode) ?? d.dismissMode
        // Merged over the standards rather than replacing them, so a file that names one shortcut
        // still gets all the others — the same forgiveness every other key here gets, and what lets
        // a settings.json written by an older build stay valid as rows are added.
        shortcuts = Settings.standardShortcuts.merging(
            try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? [:]
        ) { _, fromFile in fromFile }
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? d.accent
        markdownTheme = try c.decodeIfPresent(String.self, forKey: .markdownTheme) ?? d.markdownTheme
        // Decoded as a *string* and mapped, not as the enum: `decodeIfPresent(NoteOrder.self,…)`
        // throws on an unknown case, and this initialiser throwing costs the whole file its values,
        // not just this key. An order nobody recognises should clamp to the default and no more.
        noteOrder = NoteOrder(rawValue: try c.decodeIfPresent(String.self, forKey: .noteOrder) ?? "")
            ?? d.noteOrder
        // Decoded as a string for the reason above it.
        footerCount =
            FooterCount(rawValue: try c.decodeIfPresent(String.self, forKey: .footerCount) ?? "")
            ?? d.footerCount
        textSize = try c.decodeIfPresent(Double.self, forKey: .textSize) ?? d.textSize
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let wasTranslucent = try legacy.decodeIfPresent(Bool.self, forKey: .translucentPanes)
        panelOpacity = try c.decodeIfPresent(Double.self, forKey: .panelOpacity)
            ?? (wasTranslucent == true ? Self.legacyTranslucentPanelOpacity : d.panelOpacity)
        hideFromScreenCapture =
            try c.decodeIfPresent(Bool.self, forKey: .hideFromScreenCapture) ?? d.hideFromScreenCapture
        let everySpace = try legacy.decodeIfPresent(Bool.self, forKey: .showOnEverySpace)
        spaceAssignment = SpaceAssignment(rawValue: try c.decodeIfPresent(String.self, forKey: .spaceAssignment) ?? "")
            ?? everySpace.map { $0 ? SpaceAssignment.everySpace : .unassigned }
            ?? d.spaceAssignment
        assignedSpace = try c.decodeIfPresent(String.self, forKey: .assignedSpace)
        if spaceAssignment != .oneSpace { assignedSpace = nil }
        if spaceAssignment == .oneSpace, assignedSpace?.isEmpty ?? true {
            spaceAssignment = .unassigned
            assignedSpace = nil
        }
        keepOnTop = try c.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? d.keepOnTop
        checkForUpdates =
            try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates

        // Clamp rather than reject: a hand-typed 0 or 9999 should land somewhere sensible.
        textSize = min(max(textSize, Settings.textSizeRange.lowerBound), Settings.textSizeRange.upperBound)
        panelOpacity = min(max(panelOpacity, Self.panelOpacityRange.lowerBound), Self.panelOpacityRange.upperBound)
        // 0 would mean "delete immediately, no undo" — the one value this control must never carry.
        recentlyDeletedDays = min(max(recentlyDeletedDays, 1), 365)
        // The accent lands in CSS, so anything that is not a colour has to be caught here rather
        // than silently blanking `--accent` and taking every interactive affordance with it.
        if !Settings.isHexColour(accent) { accent = d.accent }
        // A theme is a bare filename in the themes folder. A path would let a hand-edited settings
        // file reach outside it, which is not what decision 19 offers.
        if markdownTheme.contains("/") || markdownTheme.hasPrefix(".") { markdownTheme = "" }
    }

    /// Older scratch settings inherited the release hotkey and background integrations.
    /// Migrate that hotkey while preserving any other custom combination and the existing vault.
    public mutating func isolateDevelopmentSettings(profile: BuildProfile = .current) {
        guard profile == .dev else { return }
        if summonHotkey == Hotkey.defaultSummon { summonHotkey = profile.defaultSummonHotkey }
        launchAtLogin = false
        checkForUpdates = false
    }

    /// The two places a development build used to keep its notes by default: `~/Plume-scratch`, and
    /// `Plume-scratch` beside the app bundle (which is `build/Plume-scratch` in a checkout).
    private static func legacyDevelopmentVaults(bundleURL: URL, homeDirectory: URL) -> [URL] {
        var vaults = [homeDirectory.appendingPathComponent("Plume-scratch", isDirectory: true)]
        if bundleURL.pathExtension == "app" {
            vaults.append(
                bundleURL.deletingLastPathComponent()
                    .appendingPathComponent("Plume-scratch", isDirectory: true)
            )
        }
        return vaults
    }

    /// Copy an old default development vault to `~/Documents/Plume-dev` once, preserving the source
    /// as a backup. A populated destination may belong to another checkout using the shared dev
    /// settings, so never merge or overwrite it — the configured path simply stays where it is.
    /// Missing source folders retain their path so the usual missing-vault recovery still applies.
    /// Only a `vaultPath` that *is* one of the old defaults is touched; a path the user chose is not.
    public mutating func migrateDevelopmentVault(
        profile: BuildProfile = .current,
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        guard profile == .dev else { return }
        let candidates = Self.legacyDevelopmentVaults(bundleURL: bundleURL, homeDirectory: homeDirectory)
        let configured = vaultPath == "~/Plume-scratch" ? candidates[0] : vaultURL
        guard let legacy = candidates.first(where: {
            $0.standardizedFileURL == configured.standardizedFileURL
        }) else { return }
        let destination = profile.defaultVaultURL(homeDirectory: homeDirectory)
        guard destination.standardizedFileURL != legacy.standardizedFileURL,
              !fileManager.fileExists(atPath: destination.path) else { return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".Plume-dev-migration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: legacy, to: staging)
        try fileManager.moveItem(at: staging, to: destination)
        // Update only after the whole copy is in place; failures leave the configured vault intact.
        vaultPath = destination.path
    }

    static func isHexColour(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let digits = value.dropFirst()
        return (digits.count == 6 || digits.count == 3)
            && digits.allSatisfy(\.isHexDigit)
    }
}
