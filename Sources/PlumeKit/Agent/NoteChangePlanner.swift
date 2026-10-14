import Foundation

/// Turns a `modify_note` request into the new text of the note, or refuses the whole request.
///
/// The rules, each there so a modify cannot do something nobody asked for:
///
/// - Every `replace` matches the **same** original text, not the output of the change before it,
///   so the order of changes in a request does not matter and one change cannot create the match
///   for the next.
/// - A match must be exact (no case folding, no fuzzy matching) and unique. "The first similar
///   paragraph" is how an edit lands in the wrong section silently.
/// - A match must start and end on a grapheme boundary: `e` does not match the first half of `é`
///   written as `e` + combining accent, and half an emoji is not a match.
/// - Matched ranges must not overlap. Everything is checked before anything is built, and the result
///   is one new text — never "the first two applied, the third failed".
/// - At most one `append`, at the very end. Spacing is the agent's to supply; nothing guesses a
///   section or a blank line.
/// - The result may not be blank: a modify that empties a note is a delete in disguise.
public enum NoteChangePlanner {

    public static func apply(_ changes: [NoteChange], to base: String) throws -> String {
        try validate(changes)

        let map = LineEndingMap(raw: base)
        let boundaries = graphemeBoundaries(map.lf)

        var ranges: [(range: Range<Int>, replacement: [Unicode.Scalar])] = []
        var appendText: [Unicode.Scalar] = []

        for (index, change) in changes.enumerated() {
            switch change.kind {
            case .replace:
                let needle = Array(LineEndingMap.normalize(change.oldText ?? "").unicodeScalars)
                let found = occurrences(of: needle, in: map.lf, boundaries: boundaries, limit: 2)
                guard let first = found.first else {
                    throw AgentFailure(
                        .matchNotFound,
                        "changes[\(index)].old_text does not appear in the note exactly as given; read the note again and copy the passage",
                        details: ["change_index": String(index)]
                    )
                }
                guard found.count == 1 else {
                    throw AgentFailure(
                        .matchAmbiguous,
                        "changes[\(index)].old_text appears more than once; include more surrounding text so it is unique",
                        details: ["change_index": String(index)]
                    )
                }
                ranges.append((first..<(first + needle.count), Array((change.newText ?? "").unicodeScalars)))
            case .append:
                appendText = Array((change.text ?? "").unicodeScalars)
            }
        }

        let sorted = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.range.upperBound > b.range.lowerBound {
            throw AgentFailure(.changesOverlap, "two replacements cover overlapping text; merge them into one change")
        }

        var output: [Unicode.Scalar] = []
        output.reserveCapacity(map.raw.count)
        var cursor = 0
        for item in sorted {
            let raw = map.rawRange(item.range)
            output.append(contentsOf: map.raw[cursor..<raw.lowerBound])
            output.append(contentsOf: item.replacement)
            cursor = raw.upperBound
        }
        output.append(contentsOf: map.raw[cursor...])
        output.append(contentsOf: appendText)

        let result = MarkdownDocument.normalizeTrailingNewline(LineEndingMap.string(output))
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure(.emptyContent, "the changes would leave the note empty; Plume does not delete notes through the API")
        }
        guard result.utf8.count <= AgentLimits.noteMaxBytes else {
            throw AgentFailure(.contentTooLarge, "the note would exceed \(AgentLimits.noteMaxBytes) bytes")
        }
        return result
    }

    static func validate(_ changes: [NoteChange]) throws {
        guard !changes.isEmpty else {
            throw AgentFailure(.invalidRequest, "changes is empty")
        }
        guard changes.count <= AgentLimits.maxChangesPerRequest else {
            throw AgentFailure(.invalidRequest, "at most \(AgentLimits.maxChangesPerRequest) changes per request")
        }
        var appends = 0
        for (index, change) in changes.enumerated() {
            switch change.kind {
            case .replace:
                guard let old = change.oldText, !old.isEmpty else {
                    throw AgentFailure(.invalidRequest, "changes[\(index)]: replace needs a non-empty old_text")
                }
                guard change.newText != nil, change.text == nil else {
                    throw AgentFailure(.invalidRequest, "changes[\(index)]: replace takes old_text and new_text (new_text may be empty to delete)")
                }
            case .append:
                appends += 1
                guard let text = change.text, !text.isEmpty, change.oldText == nil, change.newText == nil else {
                    throw AgentFailure(.invalidRequest, "changes[\(index)]: append takes a non-empty text and nothing else")
                }
            }
        }
        guard appends <= 1 else {
            throw AgentFailure(.invalidRequest, "at most one append per request")
        }
    }

    /// Scalar offsets where a `Character` starts, plus the end.
    static func graphemeBoundaries(_ scalars: [Unicode.Scalar]) -> [Bool] {
        var marks = [Bool](repeating: false, count: scalars.count + 1)
        var offset = 0
        for character in LineEndingMap.string(scalars) {
            marks[offset] = true
            offset += character.unicodeScalars.count
        }
        marks[scalars.count] = true
        return marks
    }

    /// Start offsets of `needle` in `haystack` that sit on grapheme boundaries at both ends, up to
    /// `limit` of them (two is enough to know a match is not unique).
    static func occurrences(
        of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], boundaries: [Bool], limit: Int
    ) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var found: [Int] = []
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first, boundaries[i], boundaries[i + needle.count] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count {
                    found.append(i)
                    if found.count >= limit { break }
                }
            }
            i += 1
        }
        return found
    }
}
