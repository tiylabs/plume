/*
 * The panel's web layer.
 *
 * Owns the editor, the chrome, the switcher and the format bar. Owns no truth: every note, every
 * pin and every setting arrives from Swift, and every change goes back the same way. The web layer
 * never touches a file.
 *
 * IPC is decision 4's: `WKScriptMessageHandler` inbound (window.webkit.messageHandlers.plume), and
 * `evaluateJavaScript` outbound, which lands on `window.plumeHost`.
 */

import "./styles/tokens.css";
import "./styles/plume.css";
import "./styles/markdown.css";
import "./styles/switcher.css";
import "./styles/action-panel.css";

import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentLess, indentMore } from "@codemirror/commands";
import {
  deleteMarkupBackward,
  markdown,
  markdownLanguage,
} from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import {
  Compartment,
  EditorState,
  type Extension,
  Prec,
} from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  keymap,
  placeholder,
  rectangularSelection,
} from "@codemirror/view";

import { mountActionPanel } from "./ui/action-panel";
import { placeOverlay } from "./ui/overlay";
import { describe, mountTooltips } from "./ui/tooltip";
import { findHighlighting, mountFind } from "./ui/find";
import { keyCommand } from "./keyboard/context";
import { chain } from "./keyboard/edit";
import { backspace } from "./keyboard/backspace";
import { deleteToLineStart, deleteWordAtStart, lineEnd, lineStart, selectLineEnd, selectLineStart } from "./keyboard/line-edge";
import { arrowDown, arrowUp, shiftArrowDown, shiftArrowUp } from "./keyboard/arrows";
import { deleteForward } from "./keyboard/delete";
import { caretPlaces } from "./markdown/caret";
import { enterKey } from "./keyboard/enter";
import { shiftEnterKey } from "./keyboard/shift-enter";
import { splitSpans } from "./keyboard/spans";
import { deleteOverMarks, keepPairs, moveOverSeams } from "./keyboard/pairs";
import { openAbove, openAboveLeft, openBelow, openBelowRight } from "./keyboard/fence-exit";
import { moveBlockDown, moveBlockUp, nothing, selectBlockEnd, selectBlockStart } from "./keyboard/move-block";
import { shiftTab, tab } from "./keyboard/tab";
import { livePreview } from "./markdown/live-preview";
import { renumberOrderedLists } from "./markdown/renumber";
import { plumeDialect } from "./markdown/dialect";
import { mountSwitcher } from "./ui/switcher";
import { MARKDOWN_FORMAT_KEYS, mountFormatBar, pendingWrapExtension } from "./ui/format-bar";
import { onLanguageChange, t, translateStaticMarkup } from "./i18n";
import { bulletInputRule, checkboxInputRule, fenceInputRule, ruleInputRule } from "./editor/input-rules";
import { backspaceKey, deleteKey, selectBlockThenAll } from "./editor/select-block";
import { DEFAULT_SHORTCUTS, keyCaps, matchesBinding } from "./editor/shortcuts";
import { send } from "./bridge/send";
import { createHost } from "./bridge/host";
import type { HostAPI } from "./bridge/protocol";
import { actionsEl, bannerEl, closeEl, editorHost, panelEl, switcherEl } from "./editor/dom";
import { ctx } from "./editor/ctx";
import { state } from "./editor/state";
import { renderCount, reportDragRegions, scheduleContentHeight, showTitle } from "./editor/chrome";

// ---------------------------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------------------------

declare global {
  interface Window {
    plumeHost: HostAPI;
  }
}

const editorTheme = EditorView.theme({
  "&": { height: "100%" },
  ".cm-scroller": { fontFamily: "var(--font-ui)", lineHeight: "var(--line-height)" },
});

function notifyEdited(view: EditorView): void {
  const text = view.state.doc.toString();
  renderCount(text);
  showTitle(view.state.doc.iterLines());
  send({ type: "edited", text, caret: view.state.selection.main.head });
  scheduleContentHeight();
}

