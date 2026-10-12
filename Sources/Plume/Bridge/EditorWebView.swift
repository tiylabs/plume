import AppKit
import Foundation
import PlumeKit
import WebKit

/// Everything the web layer can tell Swift.
///
/// Mirrors `OutboundMessage` in `Editor/src/main.ts` exactly. Decoded into a Swift enum at the
/// boundary rather than passed around as a dictionary, so a message the web layer stops sending
/// becomes a compile error here instead of a silent no-op at runtime.
enum BridgeMessage {
    case ready
    case edited(text: String, caret: Int)
    case caret(caret: Int, scrollLine: Int)
    case requestNotes(query: String)
    case openNote(filename: String)
    case createNote(title: String)
    case togglePin(filename: String?)
    case deleteNote(filename: String)
    case close
    case contentHeight(CGFloat)
    /// ⌘P opened or closed. Carries the height the list wants — measured once per opening, not
    /// per keystroke; see `reportHeight` in switcher.ts. It used to carry only the flag, and Swift
    /// made the height up from a constant.
    case switcherOpen(open: Bool, height: CGFloat)
    /// ⌘K opened or closed. Carries the panel's measured height, because how tall it is depends on
    /// how many rows survived the filter — and the panel has to grow to hold it.
    case actionsOpen(open: Bool, height: CGFloat)
    case revealInFinder
    /// ⌘-click on a link (decision 138). Carries the link node's **raw text**, deliberately not a
    /// URL: the page decides what is a link, `LinkTarget` decides what may be opened, and keeping
    /// those apart is what puts the half that can be wrong quietly somewhere it can be tested.
    case openLink(target: String)
    /// ⌘K row fifteen (decision 103): rename the file behind this note by hand.
    case renameFile
    case openSettings
    /// The buffer travels with both of these rather than Swift using its own copy, which the write
    /// debounce (decision 10) leaves up to 500 ms behind what is on screen.
    case copyAsMarkdown(text: String)
    case exportNote(text: String)
    /// `NSWindow.sharingType` is a window property, so the web layer can only ask (decision 36).
    case toggleHideFromCapture
    /// ⇧⌘/. Auto-sizing is window state, so only Swift can hold it (decision 40).
    case toggleAutoSizing
    /// ⌘K's Assign to Desktop row: `Settings.SpaceAssignment`'s raw value. Which desktop *This
    /// Desktop* means is Swift's to work out — the page cannot see Spaces.
    case setSpaceAssignment(String)
    /// The title bar's thumbtack. Window level is window state, so the page only asks.
    case toggleKeepOnTop
    case toggleFooterCount
    /// ⌘D. Carries the buffer rather than re-reading the file, so a duplicate taken mid-sentence
    /// contains the sentence.
    case duplicateNote(text: String)
    case requestDeleted
    case restoreDeleted(storedName: String)
    /// Permanent removal from the holding folder, chosen per row. The one destructive action
    /// in Plume with no undo behind it, which is why it is asked for explicitly.
    case forgetDeleted(storedName: String)
    /// ⌘= / ⌘− / ⌘0. Swift owns `Settings.textSize`, so the web layer asks rather than sets.
    case textSize(action: String)
    /// ⌘[ / ⌘]. The visit history lives in `PanelController`, so this only asks.
    case navigate(back: Bool)
    /// Where the window may be dragged from, in CSS pixels with a top-left origin. Sent by the web
    /// layer because only it knows where its own buttons ended up.
    ///
    /// `close` is the close dot on its own, named rather than indexed out of `exclusions` — it is in
    /// that list too, but reading it back by document order would break the first time the pin
    /// enters the bar. Decision 107 needs it to light the dot from Swift, because a WKWebView in a
    /// window that is not key never sees the pointer.
    case dragRegions(titleBar: CGRect, exclusions: [CGRect], close: CGRect)
    /// The format bar's heading button was pressed. Carries the button's rect (CSS pixels, top-left
    /// origin) and the caret's current heading level, so the menu can tick it.
    case headingMenu(button: CGRect, level: Int?)

