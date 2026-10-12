/*
 * The ⌘K action panel — design frame 2a.
 *
 * Decision 17: everything that is not pin, switcher or new lives here, which is what lets the title
 * bar hold three icons forever. Built like the switcher and for the same reasons — inside the panel
 * (decision 14 wants every control in its own panel) rather than as a second window that would be a
 * second web view to keep warm.
 *
 * Frame 2a lists thirteen rows and this ships fourteen — all thirteen, plus Duplicate Note, which
 * Raycast carries on ⌘D and decision 39 took across with the rest of its key map.
 *
 * The thirteenth row came back. It was retired on the reasoning that decision 29 had already
 * answered it — a dragged height was a floor, so there was nothing left to switch off — and
 * decision 40 reversed decision 29 outright: a drag now turns auto-sizing OFF and the panel holds
 * that height, so the row is the way back on, on Raycast's own ⇧⌘/.
 *
 * Every row here is a thing Plume actually does, so none of them is a row that does nothing — the
 * same rule the Shortcuts tab follows (decision 31).
 *
 * One row opens rather than runs: Assign to Desktop, which is the Dock's three-way *Assign To* and
 * not a toggle. Its three choices unfold under it in place, the one in force ticked, and ⏎ on one
 * of those is what runs.
 */

import { icon } from "./format-bar";
import { desiredOverlayHeight, pointerMotion } from "./overlay";
import { t } from "../i18n";

export interface ActionRow {
  id: string;
    svg: string;
  /**
   * What to print when the action has no rebindable binding of its own — Settings…, whose ⌘, is the
   * app menu's, and Recently Deleted, which the design deliberately leaves unbound. Every other row
   * prints the binding actually in force; see `keysFor`.
   */
  keys: string[];
  /** Delete is last, red, and separated — the design is explicit about all three. */
  danger?: boolean;
}

interface ActionPanelOptions {
  root: HTMLElement;
  panel: HTMLElement;
  /** Whether the current panel is pinned, so the Pin row can say which way it goes. */
  isPinned: () => boolean;
  /** Same, for the capture toggle. */
  isHiddenFromCapture: () => boolean;
  /** Same, for auto-sizing — which a drag can turn off without anyone pressing this row. */
  isAutoSizing: () => boolean;
  /** Which desktop the panel is assigned to, as Swift last said. */
  spaceAssignment: () => SpaceAssignmentState;
  dockSpaceAssignment: () => DockSpaceAssignmentState;
  run: (id: string) => void;
  /** One of Assign to Desktop's choices was picked: `Settings.SpaceAssignment`'s raw value. */
  chooseSpace: (mode: string) => void;
  /** The key caps to print for a row, from the bindings in force. Null keeps the row's own. */
  keysFor: (id: string) => string[] | null;
  onVisibilityChange: (open: boolean, height: number) => void;
}

/** The panel's Space assignment, from Swift — the page cannot see Spaces. */
export interface SpaceAssignmentState {
  /** `Settings.SpaceAssignment`'s raw value: `unassigned`, `oneSpace` or `everySpace`. */
  mode: string;
  /** The desktop This Desktop names: the one kept to, or the one it would keep to if chosen now. */
  desktop: number | null;
  /** Whether Swift can tell desktops apart at all. Without it there is no This Desktop to offer. */
  canKeepToOne: boolean;
}

/** The system observation takes precedence over Plume's saved assignment. */
export interface DockSpaceAssignmentState {
  mode: "checking" | "unknown" | "unassigned" | "oneSpace" | "everySpace";
  desktop: number | null;
}

/** The row that unfolds, and what unfolds under it — in the Dock's order. */
const SPACE_ROW = "spaceBehaviour";
const SPACE_CHOICES = ["unassigned", "oneSpace", "everySpace"];
const CHECK_SVG = `<path d="M20 6 9 17l-5-5" />`;
const CHEVRON_SVG = `<path d="m6 9 6 6 6-6" />`;

/** A line in the list: a row, or one of the space row's choices under it. */
interface Entry {
  row: ActionRow;
  choice?: string;
  disabled?: boolean;
}

