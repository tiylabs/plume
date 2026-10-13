/*
 * Assembling the editor: the CodeMirror extensions, the compartments that let a language switch or a
 * rebind change one of them without rebuilding it, the ⌘K action table that the keymap and the
 * panel share, and the listener that turns a change in the document into a message to Swift.
 *
 * Everything in `main.ts` that is about *what the editor is* and not about what surrounds it.
 */

import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentLess, indentMore } from "@codemirror/commands";
import { deleteMarkupBackward, markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import { Compartment, type Extension, Prec } from "@codemirror/state";
import { EditorView, drawSelection, keymap, placeholder, rectangularSelection } from "@codemirror/view";
import { keyCommand } from "../keyboard/context";
import { chain } from "../keyboard/edit";
import { backspace } from "../keyboard/backspace";
import { deleteToLineStart, deleteWordAtStart, lineEnd, lineStart, selectLineEnd, selectLineStart } from "../keyboard/line-edge";
import { arrowDown, arrowUp, shiftArrowDown, shiftArrowUp } from "../keyboard/arrows";
import { deleteForward } from "../keyboard/delete";
import { caretPlaces } from "../markdown/caret";
import { enterKey } from "../keyboard/enter";
import { shiftEnterKey } from "../keyboard/shift-enter";
import { splitSpans } from "../keyboard/spans";
import { deleteOverMarks, keepPairs, moveOverSeams } from "../keyboard/pairs";
import { openAbove, openAboveLeft, openBelow, openBelowRight } from "../keyboard/fence-exit";
import { moveBlockDown, moveBlockUp, nothing, selectBlockEnd, selectBlockStart } from "../keyboard/move-block";
import { shiftTab, tab } from "../keyboard/tab";
import { livePreview } from "../markdown/live-preview";
import { renumberOrderedLists } from "../markdown/renumber";
import { plumeDialect } from "../markdown/dialect";
import { MARKDOWN_FORMAT_KEYS, pendingWrapExtension } from "../ui/format-bar";
import { t } from "../i18n";
import { findHighlighting } from "../ui/find";
import { send } from "../bridge/send";
import { bulletInputRule, checkboxInputRule, fenceInputRule, ruleInputRule } from "./input-rules";
import { backspaceKey, deleteKey, selectBlockThenAll } from "./select-block";
import { DEFAULT_SHORTCUTS } from "./shortcuts";
import { ctx } from "./ctx";
import { state } from "./state";
import { renderCount, scheduleContentHeight, showTitle } from "./chrome";
import { openSpaceAssignment, toggleActions, toggleFormatBar, toggleSwitcher } from "./overlays";

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
  if (update.docChanged || update.selectionSet) ctx.formatBar?.refresh();
});
export const shortcutsCompartment = new Compartment();
/** The empty-note prompt, in a compartment so a language switch can re-say it without rebuilding the
 * editor. Everything else the language touches is DOM text and is re-rendered by `onLanguageChange`. */
export const placeholderCompartment = new Compartment();
/** The undo history in a compartment, so it is thrown away when the note changes: undo belongs to
 * the note, or ⌘Z after a switch writes the previous note into this one's file (decision 80). */
const historyCompartment = new Compartment();
/** What every ⌘K row does, keyed by the row's id — one table for the panel and the keymap, so a
 * printed shortcut cannot do something different from the click (decisions 17, 68). */
export const actionHandlers: Record<string, () => boolean> = {
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
  findInNote: () => (ctx.find?.open(), true),
  // ⌥⌘F is the macOS convention for find-and-replace and one Raycast leaves free, so decision 39's
  // habit-compatibility rule is untouched. No ⌘K row: the disclosure on the find bar is where
  // anyone would look for it, and decision 17's panel stays at fourteen — the same call decision 51
  // made for Back and Forward.
  findReplace: () => (ctx.find?.openWithReplace(), true),
  // The buffer goes with the message rather than Swift using its own copy. Swift's copy is up to
  // 500 ms stale by design (decision 10's debounce), and a copy that silently omits the last
  // sentence you typed is the kind of bug nobody reports because they blame the paste.
  copyAsMarkdown: () => (send({ type: "copyAsMarkdown", text: ctx.view.state.doc.toString() }), true),
  exportNote: () => (send({ type: "exportNote", text: ctx.view.state.doc.toString() }), true),
  hideFromCapture: () => (send({ type: "toggleHideFromCapture" }), true),
  autoSizing: () => (send({ type: "toggleAutoSizing" }), true),
  // A three-way setting's key opens on its three choices rather than stepping through them blind.
  spaceBehaviour: () => (openSpaceAssignment(), true),
  duplicateNote: () => (send({ type: "duplicateNote", text: ctx.view.state.doc.toString() }), true),
  recentlyDeleted: () => (ctx.switcher.openDeleted(), true),
  renameFile: () => (send({ type: "renameFile" }), true),
};

export function panelShortcuts(bindings: Record<string, string>): Extension {
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
export function baseExtensions(): Extension[] {
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
export function clearHistory(): void {
  ctx.view.dispatch({ effects: historyCompartment.reconfigure([]) });
  ctx.view.dispatch({ effects: historyCompartment.reconfigure(history()) });
}