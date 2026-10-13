# Design

Source artwork and design notes. Nothing here is built into the app directly; the build reads the
generated files in `App/`.

```
Design/
├── Icons/
│   ├── AppIcon.png            final app icon, 1024×1024 — input to make-icons
│   ├── MenuBarIcon.png        final menu bar glyph, 1024×1024, monochrome — input to make-icons
│   └── Explorations/          earlier rounds, kept for the record
│       ├── AppIcon/           icon_00 … icon_05
│       └── MenuBarIcon/       menubaricon_00 … 02, 04 … 07  (there was never a 03)
├── Specs/
│   └── settings-design-spec.md   layout tokens for the Settings window
└── Notes/
    ├── dock-space-detection.md   how the Dock's "Assign To" setting is read
    ├── naming-conventions.md     how code is named and laid out, and the names that must not change
    ├── architecture-refactor-plan.md   the phased plan for restructuring the code, with acceptance criteria
    └── agent-integration-plan.md   local MCP/CLI access, writing context, and coordinated note creation and modification
```

## Which exploration became the final

The finals are byte-for-byte copies of the last exploration in each series:

| Final | Same file as |
|---|---|
| `Icons/AppIcon.png` | `Icons/Explorations/AppIcon/icon_05.png` |
| `Icons/MenuBarIcon.png` | `Icons/Explorations/MenuBarIcon/menubaricon_07.png` |

Everything else in `Explorations/` is a different design that was tried and not taken. Nothing
refers to those files; they are history, not inputs.

## Regenerating the app's icons

The generated files are committed, so an ordinary checkout builds without running any of this. Run it
when the artwork changes:

```bash
swift Scripts/tools/make-icons.swift              # App/AppIcon.icns and App/Resources/MenuBar{,@2x,@3x}.png
swift Scripts/tools/make-icons.swift --app-only   # leave the menu bar images alone
swift Scripts/tools/make-icons.swift --menu-only  # leave the app icons alone
swift Scripts/tools/make-dev-icon.swift           # App/AppIcon-dev.icns, the tinted icon of "Plume Dev"
```

## Adding artwork

- A new round of exploration goes in `Icons/Explorations/<AppIcon|MenuBarIcon>/`, numbered after the
  last one.
- Choosing a final means replacing the same-named file in `Icons/`, regenerating as above, and
  committing the results together.
- A single file over 10 MB is the point to consider Git LFS; the largest here today is about 3 MB.
