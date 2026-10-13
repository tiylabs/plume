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
