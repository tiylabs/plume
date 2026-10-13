import Foundation

/// Every string a person reads, looked up by key in the language they chose.
///
/// **Why this is not `.strings` / `.xcstrings` / `String(localized:)`.** Three constraints, all of
/// them already load-bearing elsewhere in the project:
///
/// - Plume builds with the Command Line Tools alone (no Xcode project, see `Package.swift`), and
///   `.xcstrings` catalogs are compiled by Xcode.
/// - The language is switchable *inside the app*, live, without a relaunch. Apple's lookup follows
///   the process's language and is cached for its lifetime.
/// - A third of the product's strings live in the web editor, which Foundation cannot reach. The
///   catalog has to be a plain file both sides read, or the two halves drift.
///
/// So the catalogs are plain JSON, one directory per language under `Locales/`:
///
///     Locales/en/strings.json      flat `"key": "text"` pairs, `{name}` placeholders
///     Locales/en/welcome.md        the first note a new vault gets
///
/// **Adding a language is adding a directory** — copy `en/`, translate, done. Nothing in the code
/// names a language: the list is discovered, the picker in Settings is built from it, the web
/// bundle reads the same files at build time, and `build-app.sh` declares each one in `Info.plist`.
/// `Locales/README.md` is the contributor's version of this paragraph.
///
/// Keys are namespaced by who reads them: `editor.*` is compiled into the web bundle, everything
/// else is Swift's. A key missing from a translation falls back to English rather than showing a
/// key, and `LocalizationTests` fails before that can ship.
public enum L10n {

    /// The language every other one falls back to, and the one the source code is written against.
    public static let fallbackLanguage = "en"

    /// The `Settings.language` value meaning "whatever macOS is set to".
    public static let systemPreference = "system"

    /// The reserved key in each `strings.json` that names the language in its own script. It is
    /// what the picker prints, so a reader who cannot read the current language can still find
    /// theirs.
    public static let nameKey = "_language"

    public struct Language: Equatable, Sendable {
        /// The directory name and BCP 47 tag: `en`, `zh-Hans`.
        public let code: String
        /// In its own script: `English`, `简体中文`.
        public let name: String
    }

