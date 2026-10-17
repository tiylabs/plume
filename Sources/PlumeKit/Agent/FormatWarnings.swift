import Foundation

/// A few explicit checks on Markdown an agent is about to save, reported as warnings.
///
/// Deliberately not a Markdown parser. A second parser in Swift would disagree with the editor's
/// real one at the edges, and a warning that disagrees with what the person then sees on screen is
/// worse than none. These are line-shaped rules taken from what the editor's dialect actually does
/// (`Editor/src/markdown/dialect.ts`), each checked against the real editor by the WKWebView suite:
///
/// - Front matter on the first line becomes the note's title (`---`), which is almost never meant.
/// - A second list marker on the same line (`- - item`) does not nest — a list item holds text only.
/// - A heading, quote, fence or rule inside a list item stays literal text in this dialect.
///
/// Warnings never block a save: the person may have asked for exactly that Markdown.
public enum FormatWarnings {

    public static func check(_ markdown: String) -> [AgentWarning] {
        var warnings: [AgentWarning] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? $0.dropLast() : $0
        }

        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.trimmingCharacters(in: .whitespaces) == "---" {
            warnings.append(AgentWarning(
                "front_matter",
                "The note starts with '---'. Plume has no front matter; the first non-blank line becomes the title. Start with '# Title' instead."
            ))
        }

        var inFence = false
        var nested = false
        for line in lines {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, let rest = afterListMarker(trimmed) else { continue }
            if afterListMarker(rest) != nil || rest.hasPrefix("# ") || rest.hasPrefix("> ")
                || rest.hasPrefix("```") || rest.hasPrefix("|") {
                nested = true
            }
        }
        if nested {
            warnings.append(AgentWarning(
                "block_in_list_item",
                "A list item contains another list marker, heading, quote, code fence or table on the same line. In Plume a list item holds text only; put nested lists on their own indented line and other blocks at the top level."
            ))
        }

        if ConflictMarkers.isPresent(in: markdown) {
            warnings.append(.conflictMarkers)
        }
        return warnings
    }

    /// The rest of the line after a bullet or ordered marker and its space, or nil if not a list item.
    private static func afterListMarker(_ line: Substring) -> Substring? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            var rest = line.dropFirst(2)
            // A task box is part of the item, not a nested block.
            if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { rest = rest.dropFirst(4) }
            return rest
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return after.dropFirst(2)
    }
}
