import AppKit
import PlumeKit

/// The menu bar item, design frame 2d.
///
/// The pinned section is the only part that moves: it is one item per pinned note, and it disappears
/// entirely — along with one of the separators — when nothing is pinned. A menu with an empty region
/// in the middle of it looks broken, and pins are per-machine (decision 11), so an empty section is
/// the normal state on a fresh Mac.
@MainActor
final class MenuBarController: NSObject {

    private let item: NSStatusItem
    private let menu = NSMenu()

    var onShow: (() -> Void)?
    var onNewNote: (() -> Void)?
    var onBrowse: (() -> Void)?
    var onActions: (() -> Void)?
    var onOpenNote: ((String) -> Void)?
    var onSettings: (() -> Void)?
    /// Opens the release page for the version the menu item names.
    var onOpenRelease: ((String) -> Void)?

    /// Supplies the pinned notes as (filename, title) pairs, most recently used first.
    var pinnedNotes: () -> [(filename: String, title: String)] = { [] }

    /// *Sync Now*.
    var onSyncNow: (() -> Void)?
    /// A conflicted file was chosen from the menu.
    var onOpenConflict: ((String) -> Void)?
    /// The sync failure line was chosen — the Storage tab says more than a menu line can.
    var onOpenSyncSettings: (() -> Void)?
    /// The note title for a filename, for the conflict list; nil when it is not a note Plume knows.
    var noteTitle: (String) -> String? = { _ in nil }

