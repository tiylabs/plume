import Foundation

/// What the panel is telling the user about itself, in one line above the editor.
///
/// Nothing in the design drew any of these, so they are built against the chrome's own rules: one
/// row, no button that has to be dismissed before typing resumes, and nothing that looks like an
/// error — because in two of the three cases nothing went wrong.
public enum Banner: Equatable, Sendable {
    case conflict
    case downloading
    case problem(String)

    /// The `kind` the page keys its styling on (`data-kind` on the banner row).
    public var kind: String {
        switch self {
        case .conflict: return "conflict"
        case .downloading: return "downloading"
        case .problem: return "problem"
        }
    }

    public var text: String {
        switch self {
        case .conflict:
            // The name of the thing that happened, and nothing after it.
            //
            // This used to go on to print the sibling's filename, and **the filename was the half
            // that got cut**: note names are long by construction and the conflict stamp doubles
            // them, so a 434pt panel rendered "…Your version is in 2026-08-23-1002…" — all of the
            // prose and none of the payload. Seen the first time the banner ever fired for real.
            //
            // Nothing is lost by dropping it. The panel is already editing the sibling, so your text
            // is on screen; ⌥⌘R reveals the file it is in; and the switcher lists both. A row that
            // cannot fit the fact it is carrying is better off carrying the state instead.
            return L10n.t("banner.conflict")
        case .downloading:
            return L10n.t("banner.downloading")
        case .problem(let message):
            return message
        }
    }
}