    init?(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }

        func string(_ key: String) -> String { dict[key] as? String ?? "" }
        func number(_ key: String) -> Double { (dict[key] as? NSNumber)?.doubleValue ?? 0 }

        switch type {
        case "ready":
            self = .ready
        case "edited":
            self = .edited(text: string("text"), caret: Int(number("caret")))
        case "caret":
            self = .caret(caret: Int(number("caret")), scrollLine: Int(number("scrollLine")))
        case "requestNotes":
            self = .requestNotes(query: string("query"))
        case "openNote":
            self = .openNote(filename: string("filename"))
        case "createNote":
            self = .createNote(title: string("title"))
        case "togglePin":
            self = .togglePin(filename: dict["filename"] as? String)
        case "deleteNote":
            self = .deleteNote(filename: string("filename"))
        case "close":
            self = .close
        case "contentHeight":
            self = .contentHeight(CGFloat(number("height")))
        case "switcherOpen":
            self = .switcherOpen(
                open: dict["open"] as? Bool ?? false,
                height: CGFloat(number("height"))
            )
        case "actionsOpen":
            self = .actionsOpen(
                open: dict["open"] as? Bool ?? false,
                height: CGFloat(number("height"))
            )
        case "revealInFinder":
            self = .revealInFinder
        case "openLink":
            self = .openLink(target: string("target"))
        case "renameFile":
            self = .renameFile
        case "copyAsMarkdown":
            self = .copyAsMarkdown(text: string("text"))
        case "exportNote":
            self = .exportNote(text: string("text"))
        case "toggleHideFromCapture":
            self = .toggleHideFromCapture
        case "toggleAutoSizing":
            self = .toggleAutoSizing
        case "setSpaceAssignment":
            self = .setSpaceAssignment(string("mode"))
        case "toggleKeepOnTop":
            self = .toggleKeepOnTop
        case "toggleFooterCount":
            self = .toggleFooterCount
        case "duplicateNote":
            self = .duplicateNote(text: string("text"))
        case "requestDeleted":
            self = .requestDeleted
        case "restoreDeleted":
            self = .restoreDeleted(storedName: string("storedName"))
        case "forgetDeleted":
            self = .forgetDeleted(storedName: string("storedName"))
        case "textSize":
            self = .textSize(action: string("action"))
        case "navigate":
            self = .navigate(back: dict["back"] as? Bool ?? true)
        case "openSettings":
            self = .openSettings
        case "dragRegions":
            self = .dragRegions(
                titleBar: Self.rect(dict["titleBar"]),
                exclusions: (dict["exclusions"] as? [Any] ?? []).map(Self.rect),
                close: Self.rect(dict["close"])
            )
        case "headingMenu":
            self = .headingMenu(
                button: Self.rect(dict["button"]),
                level: (dict["level"] as? NSNumber)?.intValue
            )
        default:
            return nil
        }
    }

    private static func rect(_ any: Any?) -> CGRect {
        guard let r = any as? [String: Any] else { return .zero }
        return CGRect(
            x: (r["x"] as? NSNumber)?.doubleValue ?? 0,
            y: (r["y"] as? NSNumber)?.doubleValue ?? 0,
            width: (r["width"] as? NSNumber)?.doubleValue ?? 0,
            height: (r["height"] as? NSNumber)?.doubleValue ?? 0
        )
    }
}

@MainActor
protocol EditorWebViewDelegate: AnyObject {
    func editor(_ editor: EditorWebView, didReceive message: BridgeMessage)
}

/// The panel's web view, and the Swift half of decision 4's bridge.
///
/// One `WKScriptMessageHandler` inbound, `evaluateJavaScript` outbound. No Node, no server, no custom
/// scheme — the whole editor is a single self-contained HTML file, which is also why it can be loaded
/// straight off disk with no network entitlement and no loading state to design.
@MainActor
final class EditorWebView: NSView {

