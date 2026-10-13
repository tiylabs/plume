import CoreGraphics
import Foundation

/// Everything the web layer can tell Swift.
///
/// Mirrors `OutboundMessage` in `Editor/src/bridge/protocol.ts` exactly, and
/// `BridgeContractTests` holds the two together: the set of message names, and the fields each one
/// carries. Decoded into a Swift enum at the boundary rather than passed around as a dictionary, so
/// a message the web layer stops sending becomes a compile error here instead of a silent no-op at
/// runtime.
///
/// Decoding is lenient on purpose, as it always was: a field that is missing or the wrong type reads
/// as its zero value rather than dropping the message, because a half-understood `edited` is still
/// better handled than lost. A message whose `type` is unknown *is* dropped.
public enum BridgeMessage: Decodable, Equatable, Sendable {
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
    /// ⌘[ / ⌘]. Previous/Next follow the switcher list; `NoteSession` chooses the adjacent note.
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

    // MARK: - Names

    /// The `type` strings, one per case. Exists so the set of names is enumerable — the contract test
    /// compares it with the TypeScript union — and so the decoder below is an exhaustive `switch`:
    /// adding a case here without decoding it is a compile error.
    public enum Kind: String, CaseIterable, Sendable {
        case ready, edited, caret, requestNotes, openNote, createNote, togglePin, deleteNote, close
        case contentHeight, switcherOpen, actionsOpen, revealInFinder, openLink, renameFile
        case openSettings, copyAsMarkdown, exportNote, toggleHideFromCapture, toggleAutoSizing
        case setSpaceAssignment, toggleKeepOnTop, toggleFooterCount, duplicateNote, requestDeleted
        case restoreDeleted, forgetDeleted, textSize, navigate, dragRegions, headingMenu
    }

    public static var knownTypes: Set<String> { Set(Kind.allCases.map(\.rawValue)) }

    /// Which `type` this message was decoded from. Exhaustive, so it also proves every `Kind` has a
    /// case to land in.
    public var kind: Kind {
        switch self {
        case .ready: .ready
        case .edited: .edited
        case .caret: .caret
        case .requestNotes: .requestNotes
        case .openNote: .openNote
        case .createNote: .createNote
        case .togglePin: .togglePin
        case .deleteNote: .deleteNote
        case .close: .close
        case .contentHeight: .contentHeight
        case .switcherOpen: .switcherOpen
        case .actionsOpen: .actionsOpen
        case .revealInFinder: .revealInFinder
        case .openLink: .openLink
        case .renameFile: .renameFile
        case .openSettings: .openSettings
        case .copyAsMarkdown: .copyAsMarkdown
        case .exportNote: .exportNote
        case .toggleHideFromCapture: .toggleHideFromCapture
        case .toggleAutoSizing: .toggleAutoSizing
        case .setSpaceAssignment: .setSpaceAssignment
        case .toggleKeepOnTop: .toggleKeepOnTop
        case .toggleFooterCount: .toggleFooterCount
        case .duplicateNote: .duplicateNote
        case .requestDeleted: .requestDeleted
        case .restoreDeleted: .restoreDeleted
        case .forgetDeleted: .forgetDeleted
        case .textSize: .textSize
        case .navigate: .navigate
        case .dragRegions: .dragRegions
        case .headingMenu: .headingMenu
        }
    }

    // MARK: - Decoding

    /// From what `WKScriptMessage.body` carries: a property list of strings, numbers, booleans,
    /// arrays and dictionaries. Anything that is not a message, or not one Plume knows, is nil.
    public init?(body: Any) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let decoded = try? JSONDecoder().decode(BridgeMessage.self, from: data)
        else { return nil }
        self = decoded
    }

    private enum Key: String, CodingKey {
        case type
        case text, caret, scrollLine, query, filename, title, height, open, target, mode
        case storedName, action, back, titleBar, exclusions, close, button, level
    }

    private struct Frame: Decodable {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Axis.self)
            x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0
            y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0
            width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? 0
            height = (try? c.decodeIfPresent(Double.self, forKey: .height)) ?? 0
        }
        private enum Axis: String, CodingKey { case x, y, width, height }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let kind = Kind(rawValue: try c.decode(String.self, forKey: .type)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown message type"
            )
        }

        func string(_ key: Key) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        func number(_ key: Key) -> Double { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0 }
        func flag(_ key: Key, default fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        func frame(_ key: Key) -> CGRect { ((try? c.decodeIfPresent(Frame.self, forKey: key)) ?? nil)?.rect ?? .zero }

        switch kind {
        case .ready: self = .ready
        case .edited: self = .edited(text: string(.text), caret: Int(number(.caret)))
        case .caret: self = .caret(caret: Int(number(.caret)), scrollLine: Int(number(.scrollLine)))
        case .requestNotes: self = .requestNotes(query: string(.query))
        case .openNote: self = .openNote(filename: string(.filename))
        case .createNote: self = .createNote(title: string(.title))
        case .togglePin: self = .togglePin(filename: (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? nil)
        case .deleteNote: self = .deleteNote(filename: string(.filename))
        case .close: self = .close
        case .contentHeight: self = .contentHeight(CGFloat(number(.height)))
        case .switcherOpen: self = .switcherOpen(open: flag(.open, default: false), height: CGFloat(number(.height)))
        case .actionsOpen: self = .actionsOpen(open: flag(.open, default: false), height: CGFloat(number(.height)))
        case .revealInFinder: self = .revealInFinder
        case .openLink: self = .openLink(target: string(.target))
        case .renameFile: self = .renameFile
        case .openSettings: self = .openSettings
        case .copyAsMarkdown: self = .copyAsMarkdown(text: string(.text))
        case .exportNote: self = .exportNote(text: string(.text))
        case .toggleHideFromCapture: self = .toggleHideFromCapture
        case .toggleAutoSizing: self = .toggleAutoSizing
        case .setSpaceAssignment: self = .setSpaceAssignment(string(.mode))
        case .toggleKeepOnTop: self = .toggleKeepOnTop
        case .toggleFooterCount: self = .toggleFooterCount
        case .duplicateNote: self = .duplicateNote(text: string(.text))
        case .requestDeleted: self = .requestDeleted
        case .restoreDeleted: self = .restoreDeleted(storedName: string(.storedName))
        case .forgetDeleted: self = .forgetDeleted(storedName: string(.storedName))
        case .textSize: self = .textSize(action: string(.action))
        case .navigate: self = .navigate(back: flag(.back, default: true))
        case .dragRegions:
            let list = ((try? c.decodeIfPresent([Frame].self, forKey: .exclusions)) ?? nil) ?? []
            self = .dragRegions(titleBar: frame(.titleBar), exclusions: list.map(\.rect), close: frame(.close))
        case .headingMenu:
            self = .headingMenu(
                button: frame(.button),
                level: ((try? c.decodeIfPresent(Double.self, forKey: .level)) ?? nil).map { Int($0) }
            )
        }
    }
}
