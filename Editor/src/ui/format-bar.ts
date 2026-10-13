/*
 * The format bar — design frame 2b.
 *
 * Every button is a text edit. There is no rich-text model to toggle: wrapping a selection in `**`
 * inserts two pairs of asterisks into the document, exactly as typing them would. That is decision 5
 * holding at the UI layer — the buffer is the markdown, all the way up.
 *
 * The bar replaces the footer row rather than stacking below it (the panel's CSS does that), and its
 * active state is a pressed fill, never the accent.
 */

import type { EditorView } from "@codemirror/view";
import { describe } from "./tooltip";
import { onLanguageChange, t } from "../i18n";
import { activeMarks, applyLink, applyWrap, applyWrapPair, enclosingPair, pendingPair } from "../format/inline";
import { applyBulletList, applyCodeBlock, applyOrderedList, applyQuote, applyTaskList } from "../format/block";

// What the rest of the app takes from here: the keys, the one block command the heading menu calls,
// and the pending-wrap hooks. They live in `format/`; these re-exports keep the import paths stable.
export { MARKDOWN_FORMAT_KEYS } from "../format/keys";
export { setHeading } from "../format/block";
export { pendingPair, pendingWrapExtension } from "../format/inline";

interface Button {
  label: string;
  /** Catalog key for the name (`editor.format.bold`) — the text is not a literal here. */
  name: string;
  /** The key cap printed after the name. These keys are fixed, so it is not translated. */
  keys: string;
  className?: string;
  /** Wraps the selection, e.g. "**" for bold. */
  wrap?: string;
  /** Anything the two simple shapes above can't express. */
  custom?: (view: EditorView) => void;
  svg?: string;
  /**
   * Lezer node names that mean this button is on. Without these the pressed fill in `plume.css` has
   * nothing to key off and can never render — which is exactly what the design audit found.
   */
  active?: string[];
  /** Names that *cancel* `active` — see the bullet button, which a task would otherwise light. */
  inactiveWith?: string[];
  /**
   * The same, for the two constructs the parser has no node for (decision 61). Underline and
   * highlight were the only buttons on the bar that could never draw themselves pressed, which
   * made them the only two you could not tell the state of without reading the note.
   */
  activePair?: [string, string];
}

/**
 * One wrapper for every drawn icon in the panel's chrome, so the grid, the stroke and the terminals
 * are stated once instead of per icon.
 *
 * The icons are **Lucide** (ISC), inlined as path data rather than pulled in as a dependency — same
 * `<svg>` strings the hand-drawn ones were, from a set that was designed against itself. What they
 * buy is the thing hand-drawing could not: one 24-unit grid, one stroke weight, round terminals, and
 * optical sizing already done. The set before this had seven rendered sizes across the app and four
 * stroke weights on one bar, because every icon was authored on its own.
 *
 * `SIZE` is 14 and `STROKE` is 2.25 rather than Lucide's own 2, and both numbers are derived rather
 * than picked: 14px in the 26px button leaves exactly 6px a side (13 left it on a half-pixel), and
 * 2.25 user units on a 24-unit grid rendered at 14 is 1.31px on screen — the weight the bar was
 * already tuned to, and close enough to the letterforms' stems that a drawing sits beside a B
 * without reading heavier.
 *
 * Deliberately *not* applied to Bold, Italic, Strikethrough and Underline: those stay as type,
 * because each one is rendered in the effect it applies. The B is bold, the I is italic, the U is
 * underlined. No drawn glyph can do that, and it is worth more than a uniform visual language.
 */
const ICON_SIZE = 14;
const ICON_STROKE = 2.25;

export function icon(body: string, size = ICON_SIZE): string {
  return (
    `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" ` +
    `stroke-width="${ICON_STROKE}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">` +
    `${body}</svg>`
  );
}

const SEPARATOR: unique symbol = Symbol("separator");

/*
 * The bar, in groups, and the groups are by **what the mark applies to** — which is the rule the
 * separators had never actually followed.
 *
 *   Heading · Bold · Italic · Strikethrough · Underline · Highlight   marks on characters
 *   Inline code · Code block · Link · Quote                           inline objects and containers
 *   Numbered · Bulleted · Task                                        lists
 *
 * Underline and Highlight used to sit in the second group, which made it a catch-all of six: two
 * character marks, two inline constructs and two block containers, sharing a run for no reason
 * anybody had written down. They are decision 61's pair and they are the same *kind* of thing as
 * bold and italic — a mark on a span of characters — so they belong beside them. Heading leads the
 * run rather than standing alone because a paragraph-style control at the head of the text-format
 * group is what every toolbar does, and it reads as "how this text looks" with the rest.
 */
