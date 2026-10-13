import Foundation

/// Conflict markers, as git writes them into a file it could not merge.
public enum ConflictMarkers {

    /// Whether `text` still carries a `<<<<<<<` or `>>>>>>>` line.
    ///
    /// Only those two, and only at the start of a line: `=======` is a legitimate Markdown setext
    /// underline, and a note about git may quote a marker mid-line or inside indentation. Either
    /// remaining half means the person has not finished — a half-deleted block is not resolved.
    public static func isPresent(in text: String) -> Bool {
        // `isNewline`, not `"\n"`: Swift reads `\r\n` as a single character, so splitting on `"\n"`
        // never splits a file with Windows line endings and every marker after the first goes unseen.
        for line in text.split(whereSeparator: \.isNewline) {
            for marker in ["<<<<<<<", ">>>>>>>"] where line.hasPrefix(marker) {
                let rest = line.dropFirst(marker.count)
                if rest.isEmpty || rest.first == " " || rest.first == "\r" { return true }
            }
        }
        return false
    }

    public static func isPresent(inFileAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isPresent(in: String(decoding: data, as: UTF8.self))
    }
}