/** Grouped exactly as frame 2a groups them; the hairlines between groups are the grouping. */
const GROUPS: ActionRow[][] = [
  [
    { id: "newNote", svg: `<path d="M5 12h14" /><path d="M12 5v14" />`, keys: ["⌘", "N"] },
    {
      id: "duplicateNote",
      // Two sheets side by side, not the offset pair. This row arrived with decision 39 and took
      // its path from its neighbour, so Duplicate Note and Copy as Markdown drew the *same* icon —
      // and both are visible together every time the panel opens. The design only ever assigned
      // `M3 5h7v8H3zM5 2h7v8` to Copy as Markdown, so that one keeps it and this one gets its own.
      svg: `<rect width="14" height="14" x="8" y="8" rx="2" ry="2" /><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />`,
      keys: ["⌘", "D"],
    },
    { id: "browseNotes", svg: `<path d="M4 5h16" /><path d="M4 12h16" /><path d="M4 19h16" />`, keys: ["⌘", "P"] },
  ],
  [
    {
      id: "pinPlume",
      // The note's pin, the one the title bar and the switcher already draw for a pinned note. Not
      // the thumbtack: that is the panel's own Keep on Top, and the two read as one control.
      svg: `<circle cx="12" cy="8" r="4" /><line x1="12" x2="12" y1="12" y2="21" />`,
      keys: ["⇧", "⌘", "P"],
    },
    {
      id: "findInNote",
      svg: `<path d="m21 21-4.34-4.34" /><circle cx="11" cy="11" r="8" />`,
      keys: ["⌘", "F"],
    },
    {
      id: "copyAsMarkdown",
      svg: `<rect width="8" height="4" x="8" y="2" rx="1" ry="1" /><path d="M8 4H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" /><path d="M16 4h2a2 2 0 0 1 2 2v4" /><path d="M21 14H11" /><path d="m15 10-4 4 4 4" />`,
      keys: ["⇧", "⌘", "C"],
    },
    { id: "revealInFinder", svg: `<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2" />`, keys: ["⌥", "⌘", "R"] },
    {
      id: "exportNote",
      svg: `<path d="M12 3v12" /><path d="m17 8-5-5-5 5" /><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />`,
      keys: ["⇧", "⌘", "E"],
    },
  ],
  [
    {
      id: "autoSizing",
      svg: `<path d="M12 2v20" /><path d="m8 18 4 4 4-4" /><path d="m8 6 4-4 4 4" />`,
      keys: ["⇧", "⌘", "/"],
    },
    { id: "formatBar", svg: `<path d="M12 4v16" /><path d="M4 7V5a1 1 0 0 1 1-1h14a1 1 0 0 1 1 1v2" /><path d="M9 20h6" />`, keys: ["⌥", "⌘", ","] },
    {
      id: "spaceBehaviour",
      // A monitor with its screen split down the middle: the two desktops side by side. Lucide's
      // `monitor` with a centre line, so it keeps the set's stroke and grid.
      svg: `<rect width="20" height="14" x="2" y="3" rx="2" /><line x1="12" x2="12" y1="3" y2="17" /><line x1="8" x2="16" y1="21" y2="21" /><line x1="12" x2="12" y1="17" y2="21" />`,
      keys: ["⌥", "⌘", "S"],
    },
    {
      id: "hideFromCapture",
      svg: `<path d="M12 17v4" /><path d="M17 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 1.184-1.826" /><path d="m2 2 20 20" /><path d="M8 21h8" /><path d="M8.656 3H20a2 2 0 0 1 2 2v10a2 2 0 0 1-.293 1.042" />`,
      keys: ["⇧", "⌘", "H"],
    },
  ],
  [
    {
      id: "settings",
      svg: `<path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915" /><circle cx="12" cy="12" r="3" />`,
      keys: ["⌘", ","],
    },
    {
      id: "recentlyDeleted",
      // A clock, not the trash. This row and Delete Note carried byte-identical path data, and they
      // sit four rows apart in a panel where both are on screen together — the same defect Duplicate
      // Note and Copy as Markdown had, and the smoke test's own rule that two rows never share an
      // icon. Deleting is the bin; this is where things wait, so it is the one that changes.
      svg: `<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" /><path d="M3 3v5h5" /><path d="M12 7v5l4 2" />`,
      // The one row the design gives no shortcut, and it is right: this is a place you go looking
      // for, not a thing you fire off. Decision 31 keeps it out of the Shortcuts table for the
      // same reason — an unbound row there would be a blank waiting to be filled in.
      keys: [],
    },
    {
      id: "renameFile",
      // A tag with a hole in it: this row is about the *file's* name, not the note's title, which is
      // line one and needs no menu item.
      svg: `<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z" /><circle cx="7.5" cy="7.5" r=".5" fill="currentColor" />`,
      // Unbound, and for Recently Deleted's reason exactly: decision 103 makes the name follow the
      // title on its own, so this is the escape hatch for a title improved an hour later — a place
      // you go looking for rather than something you fire off. Decision 31 keeps it out of the
      // Shortcuts table on the same grounds.
      keys: [],
    },
    {
      id: "deleteNote",
      svg: `<path d="M10 11v6" /><path d="M14 11v6" /><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" /><path d="M3 6h18" /><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />`,
      keys: ["⌃", "X"],
      danger: true,
    },
  ],
];