const BUTTONS: (Button | typeof SEPARATOR)[] = [
  {
    label: "B",
    name: "editor.format.bold",
    keys: "⌘B",
    className: "format-bar__bold",
    wrap: "**",
    active: ["StrongEmphasis"],
  },
  { label: "I", name: "editor.format.italic",
    keys: "⌘I", className: "format-bar__italic", wrap: "*", active: ["Emphasis"] },
  {
    label: "S",
    name: "editor.format.strikethrough",
    keys: "⇧⌘S",
    className: "format-bar__strike",
    wrap: "~~",
    active: ["Strikethrough"],
  },
  {
    label: "U",
    name: "editor.format.underline",
    keys: "⌘U",
    className: "format-bar__underline",
    custom: (view: EditorView) => applyWrapPair(view, "<u>", "</u>"),
    activePair: ["<u>", "</u>"],
  },
  {
    label: "",
    name: "editor.format.highlight",
    keys: "⇧⌘M",
    custom: (view: EditorView) => applyWrap(view, "=="),
    activePair: ["==", "=="],
    svg: icon(`<path d="m9 11-6 6v3h9l3-3" /><path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4" />`),
  },
  SEPARATOR,
  {
    label: "",
    name: "editor.format.inlineCode",
    keys: "⌘E",
    wrap: "`",
    active: ["InlineCode"],
    // The one letterform that had to go. `</>` set three characters in a 26px box and measured
    // 20.8×12.3 — 2.4× the width of the B beside it, and the widest thing on the bar. Unlike B, I,
    // S and U it was never a specimen of its own effect either: inline code is not spelled `</>`.
    svg: icon(`<path d="m16 18 6-6-6-6" /><path d="m8 6-6 6 6 6" />`),
  },
  {
    label: "",
    name: "editor.format.codeBlock",
    keys: "⌥⌘C",
    custom: applyCodeBlock,
    active: ["FencedCode"],
    svg: icon(`<path d="m10 9-3 3 3 3" /><path d="m14 15 3-3-3-3" /><rect x="3" y="3" width="18" height="18" rx="2" />`),
  },
  {
    label: "",
    name: "editor.format.link",
    keys: "⌘L",
    custom: applyLink,
    active: ["Link"],
    svg: icon(`<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" /><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />`),
  },
  {
    label: "",
    name: "editor.format.quote",
    keys: "⇧⌘B",
    custom: applyQuote,
    active: ["Blockquote"],
    svg: icon(`<path d="M17 5H3" /><path d="M21 12H8" /><path d="M21 19H8" /><path d="M3 12v7" />`),
  },
  SEPARATOR,
  // Numbered before bulleted, matching the reference bar. Reads as an ordering of increasing
  // looseness — numbered, bulleted, then tasks — rather than the arbitrary pair it was.
  {
    label: "",
    name: "editor.format.orderedList",
    keys: "⇧⌘7",
    custom: applyOrderedList,
    active: ["OrderedList"],
    svg: icon(`<path d="M11 5h10" /><path d="M11 12h10" /><path d="M11 19h10" /><path d="M4 4h1v5" /><path d="M4 9h2" /><path d="M6.5 20H3.4c0-1 2.6-1.925 2.6-3.5a1.5 1.5 0 0 0-2.6-1.02" />`),
  },
  {
    label: "",
    name: "editor.format.bulletList",
    keys: "⇧⌘8",
    custom: applyBulletList,
    active: ["BulletList"],
    // A task is a bullet in the tree — `BulletList` > `ListItem` > `Task` — so this lit alongside
    // Task list on every checkbox, which reads as the line being two kinds of list at once. The
    // three are one control with three values, so the most specific wins.
    inactiveWith: ["Task"],
    svg: icon(`<path d="M3 5h.01" /><path d="M3 12h.01" /><path d="M3 19h.01" /><path d="M8 5h13" /><path d="M8 12h13" /><path d="M8 19h13" />`),
  },
  {
    label: "",
    name: "editor.format.taskList",
    keys: "⇧⌘9",
    custom: applyTaskList,
    active: ["Task"],
    svg: icon(`<path d="M13 5h8" /><path d="M13 12h8" /><path d="M13 19h8" /><path d="m3 17 2 2 4-4" /><path d="m3 7 2 2 4-4" />`),
  },
];

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** The heading level at the caret, or null when the line is not a heading. */
function currentHeadingLevel(view: EditorView): number | null {
  const marks = activeMarks(view.state);
  for (const level of [1, 2, 3, 4, 5, 6]) {
    if (marks.has(`ATXHeading${level}`)) return level;
  }
  return null;
}