const updateListener = EditorView.updateListener.of((update) => {
  if (update.docChanged && !state.applyingRemoteEdit) {
    notifyEdited(update.view);
  } else if (update.selectionSet) {
    const head = update.state.selection.main.head;
    send({
      type: "caret",
      caret: head,
      scrollLine: update.state.doc.lineAt(head).number,
    });
  }

  // The format bar's pressed fill follows the caret, so it has to be refreshed on both — a doc
  // change can move in or out of a construct without the selection being "set".
  // Optional because CodeMirror can fire an update during its own construction, before the bar
  // below has been mounted.
  if (update.docChanged || update.selectionSet) formatBar?.refresh();
});

let formatBar: ReturnType<typeof mountFormatBar> | undefined;
/// Declared here rather than at its mount, for the same reason `formatBar` is: `toggleFormatBar`
/// closes the find bar, and a `const` mounted further down would still be in its temporal dead zone.
let find: ReturnType<typeof mountFind> | undefined;

const shortcutsCompartment = new Compartment();

/** The empty-note prompt, in a compartment so a language switch can re-say it without rebuilding the
 * editor. Everything else the language touches is DOM text and is re-rendered by `onLanguageChange`. */
const placeholderCompartment = new Compartment();

/** The undo history in a compartment, so it is thrown away when the note changes: undo belongs to
 * the note, or ⌘Z after a switch writes the previous note into this one's file (decision 80). */
const historyCompartment = new Compartment();


/** What every ⌘K row does, keyed by the row's id — one table for the panel and the keymap, so a
 * printed shortcut cannot do something different from the click (decisions 17, 68). */
const actionHandlers: Record<string, () => boolean> = {
  newNote: () => (send({ type: "createNote", title: "" }), true),
  browseNotes: () => (toggleSwitcher(), true),
  navigateBack: () => (send({ type: "navigate", back: true }), true),
  navigateForward: () => (send({ type: "navigate", back: false }), true),
  pinPlume: () => (send({ type: "togglePin", filename: state.currentFilename }), true),
  formatBar: () => (toggleFormatBar(), true),
  revealInFinder: () => (send({ type: "revealInFinder" }), true),
  settings: () => (send({ type: "openSettings" }), true),
  deleteNote: () =>
    state.currentFilename ? (send({ type: "deleteNote", filename: state.currentFilename }), true) : false,
  findInNote: () => (find?.open(), true),
  // ⌥⌘F is the macOS convention for find-and-replace and one Raycast leaves free, so decision 39's
  // habit-compatibility rule is untouched. No ⌘K row: the disclosure on the find bar is where
  // anyone would look for it, and decision 17's panel stays at fourteen — the same call decision 51
  // made for Back and Forward.
  findReplace: () => (find?.openWithReplace(), true),
  // The buffer goes with the message rather than Swift using its own copy. Swift's copy is up to
  // 500 ms stale by design (decision 10's debounce), and a copy that silently omits the last
  // sentence you typed is the kind of bug nobody reports because they blame the paste.
  copyAsMarkdown: () => (send({ type: "copyAsMarkdown", text: view.state.doc.toString() }), true),
  exportNote: () => (send({ type: "exportNote", text: view.state.doc.toString() }), true),
  hideFromCapture: () => (send({ type: "toggleHideFromCapture" }), true),
  autoSizing: () => (send({ type: "toggleAutoSizing" }), true),
  // A three-way setting's key opens on its three choices rather than stepping through them blind.
  spaceBehaviour: () => (openSpaceAssignment(), true),
  duplicateNote: () => (send({ type: "duplicateNote", text: view.state.doc.toString() }), true),
  recentlyDeleted: () => (switcher.openDeleted(), true),
  renameFile: () => (send({ type: "renameFile" }), true),
};

function panelShortcuts(bindings: Record<string, string>): Extension {
  const run: Record<string, () => boolean> = { ...actionHandlers, actionPanel: () => (toggleActions(), true) };

  return keymap.of(
    Object.entries(run)
      // A binding the user cleared, or one Swift sent for an action this build does not have, drops
      // out rather than registering an undefined key.
      .filter(([action]) => Boolean(bindings[action] ?? DEFAULT_SHORTCUTS[action]))
      .map(([action, handler]) => ({
        key: bindings[action] ?? DEFAULT_SHORTCUTS[action],
        run: handler,
      }))
  );
}