    weak var delegate: (any EditorWebViewDelegate)?

    let webView: WKWebView
    /// The surface behind the web view: Liquid Glass on macOS 26+, an `NSVisualEffectView` before it.
    private let material: NSView
    /// Rounded clip around `material` on macOS 27 only; see the comment where it is installed.
    private let glassClip = NSView()
    private static let glassOverscan: CGFloat = 8
    /// Whether `material` is Liquid Glass. The web layer is told, because glass wants a much lighter
    /// scrim than the classic material (see `data-material="glass"` in `tokens.css`).
    let usesGlass: Bool
    private let dragOverlay = DragOverlayView()

    /// The close dot, **top-left origin in CSS pixels**, exactly as the web layer measured it.
    ///
    /// Kept unflipped for the same reason `DragOverlayView` keeps its regions unflipped: the message
    /// is delivered asynchronously, so a panel that resized between the web layer measuring and Swift
    /// applying would flip against the wrong height. Flip at read time, against the bounds in force.
    private var closeButtonTopLeft: CGRect = .zero
    private let bridge = MessageBridge()

    /// Calls queued before the web layer said `ready`. The bundle loads in a few milliseconds, but
    /// "a few" is not "zero", and the first `loadNote` routinely wins that race on a warm launch.
    private var pendingCalls: [String] = []
    private var isReady = false

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()

        // Nothing to persist: no cookies, no localStorage, no cache. All state lives in state.json
        // and the vault, and an ephemeral store keeps the footprint honest against the 150 MB bar.
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false

        webView = ClickThroughWebView(frame: frameRect, configuration: configuration)
        (material, usesGlass) = Self.makeMaterial()
        super.init(frame: frameRect)

