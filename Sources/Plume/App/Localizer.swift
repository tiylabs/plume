import AppKit
import PlumeKit

/// `L10n.t` under a name short enough to sit inside a sentence of AppKit code.
///
/// `tr("menu.quit")` rather than `L10n.t("menu.quit")` is the whole reason this file exists — there
/// are a hundred and twenty call sites, and the key is the part worth reading.
func tr(_ key: String, _ arguments: [String: String] = [:]) -> String {
    L10n.t(key, arguments)
}

/// The language and the things that must change with it, in one place.
///
/// **Live, not at next launch.** Settings > General > Language applies the moment it is chosen,
/// which is the same promise every other row in that window makes. Menus and the web editor are
/// rebuilt in place; the one thing that cannot be is a window that is already open, so the Settings
/// window is closed and re-made by `AppDelegate` (see `languageChanged`).
@MainActor
enum Localizer {

    /// Reads the catalogs and applies `preference`. Called once, before anything builds UI.
    static func start(preference: String) {
        if let directory = L10n.bundledDirectory() {
            L10n.configure(directory: directory)
        } else {
            NSLog("Plume: no Locales folder found — the interface will show message keys")
        }
        L10n.setLanguage(preference)
    }

    /// - Returns: true when the language actually changed, so callers skip the rebuild otherwise.
    @discardableResult
    static func apply(preference: String) -> Bool {
        let before = L10n.currentLanguage
        return L10n.setLanguage(preference) != before
    }
}
