# Naming and layout conventions

How code is named and where it lives. These rules describe the code as it is; where a name looks odd
(`pinPlume`, `plumes`, `.plume-*`) it is odd on purpose, and the section on frozen names says why.

## Layout

```
Sources/PlumeKit/        Foundation only. Anything that can be tested without a window server.
  Notes/  Vault/  GitSync/  Persistence/  Panel/  Input/  Support/
Sources/Plume/           AppKit, WebKit, Carbon. The app itself.
  App/  Panel/  Bridge/  Spaces/  MenuBar/  Services/  Settings/
Tests/PlumeKitTests/     The PlumeKit suite — an executable, not an XCTest target (see Package.swift).
Editor/src/              The web layer: bridge/  markdown/  keyboard/  ui/  styles/
Editor/tests/            unit/ (keyboard tables, run in node)  webview/ (run in a real WKWebView)
App/                     Info.plist, icons and menu bar images that the build copies into the .app
Scripts/                 build, test and CI scripts; tools/ holds the Swift helpers
Design/                  Source artwork, specs and notes. Nothing here is built directly.
```

A new file goes in the folder named for what it is about, not for who calls it. PlumeKit never imports
AppKit; if a type needs it, the type belongs in `Sources/Plume`.

## Vocabulary

| Concept | Word | Not |
|---|---|---|
| The floating window | **Panel** (the `NSPanel` subclass is `PanelWindow`) | Plume, Pane |
| One note | **Note**; a file on disk is a *file* or *filename* | Doc |
| The notes folder | **Vault** | Library |
| ⌘P | **Switcher** | Picker |
| ⌘K | **Action panel** | Command palette |
| The row of formatting buttons | **Format bar** | Toolbar |
| Reacting to a note changed by someone else | **Reconcile** (`VaultReconciler`) | Sync |
| Git and iCloud | **Sync**; Git types carry the `GitSync` prefix | |
| Checking for a newer version | **Release** (`ReleaseCheck`, `ReleaseFetcher`) | Update, except in text users read |
| The development build | **Dev** (`BuildProfile.dev`, "Plume Dev", `Plume-dev`) | Scratch |

`Plume` is the product. It appears in the module name `PlumeKit`, in bundle identifiers and log
subsystems, in the `plumeHost` bridge object, and in the CSS prefix. It is not a word for "the panel".

## Swift

- **One main type per file, and the file is named after it.** An extension lives in `Type+Feature.swift`.
  A small helper that exists only for the main type (a private view, a base class, `StoredFrame` beside
  `PanelState`) may share its file. `main.swift` is the one file named for its role.
- **Role suffixes mean one thing each:**

  | Suffix | Meaning | Examples |
  |---|---|---|
  | `Controller` | Owns a window or view | `PanelController`, `MenuBarController` |
  | `Service` | Does asynchronous I/O on its own queue | `VaultService` |
  | `Store` | Holds one value and persists it | `StateStore`, `SettingsStore` |
  | `Watcher`, `Monitor` | Observes something outside and reports | `VaultWatcher`, `DockSpaceAssignmentMonitor` |
  | `Policy` | A pure decision, no state | `SpaceAssignmentPolicy`, `WritePolicy` |
  | `Engine` | A stateful procedure | `GitSyncEngine` |
  | `Reconciler` | Decides what to do when disk and buffer disagree | `VaultReconciler` |
  | `Fetcher` | Gets something over the network | `ReleaseFetcher` |

  New code uses `Coordinator` for something that wires several services together without owning a view,
  `Scheduler` for something that only decides *when*, and a `-ing` suffix for a protocol that is
  injected so a test can replace it (`VaultServicing`, `Scheduling`).
- Abbreviations are the usual few: `URL`, `ID`, `CSS`, `JSON`, `L10n`.
- A test file is `<Subject>Tests.swift` with an entry point `run<Subject>Tests()`. Names such as `More`
  or `Misc` say nothing about what is inside; split by topic instead.

## TypeScript

- Files are kebab-case, in the folder for their layer: `bridge/`, `markdown/`, `keyboard/`, `ui/`.
- Identifiers are camelCase, a DOM reference ends in `El` (`panelEl`), module constants are
  UPPER_SNAKE. Module top levels have no side effects, except `main.ts`.
- What the page sends to Swift is typed in `bridge/protocol.ts`; what Swift may call is the `host`
  object in `main.ts`.

## Strings shown to people

Keys are `<surface>.<area>.<element>`, camelCase per segment, with `.one` / `.other` for plurals
(a language that has no singular may supply only `.other`). Do not open a second prefix for a surface
that already has one — `shortcut`, `shortcuts` and `shortcutGroup` are the example to avoid repeating.
`Locales/README.md` explains how to add a language.

## Names that must not change

These are written into users' files, users' themes or other programs, so renaming one breaks something
this repository cannot repair. They are checked by tests; a refactor that touches one fails them.

| Name | Where it lives | Checked by |
|---|---|---|
| `plumes` (the panel list in `state.json`), every other key in `state.json` and `settings.json` | the user's disk | `CompatibilityTests` and its fixtures |
| `pinPlume` (the key of the pin shortcut in `settings.json`) | the user's disk | `CompatibilityTests` |
| `.plume-*`, `.plume`, `.plume__*`, `#plume*`, `data-plume-*`, and the CSS custom properties | user themes in `~/Library/Application Support/Plume/Themes` | `Editor/tests/theme-contract.mjs`, `theme-api.txt` |
| `window.plumeHost`, `messageHandlers.plume`, the message and host method names | both ends of the bridge | `Tests/PlumeKitTests/Bridge/BridgeContractTests.swift` (reads `Editor/src/bridge/protocol.ts`) |
| Bundle identifiers, `Plume` and `Plume (Debug)` support folders, the `PlumeScratchBuild` Info.plist key | macOS | CI bundle checks, `Scripts/test-dev-isolation.sh` |

The Swift property that holds the panel list is `AppState.panels`; its `CodingKeys` entry writes it as
`plumes`. Changing a stored name, when it has to be done, needs all of: reading the old name, a stated
rule for which name is written, an updated snapshot test explained in the pull request, and a line in
`CHANGELOG.md`.

## Comments

A comment must be understandable from this repository alone. Give the reason in the comment.

Do not refer to numbered entries of a private decision record, to design-frame identifiers, or to
files that are not in the repository. `Scripts/check-doc-refs.sh` counts such references and fails when
the number goes up; the count is being worked down to zero, and a rewrite should keep the facts —
measurements, the failure that prompted the rule — and drop only the pointer. Discuss trade-offs in the
commit message or pull request; keep the constraint and its reason in the code.

Code comments are English.
