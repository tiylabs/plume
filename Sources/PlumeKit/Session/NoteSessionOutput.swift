import Foundation

/// A note, loaded and ready to be put on screen.
public struct LoadedNote: Equatable, Sendable {
    public var filename: String
    public var text: String
    public var caret: Int
    public var pinned: Bool

    public init(filename: String, text: String, caret: Int, pinned: Bool) {
        self.filename = filename
        self.text = text
        self.caret = caret
        self.pinned = pinned
    }

    /// No note: what the page is told when a draft begins, so that ⌃X and the pin decline rather
    /// than act on a file that does not exist.
    public static let none = LoadedNote(filename: "", text: "", caret: 0, pinned: false)
}

/// Everything a note session does to the world outside itself, in one place.
///
/// The session decides *what should happen to the note*; this is how that reaches the screen, the
/// menu bar and the rest of the app. Keeping it behind a protocol is what lets the session be driven
/// by a test that records the calls and checks their order — the order is most of the behaviour.
@MainActor
public protocol NoteSessionOutput: AnyObject {

    /// Replace the document on screen. Moves the caret to `note.caret`, so it is for opening a note
    /// and for an external change — never for a rename or a draft turning into a file.
    func load(_ note: LoadedNote)

    /// The note on screen is now stored under another name. **Does not reload**: the buffer is
    /// already right and a reload would move the caret. Sent after a conflict sibling, a rename that
    /// follows the title, and a hand rename.
    func currentNoteRenamed(to filename: String)

    func pinnedChanged(_ pinned: Bool)

    /// `nil` hides the banner.
    func show(_ banner: Banner?)

    /// A receipt: a short line that fades, and that costs no height.
    func toast(_ text: String)

    /// News about something that happened while nobody was looking. Into a parked panel a toast
    /// would fade unseen, so the panel may hold it for the next summon.
    func news(_ text: String)

    func focusEditor()

    /// The set of pinned notes, or one's name, changed: the menu bar rebuilds its pinned section.
    func pinsChanged()

    /// Something the open switcher lists changed. A no-op when it is closed.
    func switcherNeedsRefresh()

    /// The vault folder is gone. A failed read or write is often the vault having moved, and the
    /// answer is to ask the user where it went rather than silently recreate it.
    func vaultIsGone()

    /// Whether the panel is on screen. A hidden panel must not take the keyboard when a note loads.
    var isPanelVisible: Bool { get }
}
