import Foundation

/// One note, as the switcher needs to know it.
public struct NoteRecord: Equatable, Sendable {
    public var filename: String
    public var modified: Date
    public var title: String
    public var preview: String
    /// Full text, for body search. `nil` when the note could not be read without blocking — an
    /// evicted note is excluded from full-text search rather than being downloaded to serve a
    /// keystroke (decision 13).
    public var text: String?
    public var availability: NoteAvailability

    public init(
        filename: String,
        modified: Date,
        title: String,
        preview: String,
        text: String?,
        availability: NoteAvailability = .available
    ) {
        self.filename = filename
        self.modified = modified
        self.title = title
        self.preview = preview
        self.text = text
        self.availability = availability
    }
}