        configuration.userContentController.add(bridge, name: "plume")
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            self.delegate?.editor(self, didReceive: message)
        }

        // The window is a transparent hole; the material is CSS. Without both of these the web view
        // paints an opaque white rectangle over the panel's rounded corners.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        #if DEBUG
        webView.isInspectable = true
        #endif

        // The real material, underneath everything.
        //
        // CSS `backdrop-filter` cannot do this job: inside a WKWebView it blurs the *page's* own
        // content, and the desktop behind a transparent window is not page content — so the panel was
        // a flat 88%-alpha rectangle with no blur at all. Only an NSVisualEffectView can sample what
        // is behind the window.
        //
        // `state = .active` is the line that matters. The default, `.followsWindowActiveState`,
        // desaturates the material whenever the owning app is not frontmost — and Plume's whole
        // premise is being usable while another app is frontmost, so the default would make the panel
        // change appearance exactly when it is doing its job.
        //
        // Glass is designed to wrap its content: it masks, refracts and sizes itself around
        // `contentView`. Left as a bare sibling underneath the web view it rendered as a clear sheet
        // with no blur and square corners.
        if #available(macOS 27, *), usesGlass, let glass = material as? NSGlassEffectView {
            // The exception, on macOS 27, where the unfocused glass is the private clear variant (see
            // `applyGlassStyle`). That variant draws a bright highlight along its whole edge, far
            // brighter than the widgets', and it is part of the glass rather than something a property
            // reaches. So the glass is made `glassOverscan` larger than the panel on every side and
            // clipped back by a rounded container: the highlight lands outside the window. Measured,
            // the top and bottom edges drop back to the wallpaper's own brightness, the lens
            // refraction stays, and the focused look is unchanged. With the glass no longer wrapping
            // the web view, the square-corner problem above is the container's mask.
            glassClip.wantsLayer = true
            glassClip.layer?.cornerRadius = Self.cornerRadius
            glassClip.layer?.masksToBounds = true
            glass.cornerRadius = Self.cornerRadius + Self.glassOverscan
            glassClip.addSubview(glass)
            addSubview(glassClip)
            addSubview(webView)
        } else if #available(macOS 26, *), let glass = material as? NSGlassEffectView {
            addSubview(material)
            glass.contentView = webView
        } else {
            addSubview(material)
            addSubview(webView)
        }
        // Above the web view, and transparent to every click except the ones in the title bar's
        // empty space.
        addSubview(dragOverlay)

        // The panel starts unfocused, but nothing tells it so until the first key change.
        applyGlassStyle(focused: false)
    }

    /// Key state drives the glass, not just the page. Measured on a real panel at 0% opacity: out of
    /// key the system renders `.clear` glass as a deep frosted slab; in key it renders it as bare
    /// refraction with the wallpaper fully legible through the text — the opposite of what a panel you
    /// are about to read or type in needs. So the focused panel takes `.regular` (frosted, deeper) and
    /// the unfocused one `.clear`, and the page scrim deepens on top (`data-focused` in tokens.css).
    func setFocused(_ focused: Bool) {
        keyFocused = focused
        applyFocusedLook()
    }

    /// Whether the panel is in the window's key state, as last reported by the window delegate.
    private var keyFocused = false

    /// Keep on top holds the focused look (frosted glass, deeper scrim) whether or not the window is
    /// key: a panel the user has pinned over their work is meant to be read at a glance, and losing
    /// key status to the app underneath it should not make it dissolve into the wallpaper.
    var holdsFocusedLook = false {
        didSet { if holdsFocusedLook != oldValue { applyFocusedLook() } }
    }

    private func applyFocusedLook() {
        let focused = keyFocused || holdsFocusedLook
        call("setFocused", [focused])
        applyGlassStyle(focused: focused)
    }

    /// Focused is frosted (`.regular`: the note is being read or typed in, so the wallpaper is held
    /// back); unfocused is the clear, refracting look of the system widgets.
    ///
    /// The unfocused half cannot be had from public API. AppKit renders every `NSGlassEffectView` in a
    /// non-key window as a frosted slab whatever its `style` — measured on macOS 27 — while the
    /// widgets keep their clear glass out of key. `_variant` 11 is a clear, refracting glass that does
    /// not follow key state. It is private: if a later release renumbers it, the panel falls back to
    /// the frosted slab rather than failing. It is also sharper than the widgets, which blur their
    /// backdrop a little; nothing found yet reproduces that.
    ///
    /// Setting `style` resets `_variant`, so the variant has to be set after it, every time.
    private func applyGlassStyle(focused: Bool) {
        guard usesGlass, #available(macOS 26, *), let glass = material as? NSGlassEffectView else { return }
        if UserDefaults.standard.string(forKey: "PlumeMaterial") != nil { return }
        glass.style = focused ? .regular : .clear
        if !focused, #available(macOS 27, *), glass.responds(to: NSSelectorFromString("set_variant:")) {
            glass.setValue(Self.unfocusedGlassVariant, forKey: "_variant")
        }
    }

    private static let unfocusedGlassVariant = 11

    /// Material choice, prototype switch: `defaults write <bundle id> PlumeMaterial classic|regular`.
    /// Unset means clear glass on macOS 26+.
    ///
    /// **Clear, not regular.** Measured side by side: `.regular` washes the wallpaper toward white
    /// (light) or near-black (dark) on its own, so even with no scrim the panel looked like frosted
    /// paper and the dark theme could never get past a dark slab. `.clear` keeps the wallpaper's
    /// colour, which is what the system widgets show; legibility then comes from the page's scrim,
    /// i.e. the transparency slider.
    private static func makeMaterial() -> (NSView, Bool) {
        let choice = UserDefaults.standard.string(forKey: "PlumeMaterial")
        if #available(macOS 26, *), choice != "classic" {
            let glass = NSGlassEffectView()
            glass.style = choice == "regular" ? .regular : .clear
            glass.cornerRadius = cornerRadius
            return (glass, true)
        }
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = .popover
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        return (effect, false)
    }

    /// Matches `--radius-panel` in `tokens.css`. The web layer still draws the hairline border and
    /// its own rounding; this only stops the material's square corners showing through them.
    static let cornerRadius: CGFloat = 14

    /// Fade only the background material; the web view's text and controls keep their opacity.
    var panelOpacity: Double = Settings.defaultPanelOpacity {
        didSet {
            if usesGlass {
                // Never hidden: the web view is the glass's `contentView`, so hiding the glass hides
                // the page. Full opacity is the page painting a solid fill over it instead, and the
                // slider is carried entirely by the page's scrim (`--panel-glass-alpha`).
                material.alphaValue = 1
            } else {
                material.isHidden = panelOpacity >= 1 || panelOpacity <= 0
                material.alphaValue = min(1, max(0, panelOpacity / Settings.legacyTranslucentPanelOpacity))
            }
        }
    }

    /// Both subviews fill the view exactly. Explicit rather than autoresizing masks: this view is
    /// installed as a window's `contentView` at zero size and resized once the window has a frame,
    /// and proportional autoresizing from a zero rect is a coin toss.
    override func layout() {
        super.layout()
        if glassClip.superview != nil {
            glassClip.frame = bounds
            material.frame = glassClip.bounds.insetBy(dx: -Self.glassOverscan, dy: -Self.glassOverscan)
        } else {
            material.frame = bounds
        }
        webView.frame = bounds
        dragOverlay.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Loading

    /// Where the editor bundle lives: inside the app bundle when packaged, and — so that
    /// `swift run Plume` is a usable way to iterate — the repository's `Editor/dist` otherwise.
    static func bundleURL() -> URL? {
        if let resource = Bundle.main.resourceURL {
            let packaged = resource.appendingPathComponent("Editor/index.html")
            if FileManager.default.fileExists(atPath: packaged.path) { return packaged }
        }
        if let override = ProcessInfo.processInfo.environment["PLUME_EDITOR_HTML"] {
            return URL(fileURLWithPath: override)
        }
        // Executable at .build/<config>/Plume, so the package root is three levels up.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let development = root.appendingPathComponent("Editor/dist/index.html")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    func load() {
        guard let url = Self.bundleURL() else {
            NSLog("Plume: editor bundle not found — run Scripts/build-app.sh")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: - Outbound

    func markReady() {
        isReady = true
        let queued = pendingCalls
        pendingCalls.removeAll()
        for call in queued { webView.evaluateJavaScript(call, completionHandler: nil) }
    }

    /// Calls `window.plumeHost.<method>(...)`.
    ///
    /// Arguments are JSON-encoded rather than interpolated: a note containing a backtick, a newline
    /// or `</script>` is completely ordinary, and string-concatenating one into a JS expression would
    /// break the editor on exactly the content people write.
    func call(_ method: String, _ arguments: [Any] = []) {
        // A closure, not `map(Self.json)`: Swift 6.0, the floor Package.swift names, rejects the
        // bare reference to a main-actor static here. Newer compilers accept both (reported in #6).
        let encoded = arguments.map { Self.json($0) }.joined(separator: ", ")
        let script = "window.plumeHost && window.plumeHost.\(method)(\(encoded));"

        guard isReady else {
            pendingCalls.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Calls `window.plumeHost.<method>(...)` with arguments that are already JSON.
    ///
    /// The switcher's rows go through here: they are `Codable` structs encoded once, rather than
    /// being converted to `[String: Any]` first so that `call` can convert them straight back.
    func callJSON(_ method: String, _ jsonArguments: [String]) {
        let script = "window.plumeHost && window.plumeHost.\(method)(\(jsonArguments.joined(separator: ", ")));"
        guard isReady else {
            pendingCalls.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }

    /// Encodes one argument. `JSONSerialization` needs a container at the top level, so scalars go
    /// through a single-element array and come back out.
    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let text = String(data: data, encoding: .utf8),
              text.count >= 2
        else {
            return "null"
        }
        return String(text.dropFirst().dropLast())
    }

    func focusEditor() {
        call("focusEditor")
        // The web view has to be first responder before anything inside it can be, and summoning
        // does not go through a click that would set it.
        window?.makeFirstResponder(webView)
    }

    // MARK: - Dragging

    func setDragRegions(titleBar: CGRect, exclusions: [CGRect], close: CGRect) {
        dragOverlay.setRegions(titleBar: titleBar, exclusions: exclusions, viewHeight: bounds.height)
        closeButtonTopLeft = close
    }

    /// The close dot in screen coordinates, for decision 107's hover.
    ///
    /// Nil until the web layer has reported one, which is a real state: `reportDragRegions` runs
    /// after the first layout, and a hover read before then must simply not light the dot.
    /// **This override is on the wrong view to matter, and is kept only to say so.**
    ///
    /// `EditorWebView` is a container: the `WKWebView` is a *subview* of it (see `addSubview` in
    /// `init`), and AppKit asks `acceptsFirstMouse` of the view a click hit-tests to. That is the web
    /// view, never this one. Overriding it here changed nothing and was reported as still broken —
    /// the real answer is `ClickThroughWebView` at the bottom of this file.
    ///
    /// `NSView` returns false here, which is right for a document window — you click it to bring it
    /// forward, and you would not want that click also pressing whatever was under it. **A floating
    /// utility panel is the opposite case.** The panel is summoned over the app you are working in and
    /// deliberately never activates (decision 9); a click on ⌘K is a click on ⌘K, and spending it on
    /// focus means every action costs two clicks and the first one silently does nothing.
    ///
    /// Reported from use, and it presents exactly as AppKit swallowing the click: the button takes
    /// its pressed fill, because the page does receive the mouse-down (decision 107 measured that a
    /// click *is* delivered even when moves are not), and then nothing happens.
    ///
    /// **Not reproducible with synthetic events**, which is worth writing down rather than treating
    /// as doubt: a `CGEvent` posted at `cghidEventTap` enters below the window server's first-click
    /// arbitration, so a driver clicks straight through and always "passes". The harness cannot see
    /// this class of fault at all.
    ///
    /// Spotlight and Raycast both behave this way, and it is what makes a panel feel like a panel
    /// rather than a window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the pointer is, in the page's own top-left coordinates — the inverse of the flip below.
    ///
    /// Decision 120: the page cannot find this out for itself. In Plume's real configuration a
    /// WKWebView receives no mouse events at all (decision 107 measured zero), so anything driven by
    /// `mouseenter`, `mouseover` or `:hover` is dead whenever the panel is doing its job — floating,
    /// unfocused, over the app you are working in. Swift already reads the pointer for `setHover`
    /// and the close dot; this hands the same read to the page so the tooltip can resolve it with
    /// `elementFromPoint`.
    func pointerInPage() -> CGPoint? {
        guard let window else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inView = convert(inWindow, from: nil)
        return CGPoint(x: inView.x, y: bounds.height - inView.y)
    }

    func closeButtonScreenRect() -> CGRect? {
        guard !closeButtonTopLeft.isEmpty, let window else { return nil }
        let flipped = CGRect(
            x: closeButtonTopLeft.minX,
            y: bounds.height - closeButtonTopLeft.maxY,
            width: closeButtonTopLeft.width,
            height: closeButtonTopLeft.height
        )
        return window.convertToScreen(convert(flipped, to: nil))
    }
}

/// A `WKWebView` whose first click acts instead of being spent on focusing the window.
///
/// `NSView` answers false here, which is right for a document window — you click it to bring it
/// forward, and that click should not also press whatever was under it. **A floating utility panel is
/// the opposite case.** The panel is summoned over the app you are working in and deliberately never
/// activates (decision 9), so a click on ⌘K is a click on ⌘K; spending it on focus makes every action
/// cost two clicks, with the first silently doing nothing.
///
/// Reported from use, and it presents exactly as AppKit swallowing the click: the button takes its
/// pressed fill — the page does receive the mouse-down, which decision 107 measured — and then
/// nothing happens.
///
/// **It has to be on this class and not on `EditorWebView`.** That one is a container and the web
/// view is its subview, so AppKit never asks it. The first attempt put the override there, changed
/// nothing, and the build came back reported as unfixed.
///
/// **Not reproducible with synthetic events**, which is worth writing down rather than treating as
/// doubt: a `CGEvent` posted at `cghidEventTap` enters below the window server's first-click
/// arbitration, so a driver clicks straight through and always passes. The harness cannot see this
/// class of fault at all — three runs with the unfocused precondition asserted said it was fine.
private final class ClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the `WKScriptMessageHandler` conformance so the web view does not retain the view that owns
/// it. `WKUserContentController` retains its handlers for the lifetime of the configuration, which
/// makes a direct conformance on `EditorWebView` an unbreakable cycle.
private final class MessageBridge: NSObject, WKScriptMessageHandler {
    @MainActor var onMessage: ((BridgeMessage) -> Void)?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let decoded = BridgeMessage(body: message.body) else { return }
            onMessage?(decoded)
        }
    }
}

/// Makes the title bar draggable (rule 3) without stealing any other click.
///
/// `-webkit-app-region: drag` is in the CSS because the design's markup uses it, but it is an
/// Electron/Tauri extension and does nothing in a WKWebView. So the region is reported by the web
/// layer — which is the only place that knows where the buttons ended up after layout — and hit-tested
/// here. Everything outside it returns nil from `hitTest`, so clicks fall straight through to the web
/// view and text selection is untouched.
@MainActor
private final class DragOverlayView: NSView {

    /// Kept in the web layer's own coordinates — **top-left origin, CSS pixels** — and flipped at
    /// hit-test time against the current bounds.
    ///
    /// Flipping when the regions arrive was the obvious version and it is racy: the message is
    /// delivered asynchronously, so a panel that resized between the web layer measuring and Swift
    /// applying (which is exactly what opening the switcher does — the panel grows from note height to
    /// 500 pt) would flip against the wrong height. The draggable strip then lands hundreds of points
    /// down the note, so the title bar stops dragging and a band of body text starts.
    private var draggableTopLeft: [CGRect] = []

    func setRegions(titleBar: CGRect, exclusions: [CGRect], viewHeight: CGFloat) {
        guard !titleBar.isEmpty else {
            draggableTopLeft = []
            return
        }

        // The draggable strip is the title bar with the buttons punched out of it, expressed as the
        // horizontal gaps between them — the bar is one row, so subtracting rectangles reduces to
        // subtracting x-ranges.
        let sorted = exclusions
            .filter { $0.intersects(titleBar) }
            .sorted { $0.minX < $1.minX }

        var spans: [(CGFloat, CGFloat)] = []
        var cursor = titleBar.minX
        for box in sorted {
            if box.minX > cursor { spans.append((cursor, box.minX)) }
            cursor = max(cursor, box.maxX)
        }
        if cursor < titleBar.maxX { spans.append((cursor, titleBar.maxX)) }

        draggableTopLeft = spans.map { span in
            CGRect(x: span.0, y: titleBar.minY, width: span.1 - span.0, height: titleBar.height)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let height = bounds.height
        let hit = draggableTopLeft.contains { region in
            let flipped = CGRect(
                x: region.minX,
                y: height - region.maxY,
                width: region.width,
                height: region.height
            )
            return flipped.contains(local)
        }
        return hit ? self : nil
    }

    /// Same reasoning as `EditorWebView`'s: dragging the panel by its title bar should not need the
    /// panel focused first. Without this the first drag on an unfocused panel only focuses it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
