import Foundation

/// The first thing Plume ever renders, and the only documentation most people will read.
///
/// Three constraints, from the brief: it teaches the hotkey, ⌘P and ⌘N; it demonstrates the live
/// preview by *being* markdown worth rendering; and it is disposable — an ordinary note in an
/// ordinary folder that you can edit or delete without breaking anything.
///
/// So it is short. A welcome note nobody finishes reading has taught nothing, and the product's whole
/// claim is about the first ten seconds.
///
/// **Rewritten for decision 129**, against a 460×460 first-run panel rather than a 692-wide one, and
/// with the fold treated as part of the design: at 460 the note is 924pt and the panel shows ~370 of
/// it, so everything load-bearing — all four keys and the ⇧⌘/ tip — is on the first screen, and the
/// cut lands on an unticked checkbox, which is a more specific invitation to scroll than a sentence
/// severed mid-clause. **⌘K is named**, which the first version never did despite it carrying
/// fifteen actions. **The vault path is not named**: `~/Documents/Plume` is true only until someone
/// moves their vault, after which the note is a lie sitting in their own folder — "a folder you own"
/// plus ⌘K → Reveal in Finder is true permanently and teaches a key on the way past.
public enum WelcomeNote {

    /// The note in the language in effect — `Locales/<code>/welcome.md`, which is where a translator
    /// edits it. A process with no catalogs beside it (a probe, a bare `swift run` outside the
    /// checkout) gets `english`, so a first launch can never write an empty note.
    public static var text: String {
        L10n.document("welcome.md") ?? english
    }

    /// Kept in step with `Locales/en/welcome.md` by `LocalizationTests`, which compares the two.
    public static let english = """
        # Welcome to Plume

        This is a note. Press **⌃⌥Space** to put Plume away. Press it again and Plume comes right back.

        ## Start with three keys

        - **⌘N** New note
        - **⌘P** Find a note
        - **⌘K** Everything else

        Plume starts at a fixed size. Press **⇧⌘/** if you'd rather have it grow with your notes.

        ## Just write

        Markdown formats as you type.

        Try **bold**, *italic*, `code`, a heading, a list, or a checkbox.

        - [ ] Tick this box
        - [x] This one's done

        The markdown for the line you're editing stays visible, so you can always see what you're \
        writing.

        > Every note is a plain `.md` file in a folder you own. No database. No account. Nothing to \
        sign into.

        You can find them anytime with **⌘K → Reveal in Finder**.

        That's enough to get started.

        Feel free to delete this note. Plume won't bring it back.

        """
}
