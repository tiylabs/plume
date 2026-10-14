# AGENTS.md

Guidance for coding agents working in this repository. Read this before touching anything; the
referenced documents go deeper on specific topics.

## What this is

**Plume** is a macOS 14+ floating Markdown notes app ("a sheet of glass over whatever you're doing,
that you can write on"). A global hotkey (⌃⌥Space) summons a floating panel over the current app;
notes are plain `.md` files in a user-chosen folder ("vault"), with optional iCloud / Git sync.
No account, no telemetry. MIT licensed; forked from `ColeMei/pane` at commit `526dda4` and
developed independently since. The project was renamed Pane → Plume after v0.3.1075, so old
history and links may still say "pane".

## Architecture at a glance

SwiftPM, no Xcode project — the app builds with only the Command Line Tools. The split is deliberate
(see `Package.swift`'s header comment):

- `Sources/PlumeKit/` — **pure Foundation only**. Filenames, hashing, write model, vault watcher,
  persistence, Git sync, geometry arithmetic, switcher ordering. Everything testable without a
  window server lives here. **PlumeKit must never import AppKit/WebKit/Carbon.**
- `Sources/Plume/` — the app itself: AppKit, WebKit, Carbon. `App/`, `Panel/`, `Bridge/`,
  `Spaces/`, `MenuBar/`, `Services/`, `Settings/`.
- `Editor/` — the web layer (TypeScript, CodeMirror 6) that Plume loads into its WKWebView:
  live-preview Markdown decorations, panel chrome, switcher. Built by esbuild via
  `node build.mjs`; sources in `Editor/src/{bridge,markdown,keyboard,ui,styles,...}`.
- `Tests/PlumeKitTests/` — **an executable target, not XCTest**. Neither XCTest nor swift-testing
  ships with the Command Line Tools, so the suite is a plain executable run by `Scripts/test.sh`.
  Test files are `<Subject>Tests.swift` with an entry point `run<Subject>Tests()`.
- `App/` — Info.plist, icons, menu bar images copied into the .app.
- `Scripts/` — build, test, CI scripts; `Scripts/tools/` holds Swift helpers.
- `Locales/` — all user-visible strings (`en`, `zh-Hans`); the native UI and the editor read the
  **same** files. See `Locales/README.md` to add a language.
- `Themes/` — bundled themes; a user theme is a CSS file in
  `~/Library/Application Support/Plume/Themes`.
- `Design/` — source artwork, specs, notes. **Nothing here is built directly.**

A new file goes in the folder named for what it is about, not for who calls it.

## Commands

```bash
make help       # list all targets
make test-all   # EVERY suite: PlumeKit + editor typecheck + keyboard tables + theme contract
                # + WKWebView suites. This is what CI and the release workflow run.
make test       # just the PlumeKit suite (pure Foundation, no Node needed)
make lint       # editor typecheck + doc-refs check + SwiftLint (if installed)
make dev        # rebuild and launch the isolated build/Plume Dev.app (release app keeps running)
make build      # release build of build/Plume.app
make editor     # rebuild only the web editor bundle
make clean      # remove build outputs
```

Useful subsets:

```bash
Scripts/test-all.sh --only kit        # PlumeKit only, no Node needed
Scripts/test-all.sh --only web        # everything except PlumeKit
Scripts/test-web.sh markdown switcher # just those WKWebView suites
PLUME_TEST_SHARDS=1 Scripts/test.sh   # run PlumeKit as a single process (default is sharded)
```

## Verification expectations

Before considering work done, run the gate that covers what you changed — when in doubt,
`make test-all` (the full list of suites lives in `Scripts/test-all.sh` and **nowhere else**;
a new suite is added there, not to CI configs):

- Swift logic → `Scripts/test.sh` (PlumeKit suite; includes on-disk format compatibility and the
  Swift ⇄ web bridge contract).
- Editor/TypeScript → `cd Editor && npm run typecheck` plus the relevant suites:
  keyboard tables (`Scripts/test-keyboard.sh`), theme contract (`node tests/theme-contract.mjs`),
  and the WKWebView suites (`Scripts/test-web.sh`) which run the real bundle in a real WKWebView —
  they exist because a browser cannot measure layout and a mocked syntax tree would not catch what
  the real parser does with a real selection. Most editor bugs in this project's history came from
  this layer; do not skip it for editor changes.
- Comments that reference documents → `Scripts/check-doc-refs.sh` (the count of references to
  documents not in this repo only goes down).
- SwiftLint if installed: pinned to **0.63.2**; errors fail CI, warnings do not. The length
  thresholds in `.swiftlint.yml` are a **ratchet** set just above the current worst offenders —
  do not grow a file/type/function past them, and do not loosen the thresholds to accommodate new
  code. Bump the pinned version in `ci.yml` and the measured numbers in `.swiftlint.yml` together.

## Branching and commits

`master` is the main branch and the only long-lived one. Work happens on topic branches cut from
`master` (`feat/…`, `fix/…`, `refactor/…`, `docs/…`, `test/…`, `ci/…`) and lands through a pull
request into `master`. A topic branch must be fully green before it is merged — CI runs on every
branch push and on pull requests for exactly this reason. Releases are tags on `master`; the
changelog PR (`changelog/vX.Y.Z`) is opened by CI from the tag, so `CHANGELOG.md` is not edited by
hand.

Commit subjects are checked by CI (`Scripts/check-commit-msg.sh`):

```
type(scope): description          # optional gitmoji after the colon, as the history uses
feat(settings): ✨ Add adjustable panel opacity
fix: the hotkey gives an unfocused panel the focus back
```

Types: `feat|fix|refactor|docs|chore|test|ci|build|perf|style|revert`. Scope optional, lowercase.
`fixup!`/`squash!` commits must never reach a shared branch. Discuss trade-offs in the commit
message or PR; keep the constraint and its reason in the code comment.

## Conventions that matter

`Design/Notes/naming-conventions.md` is the authoritative document — read it before renaming or
reorganizing anything. The load-bearing rules:

- **Vocabulary is fixed**: the floating window is a **Panel**, one note is a **Note**, the notes
  folder is a **Vault**. New coordinating types are `Coordinator` (wires services, owns no view),
  `Scheduler` (decides *when* only), and injected protocols get an `-ing` suffix
  (`VaultServicing`, `Scheduling`).
- **Frozen names must not change** — they are written into users' files, users' themes, or other
  programs, and tests enforce them: `plumes` and every other key in `state.json`/`settings.json`
  (e.g. `pinPlume`); CSS hooks `.plume-*`, `.plume__*`, `#plume*`, `data-plume-*` and the CSS
  custom properties (`Editor/tests/theme-api.txt`); the bridge surface `window.plumeHost`,
  `messageHandlers.plume` and its method names (`Editor/src/bridge/protocol.ts`); bundle
  identifiers and the `Plume` / `Plume (Debug)` support folders. A necessary change to a stored
  name requires: reading the old name, a stated write rule, an updated snapshot test explained in
  the PR, and a `CHANGELOG.md` line.
- **Comments**: must be understandable from this repository alone, state the *reason*, keep
  measurements and failure history, and never cite private decision records or files outside the
  repo. Code comments are in English.
- **TypeScript**: files are kebab-case under their layer folder; camelCase identifiers, DOM refs
  end in `El`, module constants are UPPER_SNAKE; module top levels have no side effects except
  `main.ts`.
- **User-facing strings** live in `Locales/`, keys are `<surface>.<area>.<element>` with
  `.one`/`.other` plural forms; never open a second prefix for a surface that already has one.
  Both `en` and `zh-Hans` must be updated together.

## Repository ethos

- Comments carry the decision record — long explanatory comments are the house style, and lint
  rules are tuned around it (`line_length` is disabled on purpose). Match it.
- Plain files over lock-in: notes, settings (`settings.json`), state (`state.json`) and themes are
  all user-readable files on disk; formats are compatibility-tested. Never break a user's files
  silently.
- Scripts are thin and single-sourced: the Makefile wraps `Scripts/*`; suite lists live in one
  script each; CI calls the same scripts you run locally.
- Releases are signed and notarized (`Scripts/notarize.sh`, `.github/workflows/release.yml`),
  packaged as `.dmg` (`Scripts/make-dmg.sh`), and distributed via Homebrew cask
  (`Packaging/plume.rb`).

## Key references

| Document | What it covers |
|---|---|
| `Package.swift` header | why SwiftPM, why the PlumeKit/Plume split, why tests are an executable |
| `Design/Notes/naming-conventions.md` | layout, vocabulary, frozen names, comment rules |
| `Design/Notes/architecture-refactor-plan.md` | the phased restructuring plan and its acceptance criteria |
| `Design/Notes/dock-space-detection.md` | how Dock "Assign To" is read |
| `Locales/README.md` | adding a language |
| `Scripts/test-all.sh`, `Scripts/test-web.sh` headers | the test suites and why they exist |
| `CHANGELOG.md` | Keep a Changelog format, SemVer, fork history note |