    init(hotkey: Hotkey) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = Self.statusImage
            button.toolTip = BuildProfile.current == .scratch
                ? "\(BuildProfile.current.displayName) — \(hotkey.displayString)"
                : tr("menubar.tooltip", ["hotkey": hotkey.displayString])
            button.target = self
            button.action = #selector(clicked)
            // Both buttons, or the action fires on the left one only and a right-click does nothing
            // at all — the state of this control before the split, since `item.menu` swallowed both.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.delegate = self
        // Deliberately **not** `item.menu`: setting it hands AppKit both buttons and the status
        // item's own action is never called. The menu is opened by hand in `showMenu` instead.
        rebuild(hotkey: hotkey)
    }

    /*
     * Left summons, right opens the menu.
     *
     * The convention every menu bar app with one primary action follows, and Plume has exactly one:
     * the icon is a second way to press the hotkey, for the machine where something else has claimed
     * it or the week you have not learned it yet. Before this both buttons opened the menu, so the
     * frequent thing was two clicks away from the icon and the rare thing was one.
     *
     * A control-click is a right-click on macOS and always has been, so it goes to the menu too — a
     * trackpad with secondary click switched off has no other way in.
     */
    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if secondary { showMenu() } else { onShow?() }
    }

    /// Pops the menu under the item, with the item highlighted as if AppKit had opened it.
    ///
    /// `item.menu` is assigned for the length of one click and taken away again: a status item shows
    /// its menu on press when it has one, and `performClick` is the only call that gets the highlight
    /// and the placement right. Left set, it would take the left button back.
    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private var hotkey: Hotkey = .defaultSummon

    /// The newer version, when there is one — the menu item's title and the icon's dot.
    ///
    /// **Derived, never dismissed.** Nothing marks it as read: it is set from a version comparison
    /// and goes away when the running build catches up, so there is no flag here that can be wrong
    /// or stale. That is the difference between this and the toast, which is shown and gone.
    private var updateAvailable: String?

    /// Tells the item a newer release exists, or that there is not one.
    func setUpdateAvailable(_ version: String?) {
        guard version != updateAvailable else { return }
        updateAvailable = version
        refreshIcon()
        rebuild(hotkey: hotkey)
    }

    // MARK: - Sync

    private var syncStatus: GitSyncStatus?
    private var animationTimer: Timer?
    private var animationFrame = 0

    /// Tells the item how Git sync is doing, or that there is none (`nil`).
    ///
    /// The icon is a function of this and of `updateAvailable`, never of an event: a red dot means
    /// *the sync is failing now*, and goes when the next cycle succeeds, with no one having to
    /// dismiss it.
    func setSyncStatus(_ status: GitSyncStatus?) {
        guard status != syncStatus else { return }
        syncStatus = status
        refreshIcon()
        rebuild(hotkey: hotkey)
    }

    private func refreshIcon() {
        let syncing = syncStatus?.isSyncing == true
        if syncing { startAnimating() } else { stopAnimating() }
        renderIcon()
    }

    private var currentDot: MenuBarDot {
        MenuBarDot.resolve(sync: syncStatus, updateAvailable: updateAvailable != nil)
    }

    private func renderIcon() {
        let dot = currentDot
        let syncing = syncStatus?.isSyncing == true
        guard dot != .none || syncing else {
            item.button?.image = Self.statusImage
            return
        }
        // Reduce Motion gets the arrows without the movement.
        let phase = syncing
            ? (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0.5 : Double(animationFrame % Self.animationFrames) / Double(Self.animationFrames))
            : nil
        item.button?.image = Self.composedImage(dot: dot, arrowPhase: phase)
    }

    private static let animationFrames = 10

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationFrame = 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animationFrame += 1
                self.renderIcon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    func rebuild(hotkey: Hotkey) {
        self.hotkey = hotkey
        menu.removeAllItems()

        // The summon item's shortcut goes in AppKit's key column like every other item's.
        //
        // It used to be part of the title — first three spaces and the glyphs, then a right-aligned
        // tab stop — and both landed short of the column ⌘N, ⌘P and ⌘K sit in, because that column
        // is inset from the menu's right edge by an amount an item's own text never reaches; making
        // the item wider widens the menu and takes the column with it. So it is a real key
        // equivalent, and `toggle` ignores a second call within a quarter second: the combination is
        // registered globally with Carbon (decision 9), and while Plume is frontmost — which is only
        // ever the Settings window — both would fire for one press.
        let show = NSMenuItem(title: tr("menubar.show"), action: #selector(showPlume), keyEquivalent: "")
        show.target = self
        if let key = hotkey.menuKeyEquivalent {
            show.keyEquivalent = key
            var mask: NSEvent.ModifierFlags = []
            if hotkey.modifiers.contains(.command) { mask.insert(.command) }
            if hotkey.modifiers.contains(.shift) { mask.insert(.shift) }
            if hotkey.modifiers.contains(.option) { mask.insert(.option) }
            if hotkey.modifiers.contains(.control) { mask.insert(.control) }
            show.keyEquivalentModifierMask = mask
        } else {
            show.attributedTitle = Self.title(tr("menubar.show"), shortcut: hotkey.displayString)
        }
        menu.addItem(show)

        menu.addItem(action(tr("menu.newNote"), key: "n", selector: #selector(newNote)))
        menu.addItem(action(tr("menu.browseNotes"), key: "p", selector: #selector(browse)))
        // Frame 2a justifies having no ⌘ toolbar button by pointing at "the footer hint and menu
        // bar". This is the menu bar half — without it, and without the footer hint, ⌘K was a panel
        // with no way to find out it existed.
        menu.addItem(action(tr("menubar.actions"), key: "k", selector: #selector(actionPanel)))

        let pinned = pinnedNotes()
        if !pinned.isEmpty {
            menu.addItem(.separator())
            for note in pinned {
                let entry = NSMenuItem(
                    title: note.title.isEmpty ? note.filename : note.title,
                    action: #selector(openPinned(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = note.filename
                entry.image = Self.pinImage
                menu.addItem(entry)
            }
        }

        addSyncItems()

        menu.addItem(.separator())
        // Above Settings, and only while there is one. This is the durable half of decision 136:
        // the toast comes and goes once a day, and this waits — in the app-level surface, because
        // updating the app is not something ⌘K does. ⌘K's fifteen rows all act on the note or the
        // panel, and a sixteenth that opened a browser would be the odd one out.
        if let version = updateAvailable {
            let update = NSMenuItem(
                title: tr("menubar.update", ["version": version]),
                action: #selector(openRelease),
                keyEquivalent: ""
            )
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(action(tr("menu.settings"), key: ",", selector: #selector(settings)))

        let quit = NSMenuItem(title: tr("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// The sync section: one line of state, the conflicted notes if there are any, and *Sync Now*.
    /// Absent entirely while Git sync is off, so a menu that has never heard of it is unchanged.
    private func addSyncItems() {
        guard let status = syncStatus else { return }
        menu.addItem(.separator())

        func line(_ title: String, symbol: String? = nil, tint: NSColor? = nil,
                  action: Selector? = nil, tooltip: String? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if action != nil { entry.target = self } else { entry.isEnabled = false }
            entry.toolTip = tooltip
            if let symbol {
                let configuration = tint.map { NSImage.SymbolConfiguration(paletteColors: [$0]) }
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration ?? .init())
                image?.isTemplate = tint == nil
                entry.image = image
            }
            return entry
        }

        switch status {
        case .syncing:
            menu.addItem(line(tr("menubar.sync.syncing")))

        case .idle(let last):
            menu.addItem(line(
                last.map { tr("menubar.sync.last", ["time": GitSyncWording.relative($0)]) }
                    ?? tr("menubar.sync.never")
            ))

        case .conflicts(let files):
            menu.addItem(line(
                L10n.plural("menubar.sync.conflicts", count: files.count),
                symbol: "exclamationmark.triangle.fill", tint: .systemYellow
            ))
            for file in files.prefix(5) {
                let title = noteTitle(file).flatMap { $0.isEmpty ? nil : $0 } ?? file
                let entry = line(title, action: #selector(openConflict(_:)))
                entry.representedObject = file
                entry.indentationLevel = 1
                menu.addItem(entry)
            }
            if files.count > 5 {
                let more = line("…")
                more.indentationLevel = 1
                menu.addItem(more)
            }

        case .failed(let failure):
            let message = failure.message
            let shown = message.count > 64 ? String(message.prefix(63)) + "…" : message
            menu.addItem(line(
                tr("menubar.sync.failed", ["message": shown]),
                symbol: "exclamationmark.circle.fill", tint: .systemRed,
                action: #selector(openSyncSettings), tooltip: message
            ))
        }

        let now = line(tr("menubar.sync.now"), action: #selector(syncNow))
        now.isEnabled = !status.isSyncing
        menu.addItem(now)
    }

    private func action(_ title: String, key: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Right-aligned shortcut text in a menu item, for a combination that is not a key equivalent.
    /// "Show Plume" with its hotkey in the column AppKit puts every other item's key equivalent in.
    ///
    /// The shortcut used to be three spaces and the glyphs, so it landed wherever the title happened
    /// to end while ⌘N, ⌘P and ⌘K below it were right-aligned by AppKit — one item out of step in a
    /// six-item menu. A right-aligned tab stop puts it in the same column without making it a real
    /// key equivalent, which is what this must not become: the combination is a Carbon global hotkey
    /// (decision 9), and registering it twice in two systems is two owners for one keypress.
    private static func title(_ text: String, shortcut: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 240)]

        let result = NSMutableAttributedString(
            string: text, attributes: [.paragraphStyle: style]
        )
        result.append(
            NSAttributedString(
                string: "\t\(shortcut)",
                attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: style,
                ]
            )
        )
        return result
    }

    /// The menu bar glyph — Plume's own mark, drawn as a template so macOS tints it for the current
    /// menu bar rather than painting a black shape onto a dark background.
    ///
    /// Falls back to an SF Symbol when the resource is absent, which is the case for `swift run Plume`
    /// during development: `NSImage(named:)` reads the app bundle, and there isn't one.
    private static let statusImage: NSImage? = {
        let image: NSImage?
        if BuildProfile.current == .scratch {
            image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Plume Dev")
        } else {
            image = NSImage(named: "MenuBar")
                ?? NSImage(systemSymbolName: "note.text", accessibilityDescription: "Plume")
        }
        image?.isTemplate = true
        image?.accessibilityDescription = BuildProfile.current.displayName
        return image
    }()

    /// The same glyph with a dot in its top-right corner, for when a newer release exists.
    ///
    /// **Monochrome, and deliberately.** A coloured badge would mean dropping `isTemplate`, and
    /// template rendering is what makes this icon right in a dark menu bar, in a light one, while
    /// the item is highlighted, and under reduce-transparency — four appearances, none of which a
    /// hand-picked colour survives. A dot in the menu bar's own ink is less loud than an orange one
    /// and is legible in all four, which is the trade this takes.
    ///
    /// The dot is punched out of the glyph rather than painted over it: `.destinationOut` clears a
    /// slightly larger disc first, so the dot keeps its own edge even where the artwork runs under
    /// it. Without the gap, a dot touching the glyph reads as part of the drawing.
    private static let badgedStatusImage: NSImage? = {
        guard let base = statusImage else { return nil }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)

            // Derived from the icon's own height rather than written down, so the badge keeps its
            // proportion if the artwork is ever redrawn at another size (decision 82).
            let diameter = (size.height * 0.34).rounded()
            let gap = max(1, (diameter * 0.34).rounded())
            let dot = NSRect(
                x: size.width - diameter,
                y: size.height - diameter,
                width: diameter,
                height: diameter
            )

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = tr("menubar.updateAvailable")
        return image
    }()

    /// The glyph wearing whatever the sync is saying: a coloured dot for a conflict (yellow) or a
    /// failure (red), the monochrome update dot, and up-and-down arrows while a cycle runs.
    ///
    /// **A coloured dot costs the template.** A template image is drawn in the menu bar's own ink and
    /// that is what keeps the icon right on a dark bar, a light one and a highlighted item; a colour
    /// cannot be part of one. So when the dot is coloured the image is not a template, and the glyph
    /// is painted in `labelColor` *inside the drawing handler* — resolved when the menu bar draws it,
    /// under the menu bar's appearance, rather than baked in now. Without a coloured dot the image
    /// stays a template and everything in it is plain black.
    ///
    /// The size never changes, arrows included: a status item that widened for two seconds every five
    /// minutes would shove its neighbours along with it.
    private static func composedImage(dot: MenuBarDot, arrowPhase: Double?) -> NSImage? {
        guard let base = statusImage else { return nil }
        let size = base.size
        let coloured = dot == .conflict || dot == .failure

        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            if coloured {
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
            }
            let ink: NSColor = coloured ? .labelColor : .black

            if let phase = arrowPhase {
                let box = NSRect(x: size.width - 11, y: 0, width: 11, height: 11)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(roundedRect: box.insetBy(dx: -1.2, dy: -1.2), xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                drawArrows(in: box, phase: phase, ink: ink)
            }

            if dot != .none {
                let diameter = (size.height * (coloured ? 0.40 : 0.34)).rounded()
                let gap = max(1, (diameter * 0.34).rounded())
                let spot = NSRect(
                    x: size.width - diameter, y: size.height - diameter,
                    width: diameter, height: diameter
                )
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: spot.insetBy(dx: -gap, dy: -gap)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                switch dot {
                case .failure: NSColor.systemRed.setFill()
                case .conflict: NSColor.systemYellow.setFill()
                default: NSColor.black.setFill()
                }
                NSBezierPath(ovalIn: spot).fill()
            }
            return true
        }
        image.isTemplate = !coloured
        image.accessibilityDescription = {
            switch dot {
            case .failure: return tr("menubar.a11y.failed")
            case .conflict: return tr("menubar.a11y.conflict")
            default: return arrowPhase != nil ? tr("menubar.a11y.syncing") : tr("menubar.updateAvailable")
            }
        }()
        return image
    }

    /// An up arrow and a down arrow side by side, drifting in opposite directions and trading
    /// brightness, so the pair reads as traffic both ways.
    private static func drawArrows(in box: NSRect, phase: Double, ink: NSColor) {
        func arrow(centerX: CGFloat, up: Bool, phase: Double) {
            let travel = CGFloat(phase) * 2 - 1                     // -1 → +1 across the cycle
            let shift = up ? travel : -travel
            let alpha = 0.45 + 0.55 * sin(.pi * phase)
            let top = box.maxY - 1.5, bottom = box.minY + 1.5
            let tip = up ? top : bottom, tail = up ? bottom : top
            let wing: CGFloat = 2.3 * (up ? -1 : 1)

            let path = NSBezierPath()
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: centerX, y: tail + shift))
            path.line(to: NSPoint(x: centerX, y: tip + shift))
            path.move(to: NSPoint(x: centerX - 2.3, y: tip + shift + wing))
            path.line(to: NSPoint(x: centerX, y: tip + shift))
            path.line(to: NSPoint(x: centerX + 2.3, y: tip + shift + wing))
            ink.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        arrow(centerX: box.minX + 3, up: true, phase: phase)
        arrow(centerX: box.maxX - 3, up: false, phase: (phase + 0.5).truncatingRemainder(dividingBy: 1))
    }

    private static let pinImage: NSImage? = {
        let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }()

    // MARK: - Actions

    @objc private func showPlume() { onShow?() }
    @objc private func newNote() { onNewNote?() }
    @objc private func browse() { onBrowse?() }
    @objc private func actionPanel() { onActions?() }
    @objc private func settings() { onSettings?() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openRelease() {
        guard let version = updateAvailable else { return }
        onOpenRelease?(version)
    }

    @objc private func syncNow() { onSyncNow?() }
    @objc private func openSyncSettings() { onOpenSyncSettings?() }
    @objc private func openConflict(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        onOpenConflict?(file)
    }

    @objc private func openPinned(_ sender: NSMenuItem) {
        guard let filename = sender.representedObject as? String else { return }
        onOpenNote?(filename)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Rebuilt on open rather than on every pin change, so the pinned section is right without the
    /// menu having to be told each time a note is pinned from inside a panel.
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(hotkey: hotkey)
    }
}
