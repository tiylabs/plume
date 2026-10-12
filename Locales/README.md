# Locales

Every string Plume shows lives here — the native UI (menus, Settings, alerts) and the editor
(⌘K, ⌘P, find bar, format bar) read the **same files**. Currently: `en`, `zh-Hans`.

```
Locales/
  en/
    strings.json    flat "key": "text" map
    welcome.md      the first note a new vault gets
  zh-Hans/
    strings.json
    welcome.md
```

## Adding a language

1. Copy `Locales/en/` to `Locales/<code>/`. The code is a BCP 47 tag matching what macOS uses:
   `ja`, `fr`, `de`, `es`, `pt-BR`, `zh-Hant`. **Script matters** — `zh-Hant` is not `zh-Hans`.
2. Translate every value in `strings.json` and the whole of `welcome.md`.
3. Set `"_language"` to the language's name **in its own script** (`日本語`, `Français`). This is
   what the Settings picker prints.
4. Run `Scripts/test.sh`.

That is all. Nothing else names a language: the Settings picker, the editor bundle,
`CFBundleLocalizations` in `Info.plist` and the packaged `.app` are all built by discovering this
folder. The test suite holds your directory to the same rules as the others, and says which key.

## Rules `Scripts/test.sh` enforces

- **Same keys as `en`.** A missing key falls back to English at runtime, but the test fails so it
  does not ship that way. A key `en` doesn't have is a typo or a stale string.
- **Same `{placeholders}`.** `{path}`, `{version}`, `{count}`… are filled in by the code. Keep them
  exactly; a translation can move them but not drop or invent one.
- **No empty values.**
- **`welcome.md`** has a `#` heading, still teaches `⌃⌥Space ⌘N ⌘P ⌘K ⇧⌘/`, names no vault path, and
  ends in exactly one newline.
- Every key the source code uses (`tr("…")`, `L10n.t("…")`, the editor's `t("editor.…")`) exists.

## Key namespaces

| Prefix | Who reads it |
|---|---|
| `editor.*` | The web editor. Inlined into the bundle at build time by `Editor/build.mjs`. |
| everything else | Swift (`tr("key")` in the app, `L10n.t` in PlumeKit). |

## Plurals

A string that depends on a count has one entry per plural category, and the language's own rule
picks between them:

```json
"editor.count.words.one":   "{count} word",
"editor.count.words.other": "{count} words"
```

- English, French, German… use `one` and `other`.
- Chinese, Japanese, Korean, Vietnamese, Thai use `other` **only** — supply no `.one`.
- `other` is required in every language.
- The editor uses `Intl.PluralRules`, so it needs no code for any language. The Swift side has a
  small table, `L10n.pluralCategory` in `Sources/PlumeKit/Support/L10n.swift`. **Only a language with
  more than two categories (Russian, Polish, Arabic…) needs a new case there**, plus the extra
  `.few` / `.many` entries in its `strings.json`.

## Writing a translation

- Keep the **key caps** as they are (`⌘N`, `⌃⌥Space`) — they are symbols, not words.
- `form.labelSuffix` is the punctuation after a Settings label: `:` in English, `：` in Chinese.
- Dates are not in the catalog. Month names and weekdays come from macOS's calendar for the
  language; the catalog only supplies the *shape* (`band.olderMonth`: `{month} {year}` vs
  `{year}年{month}`).
- `"Plume"`, `GitHub`, `iCloud`, `Markdown` and `Finder`'s menu path are product names — translate
  the surrounding words, not these.
- Tooltips are `name + key cap` ("Bold ⌘B"); the key cap is appended by the code.

## Not translated, on purpose

- Language names (each is written in its own script, so you can find yours in a language you can't read).
- Log lines (`NSLog`) and file/folder names on disk.
- The README and docs — those are `README.md` / `README.zh-CN.md`.