export function mountActionPanel(options: ActionPanelOptions) {
  const { root, panel } = options;
  const search = root.querySelector<HTMLInputElement>(".actions__search")!;
  const list = root.querySelector<HTMLElement>(".actions__list")!;

  let visible: Entry[] = [];
  let selected = 0;
  /** Whether Assign to Desktop's choices are showing. Folded again every time the panel opens. */
  let expanded = false;

  function isOpen(): boolean {
    return panel.hasAttribute("data-actions");
  }

  /** See `desiredOverlayHeight` — shared with the switcher, which used to be a constant in Swift. */
  function desiredHeight(): number {
    return desiredOverlayHeight(root, list);
  }

  /** @param unfoldSpace open on Assign to Desktop's choices, the one in force selected — ⌥⌘S. */
  function open(unfoldSpace = false): void {
    if (isOpen()) return;
    panel.setAttribute("data-actions", "");
    search.value = "";
    expanded = unfoldSpace;
    selected = 0;
    pointer.reset();
    render("");
    // Back to the top, explicitly. The panel opens with row 0 selected, so a list left scrolled by
    // the previous visit shows a different row under the highlight than the one ⏎ will run — which
    // is exactly what happened while this list was capped shorter than its own content.
    list.scrollTop = 0;
    if (unfoldSpace) select(checkedChoiceIndex(), { scroll: true });
    search.focus();
    // Measured rather than assumed: the panel has to grow to hold this, and the panel's height
    // depends on how many rows survived the filter.
    options.onVisibilityChange(true, desiredHeight());
  }

  function close(): void {
    if (!isOpen()) return;
    panel.removeAttribute("data-actions");
    options.onVisibilityChange(false, 0);
  }

  function toggle(): void {
    isOpen() ? close() : open();
  }

  /** ⌥⌘S: straight to the three choices, which is where a three-way setting's key should land. */
  function openSpaceAssignment(): void {
    if (!isOpen()) {
      open(true);
      return;
    }
    search.value = "";
    unfold(true);
  }

  function escapeHtml(text: string): string {
    return text.replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!
    );
  }

  /** Substring, case-insensitive. Fourteen rows do not need fuzzy matching, and fuzzy on a short
   *  fixed list mostly produces surprising matches rather than helpful ones. A search for one of
   *  Assign to Desktop's choices finds the row. */
  function matches(row: ActionRow, query: string): boolean {
    const needle = query.toLowerCase().trim();
    const labels = row.id === SPACE_ROW
      ? [labelFor(row), ...choices().map(choiceLabel)]
      : [labelFor(row)];
    return labels.some((label) => label.toLowerCase().includes(needle));
  }

  /** This Desktop is only offered when Swift can tell desktops apart (decision 31: no dead rows). */
  function choices(): string[] {
    const state = options.spaceAssignment();
    return SPACE_CHOICES.filter((choice) => isSystemAssigned() || choice !== "oneSpace" || state.canKeepToOne);
  }

  function choiceLabel(choice: string): string {
    const dock = options.dockSpaceAssignment();
    if (isSystemAssigned() && choice === dock.mode) {
      if (choice === "oneSpace" && dock.desktop !== null) {
        return t("editor.action.dockSpaceAssignment.oneSpaceNumbered", { number: String(dock.desktop) });
      }
      return t("editor.action.dockSpaceAssignment.system", { value: t(`editor.action.spaceAssignment.${choice}`) });
    }
    const desktop = isSystemAssigned() ? null : options.spaceAssignment().desktop;
    if (choice === "oneSpace" && desktop !== null) {
      return t("editor.action.spaceAssignment.oneSpaceNumbered", { number: String(desktop) });
    }
    return t(`editor.action.spaceAssignment.${choice}`);
  }

  function checkedChoiceIndex(): number {
    const mode = options.spaceAssignment().mode;
    const index = visible.findIndex((entry) => entry.choice === mode && !entry.disabled);
    return index >= 0 ? index : Math.max(0, visible.findIndex((entry) => entry.row.id === SPACE_ROW));
  }

  function labelFor(row: ActionRow): string {
    // The two rows whose label depends on state. "Pin Note" on a pinned note would be a lie about
    // what pressing it does, and the same goes for a panel already hidden from capture — with no
    // checkmark column in this list, the label is the only place the current state can show.
    if (row.id === "pinPlume" && options.isPinned()) return t("editor.action.pinPlume.on");
    if (row.id === "hideFromCapture" && options.isHiddenFromCapture()) {
      return t("editor.action.hideFromCapture.on");
    }
    // This one matters more than the other two, because auto-sizing turns itself off when the panel
    // is dragged (decision 40). The label is the only place that silent change is ever stated.
    if (row.id === "autoSizing" && !options.isAutoSizing()) {
      return t("editor.action.autoSizing.off");
    }
    // The setting in force is in the label, as the toggles' state is: the choices are folded away
    // until asked for, so this is where it shows the rest of the time.
    // One desktop is named by the desktop alone, not "This Desktop (Desktop 3)": the row has the
    // narrowest panel's width to fit in (`narrow.test.js`), and which desktop is the news.
    if (row.id === SPACE_ROW) {
      if (isSystemAssigned()) return systemAssignmentLabel();
      const { mode, desktop } = options.spaceAssignment();
      const value =
        mode === "oneSpace" && desktop !== null
          ? t("editor.action.spaceAssignment.desktop", { number: String(desktop) })
          : choiceLabel(mode);
      return t("editor.action.spaceBehaviour", { value });
    }
    // Every row's name is `editor.action.<id>` in the catalog — not a literal here, which is what
    // lets a language be added without touching this file.
    return t(`editor.action.${row.id}`);
  }

  function isSystemAssigned(): boolean {
    const { mode } = options.dockSpaceAssignment();
    return mode === "oneSpace" || mode === "everySpace";
  }

  function systemAssignmentLabel(): string {
    const { mode, desktop } = options.dockSpaceAssignment();
    const value = mode === "everySpace"
      ? t("editor.action.spaceAssignment.everySpace")
      : desktop === null
        ? t("editor.action.dockSpaceAssignment.assignedDesktop")
        : t("editor.action.spaceAssignment.desktop", { number: String(desktop) });
    return t("editor.action.spaceBehaviour", { value });
  }

  function dockExplanation(): string {
    const { mode } = options.dockSpaceAssignment();
    if (mode === "checking" || mode === "unknown") {
      return t(`editor.action.dockSpaceAssignment.${mode}`);
    }
    if (mode === "unassigned") return "";
    return t("editor.action.dockSpaceAssignment.guidance");
  }

  function render(query: string): void {
    visible = [];
    let html = "";

    for (const group of GROUPS) {
      const rows = group.filter((row) => matches(row, query));
      if (rows.length === 0) continue;

      html += `<div class="actions__group">`;
      for (const row of rows) {
        const index = visible.length;
        visible.push({ row });
        // A search that found the row by one of its choices is a search for that choice, so the
        // choices show without a second step.
        const unfolded = row.id === SPACE_ROW && (expanded || query.trim() !== "");
        const disclosure =
          row.id === SPACE_ROW
            ? `<span class="actions__disclosure">${icon(CHEVRON_SVG, 12)}</span>`
            : "";
        const systemAssigned = row.id === SPACE_ROW && isSystemAssigned();
        const explanation = unfolded ? dockExplanation() : "";
        html += `
          <div class="actions__row${row.danger ? " actions__row--danger" : ""}${systemAssigned ? " actions__row--system-assigned" : ""}"
               role="option" data-index="${index}" aria-selected="${index === selected}"
               ${row.id === SPACE_ROW ? `aria-expanded="${unfolded}"` : ""}
               ${explanation ? 'aria-describedby="dock-space-explanation"' : ""}>
            ${icon(row.svg).replace("<svg ", '<svg class="actions__icon" ')}
            <span class="actions__label">${escapeHtml(labelFor(row))}</span>
            ${disclosure}
            <span class="actions__keys">
              ${(options.keysFor(row.id) ?? row.keys)
                .map((k) => `<kbd>${escapeHtml(k)}</kbd>`)
                .join("")}
            </span>
          </div>`;
        if (unfolded) {
          html += renderChoices(row);
          if (explanation) html += `<div id="dock-space-explanation" class="actions__space-explanation">${escapeHtml(explanation)}</div>`;
        }
      }
      html += `</div>`;
    }

    if (visible.length === 0) {
      html = `<div class="actions__empty">${escapeHtml(t("editor.actions.empty", { query }))}</div>`;
    }
    if (selected >= visible.length) selected = Math.max(0, visible.length - 1);

    list.innerHTML = html;
  }

  /** Assign to Desktop's choices, under it, the one in force ticked. */
  function renderChoices(row: ActionRow): string {
    const disabled = isSystemAssigned();
    const mode = disabled ? options.dockSpaceAssignment().mode : options.spaceAssignment().mode;
    let html = "";
    for (const choice of choices()) {
      const index = visible.length;
      visible.push({ row, choice, disabled });
      html += `
        <div class="actions__row actions__row--choice${disabled && choice === mode ? " actions__row--system-assigned" : ""}" role="option" data-index="${index}"
             aria-selected="${index === selected && !disabled}" aria-checked="${choice === mode}"
             aria-disabled="${disabled}">
          ${icon(CHECK_SVG).replace("<svg ", '<svg class="actions__icon actions__check" ')}
          <span class="actions__label">${escapeHtml(choiceLabel(choice))}</span>
        </div>`;
    }
    return html;
  }

  /** Folds the choices out or away, keeping the selection on the same idea: the choice in force when
   *  they open, the row itself when they close. */
  function unfold(on: boolean): void {
    expanded = on;
    render(search.value);
    const parent = visible.findIndex((entry) => entry.row.id === SPACE_ROW && entry.choice === undefined);
    select(on ? checkedChoiceIndex() : Math.max(0, parent), { scroll: true });
    // Opening is the one time the list grows after the panel was sized for it — the reason reporting
    // once on open was enough no longer holds — so it reports again. Folding away does not: the
    // panel keeps its height rather than jumping under your eyes.
    if (on) options.onVisibilityChange(true, desiredHeight());
  }

  /** Stops at the ends rather than wrapping, for the reason spelled out on the switcher's `move`. */
  function move(delta: number): void {
    if (visible.length === 0) return;
    let index = selected + delta;
    while (index >= 0 && index < visible.length && visible[index]?.disabled) index += delta;
    if (index >= 0 && index < visible.length) select(index, { scroll: true });
  }

  /**
   * There is exactly one selected row, and the pointer moves it.
   *
   * Hover used to paint its own fill on top of the keyboard selection, so moving the mouse across
   * an open panel lit up two rows at once and neither of them was obviously the one ⏎ would run.
   * Letting the pointer *take* the selection is what the reference does and leaves one answer on
   * screen — which matters here more than in most lists, because every row does something.
   */
  function select(index: number, options: { scroll?: boolean } = {}): void {
    if (visible[index]?.disabled) return;
    if (index === selected && !options.scroll) return;
    selected = index;
    list.querySelectorAll<HTMLElement>(".actions__row").forEach((row) => {
      row.setAttribute("aria-selected", String(Number(row.dataset.index) === selected));
    });
    if (options.scroll) {
      list
        .querySelector<HTMLElement>(`[data-index="${selected}"]`)
        ?.scrollIntoView({ block: "nearest" });
    }
  }

  function activate(): void {
    const entry = visible[selected];
    if (!entry || entry.disabled) return;
    // The row with choices under it opens or closes them; it has nothing of its own to run. Under a
    // search they are already showing, so ⏎ goes down to the one in force instead.
    if (entry.row.id === SPACE_ROW && entry.choice === undefined) {
      unfold(search.value.trim() !== "" || !expanded);
      return;
    }
    // Closed before the action runs, not after: several of these change the panel underneath the
    // panel — Browse Notes opens the switcher in the same slot, Delete Note swaps the note out —
    // and a panel still on screen while that happens is a panel describing the wrong panel.
    close();
    if (entry.choice !== undefined) options.chooseSpace(entry.choice);
    else options.run(entry.row.id);
  }

  /** → opens Assign to Desktop's choices, ← closes them from the row or any choice. Anywhere else
   *  both keys belong to the search field's caret. */
  function arrowFolds(key: string): boolean {
    const entry = visible[selected];
    if (!entry || entry.row.id !== SPACE_ROW) return false;
    const open = expanded || search.value.trim() !== "";
    if (key === "ArrowRight" && entry.choice === undefined && !open) {
      unfold(true);
      return true;
    }
    if (key === "ArrowLeft" && open && search.value.trim() === "") {
      unfold(false);
      return true;
    }
    return false;
  }

  // ---- Events -------------------------------------------------------------------------------

  search.addEventListener("input", () => {
    selected = 0;
    render(search.value);
    // Deliberately no height report here — the panel keeps whatever height opening this panel asked
    // for, however far the filter narrows the list.
    //
    // This used to re-report on every keystroke, and the switcher's `reportHeight` explains why it
    // does not: "a window that resizes on every keystroke of a search is a window that will not sit
    // still". ⌘K was exempted on the grounds that it "has fourteen rows and settles" — true while
    // this list had no cap, when the panel was sized to the note and filtering barely moved it.
    // **Decision 114 ended that.** With a ceiling, opening ⌘K grows the panel to 627pt and typing two
    // characters collapsed it to the height of two rows, which is the whole window jumping while
    // your eyes are on a menu. The reason for the exemption expired with the change that capped it.
    //
    // Reporting once is always enough here, and for the same reason it is enough in the switcher:
    // the panel is at its tallest the moment it opens, with nothing filtered out. A filter can only
    // shrink it, and the panel is already big enough for the largest case.
  });

  search.addEventListener("keydown", (event) => {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        move(1);
        break;
      case "ArrowUp":
        event.preventDefault();
        move(-1);
        break;
      case "Enter":
        event.preventDefault();
        activate();
        break;
      case "ArrowRight":
      case "ArrowLeft":
        if (arrowFolds(event.key)) event.preventDefault();
        break;
      case "Escape":
        event.preventDefault();
        close();
        break;
    }
  });

  // Escape from anywhere in the panel, capture phase — same reasoning as the switcher's: focus can
  // sit on a row or nowhere at all, and an uncaught Escape falls through to CodeMirror, which
  // dismisses the whole panel instead of the panel.
  document.addEventListener(
    "keydown",
    (event) => {
      if (event.key !== "Escape" || !isOpen()) return;
      event.preventDefault();
      event.stopPropagation();
      close();
    },
    true
  );

  const pointer = pointerMotion();
  // `mousemove`, not `mouseover`: a re-render under a resting pointer fires mouseover and would
  // yank the selection to wherever the mouse happens to be sitting. And only a `mousemove` that
  // moved: a scroll under a still pointer sends one too (183).
  list.addEventListener("mousemove", (event) => {
    if (!pointer.moved(event)) return;
    const row = (event.target as HTMLElement).closest<HTMLElement>(".actions__row");
    if (row?.dataset.index) select(Number(row.dataset.index));
  });

  list.addEventListener("mousedown", (event) => {
    const row = (event.target as HTMLElement).closest<HTMLElement>(".actions__row");
    if (!row) return;
    event.preventDefault();
    if (visible[Number(row.dataset.index)]?.disabled) return;
    selected = Number(row.dataset.index);
    activate();
  });

  /** An asynchronous Dock observation can arrive while ⌘K is open. Keep the user's query,
   * selection and scroll position while updating the status and the room it needs. */
  function refresh(): void {
    if (!isOpen()) return;
    const entry = visible[selected];
    const scrollTop = list.scrollTop;
    render(search.value);
    if (entry) {
      const index = visible.findIndex((candidate) => candidate.row.id === entry.row.id && candidate.choice === entry.choice);
      if (index >= 0 && !visible[index]?.disabled) select(index);
      else if (entry.row.id === SPACE_ROW) {
        select(Math.max(0, visible.findIndex((candidate) => candidate.row.id === SPACE_ROW && candidate.choice === undefined)));
      }
    }
    list.scrollTop = scrollTop;
    options.onVisibilityChange(true, desiredHeight());
  }

  return { open: () => open(), close, toggle, isOpen, openSpaceAssignment, refresh };
}