function baseExtensions(): Extension[] {
  return [
    historyCompartment.of(history()),
    drawSelection(),
    rectangularSelection(),
    EditorView.lineWrapping,

    // `addKeymap: false`: the default Enter makes a list loose instead of exiting it (`keyboard/enter.ts`).
    // `autoCloseTags: false`: a typed `<div>` gained a second `</div>`, breaking decision 5
    // (decision 108, amended 2026-09-17).
    markdown({
      base: markdownLanguage,
      // Plume's three rules over CommonMark: markers wait for their space, an item holds text, a
      // quote holds lists (158).
      extensions: plumeDialect,
      addKeymap: false,
      htmlTagLanguage: html({ matchClosingTags: false, autoCloseTags: false }),
    }),

    // Auto-close only the three that help in prose. The CodeMirror default also closes `'` and `"`,
    // which in a document made of sentences is a liability rather than a feature — an apostrophe is
    // not an opening quote.
    markdownLanguage.data.of({ closeBrackets: { brackets: ["(", "[", "`"] } }),
    closeBrackets(),

    livePreview((target) => send({ type: "openLink", target })),
    // Where the caret may rest: past every block marker, never on a break, a fence line or a
    // rule — one filter for every way a caret arrives (146, 151).
    caretPlaces(),
    // No delete takes one marker of a construct and leaves its partner (177).
    keepPairs(),
    findHighlighting(),
    // Ordered lists count themselves. A filter that writes to the document, so it declares the
    // transactions it is *for* rather than the ones it is against — see the file's own note, and
    // decision 81, which is what happened the first time that was the other way round.
    renumberOrderedLists(),
    // An empty note said nothing at all — a caret in a blank rectangle. The reference prompts, and
    // it matters more here than it does there: ⌘N now leaves nothing on disk until the first write,
    // so an empty panel is genuinely a blank page rather than a file that already exists.
    placeholderCompartment.of(placeholder(t("editor.placeholder"))),
    // First among the input rules: a pair waiting at a line start takes the first character (148).
    pendingWrapExtension(),
    checkboxInputRule(),
    bulletInputRule(),
    // The character that completes `---` also steps the caret off the rule it just made (152).
    ruleInputRule(),
    // And the backtick that completes a fence writes the block around the caret (160).
    fenceInputRule(),
    editorTheme,
    updateListener,
    // ⏎, ⇧⏎ and ⌫ are tables over the line under the caret — `keyboard/`, one file per key — and
    // sit above everything else. Each hands what it declines to CodeMirror's own markdown command
    // and then to the plain key. `nonTightLists: false` on the ⏎ delegate is why these are
    // hand-bound at all: CodeMirror's default makes a tight list loose instead of exiting it.
    Prec.high(
      keymap.of([
        // Inside an inline construct, both close it and open it again after the break (171).
        { key: "Shift-Enter", run: splitSpans(shiftEnterKey, "\n") },
        { key: "Enter", run: splitSpans(enterKey, "\n\n") },
        // ⌫ and ⌦ against a construct's marker reach past it to the text (177).
        { key: "Backspace", run: chain(keyCommand(backspace), deleteOverMarks(false, false, backspaceKey), deleteMarkupBackward) },
        // A line's edges are its text's: outside an inline construct, after a block's marker, and
        // ⌥⌫ or ⌘⌫ at the text start is ⌫ (170).
        // ⌥↑ and ⌥↓ move the caret's block, and ⌃⌘↑ and ⌃⌘↓ are the same under Raycast's key;
        // ⇧⌥ selects to the block's edge, and ⌘⌥ is taken so it adds no second caret (174).
        { key: "Alt-ArrowUp", run: moveBlockUp, shift: selectBlockStart },
        { key: "Alt-ArrowDown", run: moveBlockDown, shift: selectBlockEnd },
        { key: "Ctrl-Mod-ArrowUp", run: moveBlockUp },
        { key: "Ctrl-Mod-ArrowDown", run: moveBlockDown },
        { key: "Mod-Alt-ArrowUp", run: nothing },
        { key: "Mod-Alt-ArrowDown", run: nothing },
        { key: "Mod-ArrowLeft", run: lineStart, shift: selectLineStart },
        { key: "Mod-ArrowRight", run: lineEnd, shift: selectLineEnd },
        { key: "Mod-Backspace", run: deleteToLineStart(backspaceKey) },
        { key: "Alt-Backspace", run: chain(deleteWordAtStart(backspaceKey), deleteOverMarks(false, true, backspaceKey)) },
        // ↑ and ↓ step over every line that is not a place, keeping their column (146, 151); ⇧↑ and
        // ⇧↓ do the same with the selection's head (169).
        { key: "ArrowUp", run: chain(openAbove, arrowUp), shift: shiftArrowUp },
        { key: "ArrowDown", run: chain(openBelow, arrowDown), shift: shiftArrowDown },
        // Out of a code block at the note's edge, or next to another block, a line is opened (175).
        { key: "ArrowRight", run: chain(openBelowRight, moveOverSeams(true, false, false)), shift: moveOverSeams(true, false, true) },
        { key: "ArrowLeft", run: chain(openAboveLeft, moveOverSeams(false, false, false)), shift: moveOverSeams(false, false, true) },
        // →, ← and the ⌥ forms never stop between a construct's marker and its text (177).
        { key: "Alt-ArrowRight", run: moveOverSeams(true, true, false), shift: moveOverSeams(true, true, true) },
        { key: "Alt-ArrowLeft", run: moveOverSeams(false, true, false), shift: moveOverSeams(false, true, true) },
        // ⌦ cannot pull a fence or a rule up into the line above (151).
        { key: "Delete", run: chain(keyCommand(deleteForward), deleteOverMarks(true, false, deleteKey)) },
        // …and at a line's end, ⌥⌦ and ⌘⌦ are ⌦: the break goes whole (172).
        { key: "Alt-Delete", run: chain(keyCommand(deleteForward), deleteOverMarks(true, true, deleteKey)) },
        { key: "Mod-Delete", run: keyCommand(deleteForward) },
        { key: "Mod-a", run: selectBlockThenAll },
      ])
    ),

    // Plume's own shortcuts, in their own compartment so the Shortcuts tab can rebind them without
    // rebuilding the editor. Listed before the keymap below so they win over CodeMirror's defaults —
    // within one precedence level, the earlier extension is the higher one.
    shortcutsCompartment.of(panelShortcuts(DEFAULT_SHORTCUTS)),

    keymap.of([
      // Tier 2: the markdown formatting keys, fixed rather than rebindable (see the note on
      // MARKDOWN_FORMAT_KEYS). This is also where "Bold ⌘B" and "Italic ⌘I" stopped being a lie —
      // the format bar has printed those two on its buttons since it shipped while nothing bound
      // them, which is precisely what the comment below this one warns against.
      ...MARKDOWN_FORMAT_KEYS,

      // Text size, also fixed and also convention — ⌘+ / ⌘- / ⌘0 mean this everywhere. The
      // Appearance tab has printed "⌘= / ⌘− in any panel" beside the stepper since it shipped while
      // neither key was bound to anything; ⌘0 comes from the reference, which carries all three.
      // Swift owns the value because it is a setting, so these only ask.
      { key: "Mod-=", run: () => (send({ type: "textSize", action: "in" }), true) },
      // Both spellings, because they are the same physical key. Holding shift makes the browser
      // report `key` as "+", not "=" with a shift flag — so `Mod-Shift-=` never matches and only
      // `Mod-+` does. Measured: with just the Shift- form bound, ⌘+ did nothing while ⌘= worked.
      // ⌘+ is what most people actually press.
      { key: "Mod-+", run: () => (send({ type: "textSize", action: "in" }), true) },
      { key: "Mod--", run: () => (send({ type: "textSize", action: "out" }), true) },
      { key: "Mod-0", run: () => (send({ type: "textSize", action: "reset" }), true) },
      // Escape dismisses the panel. The switcher handles its own Escape while it is open, so this
      // only ever fires with the caret in the editor — where the reflex is "put this away", not
      // "cancel something".
      { key: "Escape", run: () => (send({ type: "close" }), true) },
      // ⇥ and ⇧⇥ nest and un-nest list items (`keyboard/tab.ts`); outside a list they are CodeMirror's.
      { key: "Tab", run: chain(keyCommand(tab), indentMore), shift: chain(keyCommand(shiftTab), indentLess) },
      // After the markdown bindings above, so Backspace only deletes a bracket pair once
      // `deleteMarkupBackward` has declined the position.
      ...closeBracketsKeymap,
      ...defaultKeymap,
      ...historyKeymap,
    ]),
  ];
}