export function mountFormatBar(
  root: HTMLElement,
  view: EditorView,
  onClose: () => void,
  onHeadingMenu: (buttonRect: Rect, currentLevel: number | null) => void
): { refresh: () => void } {
  root.innerHTML = "";

  /** Every button that declares an active state, so `refresh` is a walk rather than a re-query. */
  const stateful: {
    element: HTMLButtonElement;
    names: string[];
    unless: string[];
    pair?: [string, string];
    wrap?: string;
  }[] = [];

  // The heading control is a dropdown, as the design draws it: H1, H2 and H3 with their shortcuts.
  // A single "H" button could only ever mean H1, which makes the other two levels undiscoverable.
  const heading = document.createElement("button");
  heading.className = "format-bar__heading";
  const nameables: (() => void)[] = [() => describe(heading, t("editor.format.heading"))];
  heading.setAttribute("aria-haspopup", "true");
  heading.innerHTML = `H<svg class="format-bar__chevron" width="7" height="5" viewBox="0 0 7 5" aria-hidden="true"><path d="M0.5 1.2 3.5 4 6.5 1.2" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
  root.appendChild(heading);
  stateful.push({
    element: heading,
    names: ["ATXHeading1", "ATXHeading2", "ATXHeading3", "ATXHeading4", "ATXHeading5", "ATXHeading6"],
    unless: [],
  });

  // The menu itself is native, opened by Swift.
  //
  // It was a DOM popup, and a DOM popup cannot go where this one needs to go: the format bar sits at
  // the bottom of the panel, so the list has to hang *below* it — past the window's own edge. Anything
  // rendered in the web view is clipped to the window, so opening upward over the note was the only
  // option and it covered the text you were about to format.
  //
  // An NSMenu also brings its dismissal rules with it, which is the other half of the problem: it
  // closes on an outside click, on Escape, when the app deactivates, and when the panel is dismissed —
  // all of it handled by AppKit rather than by a pile of listeners here that would each have to be
  // remembered.
  heading.addEventListener("mousedown", (event) => {
    event.preventDefault();
    const rect = heading.getBoundingClientRect();
    onHeadingMenu(
      { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      currentHeadingLevel(view)
    );
  });

  for (const item of BUTTONS) {
    if (item === SEPARATOR) {
      const rule = document.createElement("span");
      rule.className = "format-bar__separator";
      root.appendChild(rule);
      continue;
    }

    const button = document.createElement("button");
    if (item.className) button.className = item.className;
    const tip = () => `${t(item.name)} ${item.keys}`;
    nameables.push(() => describe(button, tip()));
    if (item.svg) button.innerHTML = item.svg;
    else button.textContent = item.label;

    button.addEventListener("mousedown", (event) => {
      // mousedown, not click, and prevented: the editor must never lose the selection the button is
      // about to act on.
      event.preventDefault();
      if (item.custom) item.custom(view);
      else if (item.wrap) applyWrap(view, item.wrap);
    });

    if (item.active || item.activePair) {
      stateful.push({
        element: button,
        names: item.active ?? [],
        unless: item.inactiveWith ?? [],
        pair: item.activePair,
        wrap: item.wrap,
      });
    }
    root.appendChild(button);
  }

  const spacer = document.createElement("span");
  spacer.className = "format-bar__spacer";
  root.appendChild(spacer);

  const rule = document.createElement("span");
  rule.className = "format-bar__separator";
  root.appendChild(rule);

  const close = document.createElement("button");
  close.className = "format-bar__close";
  // The tip carries the key; the accessible name is the plain sentence, as before.
  nameables.push(() => {
    describe(close, `${t("editor.format.close")} ⌥⌘,`);
    close.setAttribute("aria-label", t("editor.format.close"));
  });
  // A filled disc rather than a bare glyph — it reads as "dismiss this bar" rather than as one more
  // formatting button that happens to look like an ✕.
  close.innerHTML = `<svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="7.25" fill="currentColor" opacity="0.16"/><path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`;
  close.addEventListener("mousedown", (event) => {
    event.preventDefault();
    onClose();
    view.focus();
  });
  root.appendChild(close);

  const nameAll = () => nameables.forEach((name) => name());
  nameAll();
  onLanguageChange(nameAll);

  return {
    refresh() {
      // Skipped while the bar is hidden: this runs on every selection change, and parsing the tree
      // to style something nobody is looking at is exactly the kind of cost that shows up as a
      // stutter while typing.
      if (!root.offsetParent) return;
      const marks = activeMarks(view.state);
      const pending = pendingPair(view.state);
      for (const { element, names, unless, pair, wrap } of stateful) {
        const waiting = pending !== null && (pair ? pending.open === pair[0] : pending.open === wrap);
        const on =
          waiting ||
          (!unless.some((n) => marks.has(n)) &&
            (names.some((n) => marks.has(n)) ||
              (pair ? enclosingPair(view.state, pair[0], pair[1]) !== null : false)));
        element.setAttribute("aria-pressed", String(on));
      }
    },
  };
}
