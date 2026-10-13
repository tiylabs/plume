import Foundation

/// Matching a query against a note: fuzzy on the title, literal on the body.
///
/// Two different algorithms because they answer two different questions. A title is short and you
/// half-remember it, so subsequence matching with a typo's worth of slack is right. A body is long
/// and you remember an exact phrase from it, so a literal substring — shown as a highlighted
/// snippet — is right. Fuzzy body matching would return everything.
public enum NoteSearch {

    public struct Hit: Equatable, Sendable {
        public var score: Int
        public var snippet: SwitcherRow.Match?
    }

    /// Characters of context either side of a body hit. Enough for the phrase to make sense on a
    /// 460 px row without wrapping to a second line.
    static let snippetLead = 24
    static let snippetTrail = 48

    public static func match(record: NoteRecord, query: String) -> Hit? {
        // A title hit always beats a body hit, and keeps the first-line preview: the row already
        // shows why it matched.
        if let titleScore = fuzzyScore(candidate: record.title, query: query) {
            return Hit(score: 1_000 + titleScore, snippet: nil)
        }

        // Then the filename, so the date-stamped name is searchable ("2026-08" finds August).
        if let nameScore = fuzzyScore(candidate: record.filename, query: query) {
            return Hit(score: 500 + nameScore, snippet: nil)
        }

        guard let text = record.text, let snippet = bodySnippet(text: text, query: query) else {
            return nil
        }
        return Hit(score: snippet.score, snippet: snippet.match)
    }

    // MARK: - Fuzzy title matching

    /// Subsequence match with a score, or nil when the query's characters do not appear in order.
    ///
    /// Scoring rewards the two things that separate a match you meant from one you didn't: characters
    /// that land consecutively, and characters that land at the start of a word. "wknotes" should
    /// find "Weekly notes" ahead of a note that merely contains those letters scattered through it.
    public static func fuzzyScore(candidate: String, query: String) -> Int? {
        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        guard !haystack.isEmpty else { return nil }

        var score = 0
        var h = 0
        var lastMatch = -2

        for c in needle {
            var found = false
            while h < haystack.count {
                if haystack[h] == c {
                    score += 1
                    if h == lastMatch + 1 { score += 4 }               // consecutive run
                    if h == 0 || !haystack[h - 1].isLetter && !haystack[h - 1].isNumber {
                        score += 3                                      // start of a word
                    }
                    lastMatch = h
                    h += 1
                    found = true
                    break
                }
                h += 1
            }
            if !found { return nil }
        }

        // A short title that matched is a better answer than a long one that also did.
        return score + max(0, 20 - haystack.count / 4)
    }

    // MARK: - Body matching

    struct BodyHit {
        var score: Int
        var match: SwitcherRow.Match
    }

    /// Literal, case-insensitive, and returned as the three pieces the row highlights.
    ///
    /// Works in `Character`s rather than UTF-16 so an emoji or a combining accent before the hit
    /// cannot split the snippet mid-grapheme and hand the web layer a broken string.
    static func bodySnippet(text: String, query: String) -> BodyHit? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }

        let chars = Array(text)
        let lower = Array(text.lowercased())
        // Lowercasing can change length (ß → ss, İ → i̇), which would misalign every index below.
        guard lower.count == chars.count else { return caseInsensitiveFallback(text: text, query: query) }

        let pattern = Array(needle)
        guard pattern.count <= chars.count else { return nil }

        var start: Int?
        for i in 0...(chars.count - pattern.count) {
            if Array(lower[i..<(i + pattern.count)]) == pattern {
                start = i
                break
            }
        }
        guard let start else { return nil }

        let end = start + pattern.count
        let preStart = max(0, start - snippetLead)
        let postEnd = min(chars.count, end + snippetTrail)

        var pre = String(chars[preStart..<start])
        var post = String(chars[end..<postEnd])

        // Collapse the newlines a snippet spanning a paragraph break would otherwise carry into a
        // single-line row.
        pre = collapseWhitespace(pre)
        post = collapseWhitespace(post)

        if preStart > 0 { pre = "…" + pre }
        if postEnd < chars.count { post += "…" }

        // Earlier hits score higher: the phrase you remember is usually near the top of the note.
        return BodyHit(
            score: max(1, 200 - start / 20),
            match: SwitcherRow.Match(pre: pre, hit: String(chars[start..<end]), post: post)
        )
    }

    /// For the rare strings whose lowercasing changes their length, fall back to Foundation's own
    /// search and rebuild the snippet from ranges rather than from indices.
    private static func caseInsensitiveFallback(text: String, query: String) -> BodyHit? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let preStart = text.index(range.lowerBound, offsetBy: -snippetLead, limitedBy: text.startIndex)
            ?? text.startIndex
        let postEnd = text.index(range.upperBound, offsetBy: snippetTrail, limitedBy: text.endIndex)
            ?? text.endIndex

        var pre = collapseWhitespace(String(text[preStart..<range.lowerBound]))
        var post = collapseWhitespace(String(text[range.upperBound..<postEnd]))
        if preStart != text.startIndex { pre = "…" + pre }
        if postEnd != text.endIndex { post += "…" }

        return BodyHit(
            score: 100,
            match: SwitcherRow.Match(pre: pre, hit: String(text[range]), post: post)
        )
    }

    static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for c in s {
            if c.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out
    }
}
