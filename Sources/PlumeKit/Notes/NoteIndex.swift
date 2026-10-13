import Foundation

/// Everything the ⌘P switcher does to a vault: keeps a cheap index of it, orders it, and answers
/// queries against it.
///
/// The index exists because the switcher's job is 200 notes (decision 23) and full-text search needs
/// their text. Re-reading 200 files per keystroke would be absurd, so files are read once and
/// re-read only when their size or modification date moves. That check is a `stat`, not a read.
public final class NoteIndex {

    /// Cached per note, so `refresh` can skip files that have not moved.
    private struct Entry {
        var record: NoteRecord
        var size: Int
        var modified: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var records: [NoteRecord] { entries.values.map(\.record) }

    public func record(_ filename: String) -> NoteRecord? { entries[filename]?.record }

    public var filenames: Set<String> { Set(entries.keys) }

    /// Rebuilds the index from the vault, reading only what changed.
    ///
    /// Never throws for a single unreadable note: one bad file must not empty the switcher. An
    /// evicted note keeps its row — it has a name, a date, and a title from the last time it was
    /// readable, or from its filename if it has never been readable here — it simply drops out of
    /// full-text search until it is downloaded.
    ///
    /// - Parameter availabilityOf: how a note's availability is decided. A seam, and one the bug
    ///   below justifies: eviction cannot be staged in a temporary directory, so without it the one
    ///   transition this method has to get right is the one transition no test can reach.
    @discardableResult
    public func refresh(
        vault: URL,
        availabilityOf: (URL) -> NoteAvailability = VaultIO.availability(of:)
    ) throws -> Set<String> {
        let urls = try VaultIO.listNotes(in: vault)
        var present = Set<String>()

        for url in urls {
            let filename = url.lastPathComponent
            present.insert(filename)

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? Date.distantPast

            // Availability belongs in the cache key, and leaving it out was a bug that survived a
            // release. A dataless file reports its **real** size and its **real** mtime — that is
            // the whole point of `VaultIO.availability`, and it means iCloud materialising a note
            // moves neither half of a size-and-mtime key. So a note indexed while it was still
            // downloading stayed indexed as evicted: no title, no body, for the life of the process.
            // On a mac syncing the vault for the first time that is most of the switcher, and the
            // only cure was quitting the app. The extra cost is one `stat` per note per refresh,
            // which is what `availability(of:)` is — it performs no data read and so can never
            // itself trigger the download it is asking about.
            let availability = availabilityOf(url)

            if let existing = entries[filename],
               existing.size == size,
               existing.modified == modified,
               existing.record.availability == availability {
                continue
            }

            var text: String?
            if availability == .available {
                text = try? VaultIO.loadText(url).text
            } else if let cached = entries[filename]?.record.text {
                // Evicted now, but we have read it before. Keeping the text means the note stays
                // searchable rather than silently dropping out of results mid-session.
                text = cached
            }

            // A note we have never been able to read falls back to the phrase in its own filename.
            // Not a title anyone typed, but the row is a landmark rather than a blank.
            let summary = text.map(MarkdownDocument.summary(of:))
                ?? (title: NoteFilename.title(from: filename) ?? "", preview: "")
            entries[filename] = Entry(
                record: NoteRecord(
                    filename: filename,
                    modified: modified,
                    title: summary.title,
                    preview: summary.preview,
                    text: text,
                    availability: availability
                ),
                size: size,
                modified: modified
            )
        }

        entries = entries.filter { present.contains($0.key) }
        return present
    }

    /// Updates one note in place, for the buffer the user is typing into.
    ///
    /// Called after every write so the switcher shows the note as it is now, not as it was when the
    /// index last ran — opening ⌘P immediately after typing a title and seeing the old one is the
    /// kind of small lie that makes a tool feel stale.
    public func update(filename: String, text: String, modified: Date) {
        let summary = MarkdownDocument.summary(of: text)
        entries[filename] = Entry(
            record: NoteRecord(
                filename: filename,
                modified: modified,
                title: summary.title,
                preview: summary.preview,
                text: text,
                availability: .available
            ),
            size: Data(text.utf8).count,
            modified: modified
        )
    }

    public func forget(_ filename: String) {
        entries.removeValue(forKey: filename)
    }

    // MARK: - Rows

    /// The rows the switcher shows, ordered, banded and formatted.
    ///
    /// - Parameters:
    ///   - query: what is in the search field. Empty means "everything, by recency".
    ///   - state: supplies pins and `lastOpened`.
    ///   - current: the note open in this panel, badged rather than hidden.
    ///   - order: which clock counts as "recent" (decision 104). Whichever it picks is the one value
    ///     the rows are sorted by, banded by and labelled with — see `NoteOrdering.activity`.
    public func rows(
        query: String,
        state: AppState,
        current: String?,
        order: Settings.NoteOrder = .modified,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = L10n.locale
    ) -> [SwitcherRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        let scored: [(record: NoteRecord, activity: Date, pinned: Bool, match: SwitcherRow.Match?, score: Int)]
        if trimmed.isEmpty {
            scored = records.map { record in
                let noteState = state.note(record.filename)
                return (
                    record,
                    NoteOrdering.activity(
                        order,
                        filename: record.filename,
                        modified: record.modified,
                        lastOpened: noteState.lastOpened
                    ),
                    noteState.isPinned,
                    nil,
                    0
                )
            }
        } else {
            scored = records.compactMap { record in
                guard let hit = NoteSearch.match(record: record, query: trimmed) else { return nil }
                let noteState = state.note(record.filename)
                return (
                    record,
                    NoteOrdering.activity(
                        order,
                        filename: record.filename,
                        modified: record.modified,
                        lastOpened: noteState.lastOpened
                    ),
                    noteState.isPinned,
                    hit.snippet,
                    hit.score
                )
            }
        }

        // With a query the order is relevance, then recency. Without one it is pins, then recency.
        let sorted = scored.sorted { a, b in
            if trimmed.isEmpty {
                if a.pinned != b.pinned { return a.pinned }
            } else if a.score != b.score {
                return a.score > b.score
            }
            if a.activity != b.activity { return a.activity > b.activity }
            return a.record.filename > b.record.filename
        }

        // Bands are landmarks for a recency-ordered scroll. A search result list is ordered by
        // relevance, so a "Today" header over it would be describing an order that isn't there —
        // bands are suppressed while searching, and the row's time column carries the date instead.
        let banded = trimmed.isEmpty && sorted.count >= NoteOrdering.groupingThreshold

        return sorted.map { item in
            let band: String? = banded
                ? NoteOrdering.label(
                    for: NoteOrdering.band(
                        modified: item.activity,
                        isPinned: item.pinned,
                        now: now,
                        calendar: calendar
                    ),
                    calendar: calendar,
                    locale: locale
                )
                : nil

            return SwitcherRow(
                filename: item.record.filename,
                title: item.record.title,
                time: NoteOrdering.relativeTime(item.activity, now: now, calendar: calendar, locale: locale),
                preview: item.record.preview,
                band: band,
                pinned: item.pinned ? true : nil,
                current: item.record.filename == current ? true : nil,
                match: item.match
            )
        }
    }
}