    // MARK: - State

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var catalogs: [String: [String: String]] = [:]
        var languages: [Language] = []
        var directory: URL?
        var current = L10n.fallbackLanguage
        /// Whether `configure` has run, or lazy loading has been tried. Lazy loading is attempted
        /// once: a process with no catalogs beside it should not stat the disk on every string.
        var attempted = false
    }

    /// Read from the main thread for the UI and from the vault queue for switcher rows, hence the
    /// lock. Contention is nil — it is written when the language changes, which is a click.
    private static let state = State()

    // MARK: - Loading

    /// Reads every `<code>/strings.json` under `directory`.
    ///
    /// A malformed catalog is skipped rather than fatal, and `LocalizationTests` is what notices:
    /// an app that cannot launch because a translator left a trailing comma is a worse failure than
    /// one language quietly falling back to English.
    public static func configure(directory: URL, fileManager: FileManager = .default) {
        var catalogs: [String: [String: String]] = [:]
        var languages: [Language] = []

        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = entry.appendingPathComponent("strings.json")
            guard let data = try? Data(contentsOf: file),
                  let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            else { continue }
            let code = entry.lastPathComponent
            catalogs[code] = table
            languages.append(Language(code: code, name: table[nameKey] ?? code))
        }

        // The fallback leads the list, and the rest follow alphabetically by code, so the picker's
        // order does not depend on which language the reader is currently in.
        languages.sort {
            if $0.code == fallbackLanguage { return true }
            if $1.code == fallbackLanguage { return false }
            return $0.code < $1.code
        }

        state.lock.lock()
        state.catalogs = catalogs
        state.languages = languages
        state.directory = directory
        state.attempted = true
        state.lock.unlock()
    }

    /// Loads the bundled catalogs the first time anything asks, if nobody configured them.
    ///
    /// The app calls `configure` explicitly at launch (`Localizer.start`); this is for everything
    /// else that links PlumeKit — the test executable, `swift run`, a probe — so that none of them
    /// has to remember a setup call and none shows `band.today` where it meant "Today".
    private static func ensureLoaded() {
        state.lock.lock()
        let needed = !state.attempted
        state.attempted = true
        state.lock.unlock()
        guard needed, let directory = bundledDirectory() else { return }
        configure(directory: directory)
    }

    /// Where the catalogs live, or nil when this process has none beside it.
    ///
    /// In the app bundle first; then `PLUME_LOCALES`; then — so `swift run Plume` and the PlumeKit test
    /// executable work from a checkout — the repository's own `Locales`, found the same way
    /// `EditorWebView.bundleURL` finds `Editor/dist`.
    public static func bundledDirectory(fileManager: FileManager = .default) -> URL? {
        if let resource = Bundle.main.resourceURL {
            let packaged = resource.appendingPathComponent("Locales")
            if fileManager.fileExists(atPath: packaged.path) { return packaged }
        }
        if let override = ProcessInfo.processInfo.environment["PLUME_LOCALES"] {
            return URL(fileURLWithPath: override)
        }
        // Executable at <root>/.build/<triple>/<config>/<name>: the root is four levels up.
        var root = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<4 { root = root.deletingLastPathComponent() }
        let development = root.appendingPathComponent("Locales")
        return fileManager.fileExists(atPath: development.path) ? development : nil
    }

    /// The languages found, fallback first.
    public static var availableLanguages: [Language] {
        ensureLoaded()
        state.lock.lock(); defer { state.lock.unlock() }
        return state.languages
    }

    // MARK: - Choosing

    /// Picks the catalog a preference means.
    ///
    /// - Parameters:
    ///   - preference: a language code, or `system`. Anything that names no catalog is treated as
    ///     `system`, so a hand-edited or newer `settings.json` degrades to the OS language rather
    ///     than to nothing.
    ///   - systemLanguages: macOS's ordered list; injectable so the rule is testable.
    public static func resolve(
        preference: String,
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let available = availableLanguages.map(\.code)
        if available.contains(preference) { return preference }
        return Bundle.preferredLocalizations(from: available, forPreferences: systemLanguages).first
            ?? fallbackLanguage
    }

    /// Switches the language and returns the code that took effect.
    @discardableResult
    public static func setLanguage(
        _ preference: String,
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let code = resolve(preference: preference, systemLanguages: systemLanguages)
        state.lock.lock()
        state.current = code
        state.lock.unlock()
        return code
    }

    /// The code in effect.
    public static var currentLanguage: String {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.current
    }

    /// What dates, month names and weekdays should be formatted in: the *chosen* language rather
    /// than the system's, so the switcher's "Today" and its weekday column never disagree.
    public static var locale: Locale { Locale(identifier: currentLanguage) }

    /// The catalog that best matches a `Locale`, for callers that are handed one explicitly — which
    /// is how the date tests stay deterministic whatever language the app is in.
    public static func language(for locale: Locale) -> String {
        let available = availableLanguages.map(\.code)
        return Bundle.preferredLocalizations(
            from: available, forPreferences: [locale.identifier(.bcp47)]
        ).first ?? fallbackLanguage
    }

    // MARK: - Lookup

    /// The text for `key` with `{name}` placeholders filled from `arguments`.
    ///
    /// Falls back to English, then to the key itself — visible and greppable, which is what you
    /// want from a string nobody supplied.
    public static func t(
        _ key: String,
        _ arguments: [String: String] = [:],
        language: String? = nil
    ) -> String {
        format(lookup(key, language: language ?? currentLanguage) ?? key, arguments)
    }

    /// A string that depends on a count: `key.one`, `key.other`, … chosen by the language's plural
    /// rule, with `{count}` filled in. Languages without plurals (Chinese, Japanese) supply only
    /// `key.other`.
    public static func plural(
        _ key: String,
        count: Int,
        _ arguments: [String: String] = [:],
        language: String? = nil
    ) -> String {
        let code = language ?? currentLanguage
        let category = pluralCategory(count, language: code)
        var all = arguments
        all["count"] = String(count)

        for candidate in ["\(key).\(category)", "\(key).other", key] {
            if let found = lookup(candidate, language: code) {
                return format(found, all)
            }
        }
        return key
    }

    /// CLDR plural categories, for the languages Plume has needed so far.
    ///
    /// **This is the one place a new language can need code**, and only if its plural rule is not
    /// one of the three below: Russian, Polish and Arabic have more categories than `one`/`other`.
    /// Add a case here, then the extra keys in that language's `strings.json`; the web layer uses
    /// `Intl.PluralRules` and needs nothing.
    public static func pluralCategory(_ n: Int, language: String) -> String {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        switch base {
        case "zh", "ja", "ko", "vi", "th", "id", "ms":
            return "other"
        case "fr", "pt":
            return n == 0 || n == 1 ? "one" : "other"
        default:
            return n == 1 ? "one" : "other"
        }
    }

    private static func lookup(_ key: String, language: String) -> String? {
        ensureLoaded()
        state.lock.lock(); defer { state.lock.unlock() }
        return state.catalogs[language]?[key] ?? state.catalogs[fallbackLanguage]?[key]
    }

    /// `{name}` → value. A placeholder with no argument is left as written so the gap is visible.
    static func format(_ template: String, _ arguments: [String: String]) -> String {
        guard !arguments.isEmpty, template.contains("{") else { return template }
        var result = template
        for (name, value) in arguments {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }

    // MARK: - Files that are not one-liners

    /// A language's copy of a document such as `welcome.md`, or English's when it has none.
    ///
    /// Markdown with its own file rather than a JSON string, because a translator should be editing
    /// prose with real line breaks — not a 25-line note escaped onto one line of JSON.
    public static func document(_ name: String, language: String? = nil) -> String? {
        ensureLoaded()
        state.lock.lock()
        let directory = state.directory
        let code = language ?? state.current
        state.lock.unlock()
        guard let directory else { return nil }

        for candidate in [code, fallbackLanguage] {
            let url = directory.appendingPathComponent(candidate).appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }
}