/** Throws the undo stack away: out of the configuration, then back in. Reconfiguring with a fresh
 * `history()` hands back the same field and the same stack — it looks like it works and does nothing
 * (decision 80, amended 2026-09-17; decision 71's genre). */
function clearHistory(): void {
  view.dispatch({ effects: historyCompartment.reconfigure([]) });
  view.dispatch({ effects: historyCompartment.reconfigure(history()) });
}

const view = new EditorView({
  state: EditorState.create({ doc: "", extensions: baseExtensions() }),
  parent: editorHost,
});
ctx.view = view;

// ---------------------------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------------------------

function toggleFormatBar(): void {
  // One footer row, never two (decision 22). Find and the format bar are both that row, so opening
  // either has to put the other away.
  find?.close();
  panelEl.toggleAttribute("data-format-bar");
  formatBar?.refresh();
  // The bar and the footer are different heights, so swapping them changes how much room the note
  // has — and the window has to follow.
  scheduleContentHeight();
  reportDragRegions();
}

/* `mousedown`, and prevented: a click would blur the editor and decision 53 would redraw the note
 * under the pointer. Swapped here rather than after Swift's round trip, or the number lags the press
 * (decision 124). */
document.getElementById("word-count")!.addEventListener("mousedown", (event) => {
  event.preventDefault();
  state.footerCount = state.footerCount === "words" ? "characters" : "words";
  renderCount(view.state.doc.toString());
  send({ type: "toggleFooterCount" });
});

