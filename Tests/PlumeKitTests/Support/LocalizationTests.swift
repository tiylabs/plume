import Foundation
import PlumeKit

/// The contract a language directory has to meet, checked against whatever is in `Locales/`.
///
/// **Nothing here names a language except English**, which is the reference. That is the point: a
/// contributor who adds `Locales/ja/` is held to exactly these rules without touching this file, and
/// the failure says which key and which language.
func runLocalizationTests() {
    guard let directory = L10n.bundledDirectory() else {
        Check.suite("Localization") {
            Check.test("the Locales folder is found") {
                Check.expect(false, "no Locales directory beside the checkout — set PLUME_LOCALES")
            }
        }
        return
    }
    L10n.configure(directory: directory)
    defer { L10n.setLanguage(L10n.fallbackLanguage) }

    /// Raw catalogs, read independently of `L10n` so the tests do not trust what they test.
    func table(_ code: String) -> [String: String]? {
        let url = directory.appendingPathComponent(code).appendingPathComponent("strings.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
    let codes = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        .filter { table($0) != nil }.sorted()
    let english = table(L10n.fallbackLanguage) ?? [:]

    /// `editor.count.words.one` and `.other` are one logical string.
    func base(_ key: String) -> String {
        for suffix in [".zero", ".one", ".two", ".few", ".many", ".other"] where key.hasSuffix(suffix) {
            return String(key.dropLast(suffix.count))
        }
        return key
    }
    func placeholders(_ text: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    Check.suite("Localization") {

        Check.test("English exists, and names itself") {
            Check.expect(!english.isEmpty, "Locales/en/strings.json is missing or unreadable")
            Check.equal(english[L10n.nameKey], "English")
        }

        Check.test("every language directory parses and names itself in its own script") {
            let directories = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "README.md" }
            for code in directories {
                Check.expect(table(code) != nil, "\(code)/strings.json is missing or is not a flat string map")
                Check.expect(
                    table(code)?[L10n.nameKey]?.isEmpty == false,
                    "\(code) has no \"\(L10n.nameKey)\" entry, so the picker cannot show it"
                )
            }
        }

        Check.test("the picker lists every language, English first") {
            let listed = L10n.availableLanguages.map(\.code)
            Check.equal(listed.first, "en")
            Check.equal(Set(listed), Set(codes))
        }

        Check.test("no language is missing a key English has") {
            let wanted = Set(english.keys.map(base))
            for code in codes where code != L10n.fallbackLanguage {
                let have = Set((table(code) ?? [:]).keys.map(base))
                Check.expect(
                    wanted.subtracting(have).isEmpty,
                    "\(code) lacks: \(wanted.subtracting(have).sorted().joined(separator: ", "))"
                )
            }
        }

        Check.test("no language has a key English does not (a typo, or a stale string)") {
            let wanted = Set(english.keys.map(base))
            for code in codes where code != L10n.fallbackLanguage {
                let extra = Set((table(code) ?? [:]).keys.map(base)).subtracting(wanted)
                Check.expect(extra.isEmpty, "\(code) has unknown keys: \(extra.sorted().joined(separator: ", "))")
            }
        }

        Check.test("placeholders match English's, so no translation drops {path} or invents one") {
            // Compared per logical key across plural forms: Chinese's `.other` has to carry every
            // placeholder English's `.one` and `.other` do, minus none.
            func union(_ t: [String: String]) -> [String: Set<String>] {
                var out: [String: Set<String>] = [:]
                for (key, text) in t where key != L10n.nameKey {
                    out[base(key), default: []].formUnion(placeholders(text))
                }
                return out
            }
            let reference = union(english)
            for code in codes where code != L10n.fallbackLanguage {
                let mine = union(table(code) ?? [:])
                for (key, expected) in reference {
                    guard let got = mine[key] else { continue }
                    // A translation may omit {count} in a form that has no number in it, but may
                    // never use a placeholder the code does not supply.
                    Check.expect(
                        got.isSubset(of: expected),
                        "\(code) \(key): uses \(got.subtracting(expected).sorted()) which the code never fills"
                    )
                    Check.expect(
                        expected.subtracting(got).subtracting(["count"]).isEmpty,
                        "\(code) \(key): drops \(expected.subtracting(got).subtracting(["count"]).sorted())"
                    )
                }
            }
        }

        Check.test("no value is empty") {
            for code in codes {
                for (key, text) in table(code) ?? [:] {
                    Check.expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(code) \(key) is empty")
                }
            }
        }

        Check.test("plural keys use only categories the language has") {
            // Chinese has `other` alone; English `one` and `other`. A `.one` form in a language
            // whose rule never selects it is dead text a translator thought was live.
            for code in codes {
                let used = (table(code) ?? [:]).keys.compactMap { key -> String? in
                    for suffix in ["zero", "one", "two", "few", "many"] where key.hasSuffix(".\(suffix)") { return suffix }
                    return nil
                }
                let selectable = Set((0...120).map { L10n.pluralCategory($0, language: code) })
                for category in used {
                    Check.expect(selectable.contains(category), "\(code) has a `.\(category)` form its plural rule never selects")
                }
                // And every plural family has the form `other`, the one every rule falls back to.
                for key in (table(code) ?? [:]).keys where key != base(key) {
                    Check.expect(
                        (table(code) ?? [:])["\(base(key)).other"] != nil,
                        "\(code) \(base(key)) has no `.other` form"
                    )
                }
            }
        }

        Check.test("every language has a welcome note with a title line") {
            for code in codes {
                let url = directory.appendingPathComponent(code).appendingPathComponent("welcome.md")
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                Check.expect(!MarkdownDocument.title(of: text).isEmpty, "\(code)/welcome.md is missing or has no heading")
                Check.expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"), "\(code)/welcome.md must end in exactly one newline")
            }
        }

        Check.test("every welcome note teaches the same keys, in whatever words") {
            for code in codes {
                let text = (try? String(contentsOf: directory.appendingPathComponent(code).appendingPathComponent("welcome.md"), encoding: .utf8)) ?? ""
                for key in ["⌃⌥Space", "⌘N", "⌘P", "⌘K", "⇧⌘/"] {
                    Check.expect(text.contains(key), "\(code)/welcome.md never mentions \(key)")
                }
                for path in ["~/Documents", "Documents/Plume", "/Users/"] {
                    Check.expect(!text.contains(path), "\(code)/welcome.md hardcodes \(path)")
                }
            }
        }

        Check.test("the compiled-in English welcome note is the English file") {
            let file = (try? String(contentsOf: directory.appendingPathComponent("en/welcome.md"), encoding: .utf8)) ?? ""
            Check.equal(WelcomeNote.english, file)
        }
    }

    Check.suite("Localization · lookup") {

        Check.test("a key is looked up in the language asked for") {
            Check.equal(L10n.t("menu.quit", language: "en"), "Quit Plume")
        }

        Check.test("a key missing from a language falls back to English, not to the key") {
            // `zz` has no catalog at all, so everything falls through.
            Check.equal(L10n.t("menu.quit", language: "zz"), "Quit Plume")
        }

        Check.test("a key nobody defined shows as itself") {
            Check.equal(L10n.t("no.such.key", language: "en"), "no.such.key")
        }

        Check.test("placeholders are filled, and an unfilled one is left visible") {
            Check.equal(L10n.t("update.toast", ["version": "9.9"], language: "en"), "Plume 9.9 is available")
            Check.equal(L10n.t("update.toast", language: "en"), "Plume {version} is available")
        }

        Check.test("a value containing a placeholder-shaped string is not re-expanded") {
            // A note called "{version}" must not be interpreted as the version.
            Check.equal(
                L10n.t("news.deletedElsewhereTitled", ["title": "{message}"], language: "en"),
                "Deleted on another device: {message}"
            )
        }

        Check.test("English plurals pick one/other") {
            Check.equal(L10n.plural("editor.count.words", count: 1, language: "en"), "1 word")
            Check.equal(L10n.plural("editor.count.words", count: 0, language: "en"), "0 words")
            Check.equal(L10n.plural("editor.count.words", count: 2, language: "en"), "2 words")
        }

        Check.test("a language without plurals uses `.other` for every count") {
            if codes.contains("zh-Hans") {
                Check.equal(L10n.plural("editor.count.words", count: 1, language: "zh-Hans"), "1 个词")
                Check.equal(L10n.plural("editor.count.words", count: 5, language: "zh-Hans"), "5 个词")
            }
        }

        Check.test("a preference resolves to a catalog, and anything unknown follows the system") {
            Check.equal(L10n.resolve(preference: "en", systemLanguages: ["zh-Hans-CN"]), "en")
            Check.equal(L10n.resolve(preference: "system", systemLanguages: ["en-GB"]), "en")
            Check.equal(L10n.resolve(preference: "klingon", systemLanguages: ["en-US"]), "en")
            if codes.contains("zh-Hans") {
                Check.equal(L10n.resolve(preference: "zh-Hans", systemLanguages: ["en"]), "zh-Hans")
                Check.equal(L10n.resolve(preference: "system", systemLanguages: ["zh-Hans-CN", "en"]), "zh-Hans")
                // Script matters: Traditional Chinese must not be handed Simplified text.
                Check.equal(L10n.resolve(preference: "system", systemLanguages: ["zh-Hant-TW"]), "en")
            }
        }

        Check.test("an unsupported system language falls back to English") {
            Check.equal(L10n.resolve(preference: "system", systemLanguages: ["xx-YY"]), "en")
            Check.equal(L10n.resolve(preference: "system", systemLanguages: []), "en")
        }

        Check.test("setLanguage reports what took effect") {
            Check.equal(L10n.setLanguage("klingon", systemLanguages: ["en"]), "en")
            Check.equal(L10n.currentLanguage, "en")
        }
    }

    Check.suite("Localization · every key in the source exists") {

        // The mirror of "no language is missing a key": this is "no call site asks for one that
        // does not exist". Scans the Swift sources for `tr("…")` and `L10n.t("…")`, and the editor's
        // `t("…")` / `plural("…")`, because a typo'd key only shows at runtime, as the key.
        Check.test("every literal key a call site uses is defined in English") {
            let root = directory.deletingLastPathComponent()
            var used: [(key: String, file: String)] = []

            func scan(_ folder: String, pattern: String, extensions: Set<String>) {
                let base = root.appendingPathComponent(folder)
                guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return }
                let regex = try! NSRegularExpression(pattern: pattern)
                for case let file as URL in walker where extensions.contains(file.pathExtension) {
                    guard !file.path.contains("/node_modules/"), !file.path.contains("/dist/"),
                          let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    let range = NSRange(text.startIndex..., in: text)
                    for match in regex.matches(in: text, range: range) {
                        if let r = Range(match.range(at: 1), in: text) {
                            used.append((String(text[r]), file.lastPathComponent))
                        }
                    }
                }
            }
            scan("Sources/Plume", pattern: #"\b(?:tr|L10n\.t|L10n\.plural)\(\s*"([A-Za-z0-9_.]+)""#, extensions: ["swift"])
            scan("Sources/PlumeKit", pattern: #"\bL10n\.(?:t|plural)\(\s*"([A-Za-z0-9_.]+)""#, extensions: ["swift"])
            scan("Editor/src", pattern: #"\b(?:t|plural)\(\s*"(editor\.[A-Za-z0-9_.]+)""#, extensions: ["ts"])
            scan("Editor/src", pattern: #"data-i18n-(?:aria|placeholder)="([A-Za-z0-9_.]+)""#, extensions: ["html"])

            Check.expect(used.count > 80, "found only \(used.count) call sites — the scan is not reading the sources")
            let known = Set(english.keys.map(base))
            for (key, file) in used {
                Check.expect(known.contains(base(key)), "\(file) asks for \"\(key)\", which no catalog defines")
            }
        }
    }
}
