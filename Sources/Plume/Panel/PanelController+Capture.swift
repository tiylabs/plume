import AppKit
import Foundation
import PlumeKit

/// Hiding the panel from screen capture, exporting a note, and loading the user's theme.
extension PanelController {

    // MARK: - Hide from Screen Capture

    /// Frame 2a's "Hide While Screen Sharing", decided by decision 36.
    ///
    /// The design's label implies detection: notice a screen-sharing session, hide until it ends.
    /// `NSWindow.sharingType = .none` is better than that and simpler — the window is excluded from
    /// capture at the window-server level, so there is no session to detect, no race between the
    /// share starting and the panel reacting, and no Screen Recording permission, which decision 9
    /// would otherwise have made this row impossible to build at all.
    func applyHiddenFromCapture() {
        let hidden = settings.value.hideFromScreenCapture
        panel.sharingType = hidden ? .none : .readOnly
        editor.send(.setHiddenFromCapture(hidden))
    }

    func setHiddenFromCapture(_ hidden: Bool) {
        settings.update { $0.hideFromScreenCapture = hidden }
        // `settings.update` comes back through `applySettings`, but not synchronously, and the ⌘K
        // row's label is read the moment the panel next opens.
        applyHiddenFromCapture()

        // The one setting in Plume whose effect is invisible *by definition* — it changes what other
        // processes can see, so pressing ⇧⌘H changed nothing at all on screen and the only way to
        // find out whether it had worked was to take a screenshot. Same toast as ⌃X's, decision 50.
        editor.send(.showToast(hidden ? tr("toast.hiddenFromCapture") : tr("toast.visibleInCapture")))
    }

    // MARK: - Export

    /// Frame 2a's Export…, and the one row whose meaning had to be decided rather than implemented
    /// (decision 37). The note is already a file the user owns, and Reveal in Finder already reaches
    /// it, so "export the markdown" would be a save panel wrapped around a copy they could make in
    /// the Finder. What they cannot get anywhere else is the *rendered* note.
    func exportNote(text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = MarkdownDocument.title(of: text).isEmpty
            ? "\(tr("export.defaultName")).html"
            : "\(MarkdownDocument.title(of: text)).html"
        panel.canCreateDirectories = true
        panel.title = tr("export.title")

        // The one place other than "choose vault" (decision 27) where Plume activates on purpose:
        // a save panel behind every other window is a hang as far as the user is concerned. And
        // activating is not enough on its own — the panel is `.floating`, so the panel came up behind
        // it with the Save button under its edge until `stepAside` (see `PanelWindow`).
        PanelWindow.stepAside()
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { [weak self] response in
            PanelWindow.resumeFloating()
            guard response == .OK, let url = panel.url, let self else { return }
            let html = MarkdownExport.html(
                from: text,
                title: MarkdownDocument.title(of: text),
                accent: self.settings.value.accent,
                language: L10n.currentLanguage
            )
            try? html.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// The selected theme's stylesheet, or empty for Plume's own.
    ///
    /// Failure is silent and falls back to the default: a theme is a file the user dropped in a
    /// folder, so a malformed or deleted one is an ordinary Tuesday, not an error worth a banner.
    func loadThemeCSS() -> String {
        let name = settings.value.markdownTheme
        guard !name.isEmpty else { return "" }
        let url = settings.themesFolder.appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
