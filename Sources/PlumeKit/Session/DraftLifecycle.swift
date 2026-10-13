import Foundation

/// Which draft is on screen, and whether an answer to an earlier draft's create still applies to it.
///
/// A draft is the panel after ⌘N and before its first write: it has text but no file. The file is made
/// by an asynchronous create, and **the answer arrives after the panel may have moved on**. A bare
/// "is a draft showing?" flag cannot tell the draft that asked for the create from a *newer* one:
/// type into draft A, press ⌘N within the 500 ms debounce, and A's create is enqueued while the
/// panel switches to an empty draft B. When A's answer lands the flag is true again — for B — so
/// the panel bound B's buffer to A's file, the next write put B's (usually empty) text into it
/// with A's hash as the expected one, and A's text was silently replaced. The write model must
/// keep each buffer attached to its own file, so the question is answered by
/// identity, not by state: each draft takes a generation number, and a create answer is only
/// accepted by the generation that asked.
///
/// Pure value type, no clock and no I/O, so the sequence above can be replayed in a test; the panel
/// delegates to the note session, which owns the instance and receives vault answers on the main actor.
public struct DraftLifecycle: Equatable, Sendable {
    /// Names one draft for as long as it is on screen.
    public typealias Ticket = Int

    /// A draft is showing: text without a file yet.
    public private(set) var isDraft = false

    private var generation = 0

    public init() {}

    /// A new, empty draft replaces whatever was on screen — an earlier draft included.
    public mutating func begin() {
        generation &+= 1
        isDraft = true
    }

    /// The draft stopped being the panel's content: its file was adopted, or a real note opened.
    public mutating func end() {
        isDraft = false
    }

    /// Taken when a create is asked for, and handed back with its answer.
    public var ticket: Ticket { generation }

    /// Whether the draft that took `ticket` is still the one showing. False when the panel has since
    /// moved to a real note *or to a different draft*; either way the created file is on disk and
    /// nothing on screen refers to it.
    public func isCurrent(_ ticket: Ticket) -> Bool {
        isDraft && generation == ticket
    }
}
