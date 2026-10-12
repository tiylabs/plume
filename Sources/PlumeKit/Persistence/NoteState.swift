import CoreGraphics
import Foundation

public struct NoteState: Codable, Equatable, Sendable {

    /// Where the caret was when the panel was last dismissed, as a UTF-16 offset into the document —
    /// the unit both `NSTextView` and the web layer's `EditorState` count in, so it crosses the
    /// bridge without a conversion that could drift.
    ///
    /// Restored exactly, not reset to the end of the document: the workflow is returning to a
    /// half-finished thought, and end-of-document is only the right answer by coincidence
    /// (decision 11).
    public var caretOffset: Int

    /// The far end of a selection, when the user left one. `nil` means a plain caret.
    public var selectionAnchor: Int?

    /// First visible line, so a long note reopens where it was rather than scrolled to the top.
    public var scrollLine: Int

    /// When Plume last opened this note.
    ///
    /// Only the `.opened` switcher order reads it (decision 104), and it is no longer the default:
    /// every open stamps this, launch included, so ordering by it moved notes nobody had edited.
    public var lastOpened: Date?

    /// Pinned notes sort into the switcher's Pinned group, appear in the menu bar, and make the panel
    /// holding them ignore the dismiss hotkey.
    public var isPinned: Bool

    public init(
        caretOffset: Int = 0,
        selectionAnchor: Int? = nil,
        scrollLine: Int = 0,
        lastOpened: Date? = nil,
        isPinned: Bool = false
    ) {
        self.caretOffset = caretOffset
        self.selectionAnchor = selectionAnchor
        self.scrollLine = scrollLine
        self.lastOpened = lastOpened
        self.isPinned = isPinned
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caretOffset = try c.decodeIfPresent(Int.self, forKey: .caretOffset) ?? 0
        selectionAnchor = try c.decodeIfPresent(Int.self, forKey: .selectionAnchor)
        scrollLine = try c.decodeIfPresent(Int.self, forKey: .scrollLine) ?? 0
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

}