// Named from the first frame rather than from the first edit. The markup ships "0 words" as text
// and nothing had ever set the tip, so an untouched panel had one control the bubble could not name.
renderCount(view.state.doc.toString());

document.getElementById("format-toggle")!.addEventListener("click", toggleFormatBar);
closeEl.addEventListener("click", () => send({ type: "close" }));
document.getElementById("keep-on-top")!.addEventListener("click", () =>
  send({ type: "toggleKeepOnTop" })
);
document.getElementById("new-note")!.addEventListener("click", () =>
  send({ type: "createNote", title: "" })
);
document.getElementById("pin")!.addEventListener("click", () =>
  send({ type: "togglePin", filename: state.currentFilename })
);
document.getElementById("browse")!.addEventListener("click", () => toggleSwitcher());
document.getElementById("open-actions")!.addEventListener("click", () => toggleActions());

/* Every button names itself the same way: one string carries the shortcut and becomes the accessible
 * name, so a key cannot be advertised differently in two places (decision 58). */
mountTooltips(panelEl);

/** The chrome's tooltips read the binding in force, re-read whenever settings arrive — decision 68's
 * rule, its fourth instance (92). */
const CHROME_TIPS: [selector: string, label: string, action: string | null][] = [
  ["#close", "editor.tip.close", null],
  ["#keep-on-top", "editor.tip.keepOnTop", null],
  ["#pin", "editor.tip.unpin", "pinPlume"],
  ["#open-actions", "editor.tip.actions", "actionPanel"],
  ["#browse", "editor.tip.notes", "browseNotes"],
  ["#new-note", "editor.tip.newNote", "newNote"],
  ["#format-toggle", "editor.tip.format", "formatBar"],
  // The find bar's disclosure is the **only** place ⌥⌘F is printed anywhere in the app — it has no
  // ⌘K row (decision 72) and no Shortcuts row. If this string goes stale the key is documented
  // nowhere, which is why it is listed here rather than left as a literal beside its neighbours.
  ["[data-disclosure]", "editor.tip.replace", "findReplace"],
];

function refreshChromeTooltips(): void {
  for (const [selector, labelKey, action] of CHROME_TIPS) {
    const element = document.querySelector<HTMLElement>(selector);
    if (!element) continue;
    // The thumbtack names the thing it will do, so its text follows the state.
    const label = t(
      selector === "#keep-on-top" && panelEl.hasAttribute("data-keep-on-top")
        ? "editor.tip.keepOnTop.on"
        : labelKey
    );
    const binding = action ? state.liveShortcuts[action] ?? DEFAULT_SHORTCUTS[action] : undefined;
    describe(element, binding ? `${label} ${keyCaps(binding).join("")}` : label);
  }
}
// The first call is below, after everything it reads has been built. It used to be that the binding
// table was a `let` declared further down the file, and calling this from up here threw — which took
// out `window.plumeHost` entirely and presented as the whole bridge being missing. The table now
// lives in `state`, so that particular ordering no longer exists; the first call stays where it was.

formatBar = ctx.formatBar = mountFormatBar(
  document.getElementById("format-bar") as HTMLElement,
  view,
  toggleFormatBar,
  (button, level) => send({ type: "headingMenu", button, level })
);

find = ctx.find = mountFind({
  root: document.getElementById("find") as HTMLElement,
  panel: panelEl,
  view,
  onLayoutChange: () => {
    scheduleContentHeight();
    reportDragRegions();
  },
});

/* Both overlays are placed by one calculation whenever the panel opens, its height changes, or the
 * panel's height changes after Swift grows the window (decision 45). One `ResizeObserver`, and `top`
 * changes no size, so it cannot feed itself. */
function placeOverlays(): void {
  placeOverlay(switcherEl, panelEl);
  placeOverlay(actionsEl, panelEl);
}

new ResizeObserver(placeOverlays).observe(switcherEl);
new ResizeObserver(placeOverlays).observe(actionsEl);

const actions = ctx.actions = mountActionPanel({
  root: actionsEl,
  panel: panelEl,
  isPinned: () => panelEl.hasAttribute("data-pinned"),
  isHiddenFromCapture: () => state.hiddenFromCapture,
  isAutoSizing: () => state.autoSizing,
  spaceAssignment: () => state.spaceAssignment,
  dockSpaceAssignment: () => state.dockSpaceAssignment,
  run: (id) => actionHandlers[id]?.(),
  chooseSpace: (mode) => send({ type: "setSpaceAssignment", mode }),
  // The keys a row prints come from the bindings in force, not from a literal beside the label.
  // They were literals, so rebinding New Note in the Shortcuts tab left ⌘K still advertising ⌘N —
  // which is exactly what decision 17 forbids: "a row cannot advertise a key that does something
  // else". Rows with no binding of their own (Settings…, which the menu bar owns) keep the literal.
  keysFor: (id) => (state.liveShortcuts[id] ? keyCaps(state.liveShortcuts[id]) : null),
  onVisibilityChange: (open, height) => {
    send({ type: "actionsOpen", open, height });
    if (!open) view.focus();
  },
});

const switcher = ctx.switcher = mountSwitcher({
  root: switcherEl,
  panel: panelEl,
  onQuery: (query) => send({ type: "requestNotes", query }),
  onOpen: (filename) => send({ type: "openNote", filename }),
  onCreate: (title) => send({ type: "createNote", title }),
  onPin: (filename) => send({ type: "togglePin", filename }),
  onDelete: (filename) => send({ type: "deleteNote", filename }),
  isDeleteKey: (event) => matchesBinding(event, state.liveShortcuts.deleteNote ?? DEFAULT_SHORTCUTS.deleteNote!),
  deleteKeyCaps: () => keyCaps(state.liveShortcuts.deleteNote ?? DEFAULT_SHORTCUTS.deleteNote!).join(""),
  onRequestDeleted: () => send({ type: "requestDeleted" }),
  onRestore: (storedName) => send({ type: "restoreDeleted", storedName }),
  onForgetDeleted: (storedName) => send({ type: "forgetDeleted", storedName }),
  onVisibilityChange: (open, height) => {
    send({ type: "switcherOpen", open, height });
    if (!open) view.focus();
  },
});

/** One slot: opening either panel closes the other first, here rather than at every call site
 * (decision 45). */
function toggleSwitcher(): void {
  actions.close();
  switcher.toggle();
}

function toggleActions(): void {
  switcher.close();
  actions.toggle();
}

function openSpaceAssignment(): void {
  switcher.close();
  actions.openSpaceAssignment();
}

/* Clicking outside an open overlay closes it and never reaches the note. `mousedown`, prevented: by
 * the time a click completes focus has already left the panel's input (decision 52). */
document.getElementById("overlay-scrim")!.addEventListener("mousedown", (event) => {
  event.preventDefault();
  actions.close();
  switcher.close();
});
refreshChromeTooltips();

/** An open overlay's own shortcut closes it: focus is in a plain `<input>` outside CodeMirror, so the
 * keymap never sees the second press. Capture phase, only while open (decision 45). */
document.addEventListener(
  "keydown",
  (event) => {
    // Only while an overlay is up. With the caret in the editor, CodeMirror's keymap is already
    // handling both of these properly and this must stay out of its way.
    if (!actions.isOpen() && !switcher.isOpen()) return;

    const binding = (action: string) => state.liveShortcuts[action] ?? DEFAULT_SHORTCUTS[action] ?? "";

    // Each key keeps its own meaning from inside either panel: it closes its own panel, and swaps
    // to it from the other one. Handling only the closing half left ⌘K doing nothing at all while
    // the switcher was open, which is a different kind of dead key from the one being fixed.
    if (matchesBinding(event, binding("actionPanel"))) {
      event.preventDefault();
      event.stopPropagation();
      actions.isOpen() ? actions.close() : toggleActions();
      return;
    }
    if (matchesBinding(event, binding("browseNotes"))) {
      event.preventDefault();
      event.stopPropagation();
      switcher.isOpen() ? switcher.close() : toggleSwitcher();
    }
  },
  true
);

// ---------------------------------------------------------------------------------------------
// Inbound — everything Swift can ask the web layer to do
// ---------------------------------------------------------------------------------------------

const host = createHost({
  view,
  actions,
  switcher,
  shortcutsCompartment,
  panelShortcuts,
  clearHistory,
  refreshChromeTooltips,
  toggleSwitcher,
  toggleActions,
});

window.plumeHost = host;

/* A language switch re-says everything built once: the static markup, the title and footer count,
 * the empty-note prompt, and every chrome tooltip. Open overlays render fresh each time they open,
 * and Swift closes the Settings window — the only place the switch is made — so none of those can
 * be on screen in the old language. The first call is the initial pass: the HTML ships English. */
function retranslate(): void {
  translateStaticMarkup();
  refreshChromeTooltips();
  view.dispatch({
    effects: placeholderCompartment.reconfigure(placeholder(t("editor.placeholder"))),
  });
  showTitle(view.state.doc.iterLines());
  renderCount(view.state.doc.toString());
}
onLanguageChange(retranslate);
translateStaticMarkup();

/* Hover arrives from Swift (`setHover`): the page's own `mouseenter` only fires once the panel has been
 * clicked (decisions 41, 120). The web layer owns no truth. */

// Clicking the banner acknowledges it. That is the whole dismissal affordance: a conflict banner
// with an ✕ would be a control the user must operate before the panel looks normal again, which is
// the interruption decision 8 rules out.
bannerEl.addEventListener("click", () => host.hideBanner());

// Drag regions only, on every title-bar relayout. Never content height: the window's size is not an
// input to how tall the content wants to be, and reporting it here is what made the panel overshoot
// (decision 40, amended 2026-09-17).
new ResizeObserver(() => {
  reportDragRegions();
  placeOverlays();
}).observe(panelEl);

/* The pin enters and leaves the title bar with the panel's pinned state (decision 54), which moves
 * the buttons beside it — and the drag-exclusion rects Swift hit-tests are measured from those
 * boxes. This is the same hook the title's old scroll-gated reveal needed, pointed at the one
 * attribute that still changes the bar's layout. */
new MutationObserver(reportDragRegions).observe(panelEl, {
  attributes: true,
  attributeFilter: ["data-pinned", "data-keep-on-top"],
});

reportDragRegions();
send({ type: "ready" });
