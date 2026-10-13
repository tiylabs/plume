/*
 * Inline formatting: wrapping a selection in `**`, `_`, `` ` `` or `~~`, taking the wrapper off again,
 * and making a link — as text edits, exactly as typing the characters would.
 *
 * Nothing here knows about the format bar's buttons or the keyboard: the bar and the keymap both call
 * these, which is the point. A wrap that was pressed with no selection waits for its first character
 * (`pendingWrap`), so the pair is never left empty.
 */

import { syntaxTree } from "@codemirror/language";
import { type ChangeSet, type EditorState, type Extension, StateEffect, StateField } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { blocksIn, markerSpanEnd } from "../markdown/blocks";

/**
 * `[label](url)`, which is one of the two things frame 2b draws that had no implementation.
 *
 * With a selection, the selected text becomes the label and the caret lands in the empty target,
 * because the text is the part you already have and the URL is the part you are about to paste.
 * Without one, both halves are empty and the caret goes in the label.
 */
export function applyLink(view: EditorView): void {
  const state = view.state;
  const { from, to } = state.selection.main;

  // No selection: one keystroke carries you through a link — label, then target, then out (165).
  // It used to write a fresh `[]()` every time, so a second press nested a link in the label.
  if (from === to) {
    const move = (anchor: number) => {
      view.dispatch({ selection: { anchor } });
      view.focus();
    };
    // Pressed twice with nothing typed: the empty link comes back out.
    if (state.sliceDoc(from - 1, from + 3) === "[]()") {
      view.dispatch({
        changes: { from: from - 1, to: from + 3 },
        selection: { anchor: from - 1 },
        userEvent: "input",
      });
      view.focus();
      return;
    }
    const link = enclosingNode(state, "Link");
    if (!link) {
      view.dispatch({ changes: { from, insert: "[]()" }, selection: { anchor: from + 1 } });
      view.focus();
      return;
    }
    const labelEnd = link.from + state.sliceDoc(link.from, link.to).lastIndexOf("](");
    // In the target already: out.
    if (from > labelEnd) return move(link.to);
    // At the end of the label: into an empty target, or out past a filled one.
    if (from === labelEnd) return move(state.sliceDoc(link.to - 2, link.to) === "()" ? link.to - 1 : link.to);
    // In the middle of the label: the link comes off and the text stays, caret where it was.
    view.dispatch({
      changes: [
        { from: link.from, to: link.from + 1 },
        { from: labelEnd, to: link.to },
      ],
      selection: { anchor: Math.max(from - 1, link.from) },
      userEvent: "input",
    });
    view.focus();
    return;
  }

  // Already links? Take them off — `[text](url)` back to `text`, because every other button on
  // this bar toggles and this one only ever added.
  const all = spansPerBlock(state, from, to);
  const links = all.map((span) => constructAround(state, span, "[", "Link"));
  if (all.length > 0 && links.every(Boolean)) {
    const changes = links.flatMap((link) => {
      const text = state.doc.sliceString(link!.from, link!.to);
      return [
        { from: link!.from, to: link!.from + 1, insert: "" },
        { from: link!.from + text.lastIndexOf("]("), to: link!.to, insert: "" },
      ];
    });
    const set = state.changes(changes);
    view.dispatch({
      changes: set,
      selection: selectionAround(set, links.map((link) => link!)),
      userEvent: "input",
    });
    view.focus();
    return;
  }

  // One link per block. Across two paragraphs the old version wrote a single `[rest` … `rest]()`
  // spanning the blank line, which is not a link to any parser — the same fault bold had, in the
  // one command that never moved onto the block primitive.
  const spans = spansPerBlock(state, from, to);
  if (spans.length === 0) return;

  const changes = spans.flatMap((span) => [
    { from: span.from, insert: "[" },
    { from: span.to, insert: "]()" },
  ]);
  const set = state.changes(changes);
  // The caret lands in the first link's empty target, because the text is the half you have and
  // the URL is the half you are about to paste.
  const target = set.mapPos(spans[0]!.to, 1) - 1;
  view.dispatch({ changes: set, selection: { anchor: target }, userEvent: "input" });
  view.focus();
}

/**
 * Which formatting the caret is currently inside.
 *
 * Read from the syntax tree rather than from the raw text, so it agrees with what the live preview
 * is rendering — the two would drift immediately if one parsed and the other pattern-matched.
 */
export function activeMarks(state: EditorState): Set<string> {
  const names = new Set<string>();

  // Bias to the left so that having just typed the closing `**` still counts as bold: the caret sits
  // after the construct, and resolving right would land outside it.
  //
  // A cursor rather than a node chain — `TreeCursor.parent()` walks up in place, which avoids naming
  // the node type and the casts that came with it.
  const cursor = syntaxTree(state).cursorAt(state.selection.main.head, -1);
  // Only the innermost list counts. A bullet nested inside a numbered list has both on its ancestor
  // chain, so both buttons lit — true about the caret, and not what the bar is answering. The bar
  // says what *this line* is, and a line has exactly one kind of marker.
  let listSeen = false;
  do {
    const isList = cursor.name === "BulletList" || cursor.name === "OrderedList";
    if (isList) {
      if (listSeen) continue;
      listSeen = true;
    }
    names.add(cursor.name);
  } while (cursor.parent());

  return names;
}

/**
 * The parser node each marker produces, where the parser has one.
 *
 * Used to decide whether a press means "wrap" or "unwrap", from the same walk `activeMarks` uses to
 * decide whether the button looks pressed — so the two can never disagree. Matching on the text
 * instead would get `*` wrong the moment the caret is inside `**bold**`, where the asterisks it
 * would find belong to the construct one level up.
 */
const WRAP_NODES: Record<string, string> = {
  "**": "StrongEmphasis",
  "*": "Emphasis",
  "~~": "Strikethrough",
  "`": "InlineCode",
};

/** The construct of this kind the caret is inside, if any. Same bias as `activeMarks`. */
export function enclosingNode(
  state: EditorState,
  name: string
): { from: number; to: number } | null {
  const cursor = syntaxTree(state).cursorAt(state.selection.main.head, -1);
  do {
    if (cursor.name === name) return { from: cursor.from, to: cursor.to };
  } while (cursor.parent());
  return null;
}

/**
 * The construct of this kind wrapping a *span*, for the per-block toggle.
 *
 * `enclosingNode` asks about the caret, which is one position — right for a caret and wrong for a
 * selection over three paragraphs, where it answers about whichever block the head happens to be
 * in. Pressing ⌘B twice on such a selection un-bolded exactly one of them and left the rest bold.
 */
function constructAround(
  state: EditorState,
  span: { from: number; to: number },
  open: string,
  nodeName: string | undefined
): { from: number; to: number } | null {
  if (!nodeName) return pairAround(state, span, open, open === "<u>" ? "</u>" : open);

  let node = syntaxTree(state).resolveInner(span.from, 1);
  while (node.parent) {
    if (node.name === nodeName && node.from <= span.from && node.to >= span.to) {
      return { from: node.from, to: node.to };
    }
    node = node.parent;
  }
  return null;
}

/**
 * The same question for the two constructs the parser has no node for — `==highlight==` and
 * `<u>underline</u>` (decision 61). Matched on the caret's line, and only when the selection sits
 * *inside* the pair rather than spanning it.
 */
export function enclosingPair(
  state: EditorState,
  open: string,
  close: string
): { from: number; to: number } | null {
  return pairAround(state, state.selection.main, open, close);
}

function pairAround(
  state: EditorState,
  range: { from: number; to: number },
  open: string,
  close: string
): { from: number; to: number } | null {
  // The span may *be* the construct rather than sit inside it — which is exactly what the mapped
  // selection looks like after one press, so without this a second press wrapped it again.
  const text = state.doc.sliceString(range.from, range.to);
  if (text.startsWith(open) && text.endsWith(close) && text.length > open.length + close.length) {
    return { from: range.from, to: range.to };
  }

  const line = state.doc.lineAt(range.from);
  const head = range.from - line.from;
  const tail = range.to - line.from;

  // `==` opens and closes with the same bytes, so searching back from the caret finds the *closing*
  // marker whenever the caret sits just before it — and a press there wrapped again, `==xy====`
  // (165). Pair them left to right instead, the way the line reads.
  if (open === close) {
    let from = 0;
    for (;;) {
      const start = line.text.indexOf(open, from);
      if (start === -1 || start > head) return null;
      const end = line.text.indexOf(close, start + open.length);
      if (end === -1) return null;
      if (end + close.length >= tail) return { from: line.from + start, to: line.from + end + close.length };
      from = end + close.length;
    }
  }

  // Containment, matching what the tree path tests for the constructs that have a node: the
  // construct has to *contain* the span, not sit strictly outside it. Requiring the span to start
  // after the opening delimiter was stricter than bold's rule, so a selection that happened to
  // include a marker — which is what a selection looks like once it has been wrapped once — found
  // nothing and wrapped again.
  const start = line.text.lastIndexOf(open, head);
  if (start === -1 || start > head) return null;
  const end = line.text.indexOf(close, start + open.length);
  if (end === -1 || end + close.length < tail) return null;

  return { from: line.from + start, to: line.from + end + close.length };
}

/**
 * Narrows a range to the text inside it: past the line's marker span, and ignoring whitespace at
 * either end.
 *
 * A delimiter next to a space is not a delimiter: `**select **` is not bold to CommonMark, or to
 * Obsidian, or to anything else that will ever open the file — it renders as four literal
 * asterisks. Double-clicking a word and dragging one character too far is enough to produce it, so
 * the button is not allowed to write it.
 *
 * **And a marker is not text** (153). A range that starts before the line's content — ⌘A, ⇧Home,
 * a drag from the left edge — wrote `**1. Hi**`, which is no longer a list item at all. The caret
 * rule from 151 is enforced for a caret only; this is the same rule for a range, at the one place
 * that turns a range into bytes, so no command can write a marker however the selection was made.
 */
function trimmed(state: EditorState, from: number, to: number): { from: number; to: number } {
  let start = Math.min(Math.max(from, markerSpanEnd(state, state.doc.lineAt(from).number)), to);
  let end = to;
  while (start < end && /\s/.test(state.doc.sliceString(start, start + 1))) start++;
  while (end > start && /\s/.test(state.doc.sliceString(end - 1, end))) end--;
  return { from: start, to: end };
}

/**
 * Removes a construct's delimiters around a caret, and leaves the caret where it was in the text.
 *
 * It used to select the text it had unwrapped, which is right after unwrapping a selection and
 * wrong here: the next key replaced the word (165).
 */
function unwrap(
  view: EditorView,
  node: { from: number; to: number },
  open: number,
  close: number,
  caret: number
): void {
  const textEnd = node.to - open - close;
  view.dispatch({
    changes: [
      { from: node.from, to: node.from + open },
      { from: node.to - close, to: node.to },
    ],
    selection: { anchor: Math.min(Math.max(caret - open, node.from), textEnd) },
    userEvent: "input",
  });
  view.focus();
}

/**
 * The pair a press just wrote with nothing typed into it — `**|**` — so a second press takes it
 * back out rather than wrapping it again. Not when a word follows the closer: `*|*bold**` is the
 * inside of bold's opening marker, not an empty italic.
 */
function emptyPairAt(state: EditorState, at: number, open: string, close: string): boolean {
  return (
    state.sliceDoc(at - open.length, at) === open &&
    state.sliceDoc(at, at + close.length) === close &&
    !/\w/.test(state.sliceDoc(at + close.length, at + close.length + 1))
  );
}

/**
 * The selection, put back around the **text** after markers were placed around it.
 *
 * Not `selection.map(changes)`, which was the bug. That maps both ends the same way and an
 * insertion sitting exactly on an end pushes that end past it — and worse, ⌘A selects a block
 * *including its trailing newline*, so the closing marker was inserted strictly inside the
 * selection and no mapping bias could have saved it. Wrapping `word` left the selection covering
 * `word**\n`.
 *
 * Invisible until a *second, different* button was pressed: ⌘B then ⌘E wrapped that selection and
 * wrote ``**`word**` ``, four literal characters to any parser — decision 64's own rule broken by
 * the selection rather than by the command. The matrix missed it because it presses each command
 * twice and unwrapping reads the syntax tree, so the too-wide selection was still inside the
 * construct and the round trip passed while the state in between was wrong.
 *
 * So the selection is rebuilt from the spans that were actually wrapped rather than mapped from
 * whatever the user had: the first span's start biased **forward** past its opening marker, the
 * last span's end biased **backward** before its closing one.
 */
function selectionAround(
  set: ChangeSet,
  spans: { from: number; to: number }[]
): { anchor: number; head: number } {
  const first = spans[0]!;
  const last = spans[spans.length - 1]!;
  return { anchor: set.mapPos(first.from, 1), head: set.mapPos(last.to, -1) };
}

/**
 * Wraps the selection, or unwraps the construct the caret is already in.
 *
 * The unwrap half used to test whether the *selection text* began and ended with the marker, which
 * is true only if the markers happen to be selected. So selecting a word inside `**bold**` and
 * pressing ⌘B added a second pair — `***bold***` — while the button sat there drawn as pressed,
 * because the pressed state was read from the syntax tree and the toggle was read from a string.
 * Both read the tree now, so a button that says it is on turns off.
 */
export function applyWrap(view: EditorView, marker: string): void {
  toggleWrap(view, marker, marker, WRAP_NODES[marker]);
}

/**
 * Adds a construct, or takes it off — over one caret or over every span a selection covers.
 *
 * One function for all six inline constructs, because they had drifted into three half-paths with
 * a different bug in each: `**` toggled off only the block the caret happened to be in, `<u>` and
 * `==` stopped toggling off at all once a selection spanned more than one line, and only `**` knew
 * about blocks. Off happens only when *every* span is already wrapped, so a mixed selection
 * finishes the job rather than undoing half of it — the rule the list buttons already follow.
 */
function toggleWrap(
  view: EditorView,
  open: string,
  close: string,
  nodeName: string | undefined
): void {
  const state = view.state;
  const { from, to } = state.selection.main;

  // A caret is one position, so one construct. Three answers, for press-type-press-type (165).
  if (from === to) {
    // Pressed twice with nothing typed: the empty pair comes back out.
    if (emptyPairAt(state, from, open, close)) {
      view.dispatch({
        changes: { from: from - open.length, to: from + close.length },
        selection: { anchor: from - open.length },
        userEvent: "input",
      });
      view.focus();
      return;
    }
    const inside = nodeName ? enclosingNode(state, nodeName) : enclosingPair(state, open, close);
    if (!inside) {
      wrapPerBlock(view, open, close, !nodeName);
      return;
    }
    // At the end of its text, the press steps out: the word keeps its style and what you type
    // next does not — how every editor with a bold key behaves.
    if (from === inside.to - close.length) {
      view.dispatch({ selection: { anchor: inside.to } });
      view.focus();
      return;
    }
    // Anywhere else inside, it takes the style off. Length rather than the marker itself:
    // `_italic_` and `*italic*` are one node and both delimiters are one character, so removing by
    // length handles the spelling the user chose.
    unwrap(view, inside, open.length, close.length, from);
    return;
  }

  // Constructs the parser knows span a soft break happily, so they go per block. `==` and `<u>`
  // are matched on a line's text (decision 61), so markup spanning a newline would never render —
  // they go per line.
  const spans = (nodeName ? spansPerBlock : spansPerLine)(state, from, to);
  if (spans.length === 0) return;

  const wrapping = spans.map((span) => constructAround(state, span, open, nodeName));
  if (!wrapping.every(Boolean)) {
    wrapPerBlock(view, open, close, !nodeName);
    return;
  }

  const changes = wrapping.flatMap((found) => [
    { from: found!.from, to: found!.from + open.length, insert: "" },
    { from: found!.to - close.length, to: found!.to, insert: "" },
  ]);
  const set = state.changes(changes);
  view.dispatch({
    changes: set,
    selection: selectionAround(set, wrapping.map((found) => found!)),
    userEvent: "input",
  });
  view.focus();
}

/**
 * The part of each **line** a selection covers, for the two constructs the parser has no node for.
 *
 * `==highlight==` and `<u>…</u>` are matched on the line's text (decision 61) — live preview's
 * patterns are `[^=\n]` and a non-dotall `.`, both of which stop at a newline. So wrapping a ⇧⏎
 * pair as one construct wrote markup that could never render: the text simply lost its styling and
 * nothing said why. Per line, they render.
 */
function spansPerLine(
  state: EditorState,
  from: number,
  to: number
): { from: number; to: number }[] {
  const doc = state.doc;
  const spans = [];
  for (let n = doc.lineAt(from).number; n <= doc.lineAt(to).number; n++) {
    const line = doc.line(n);
    if (line.text.trim() === "") continue;
    const span = trimmed(state, Math.max(from, line.from), Math.min(to, line.to));
    if (span.from < span.to) spans.push(span);
  }
  return spans;
}

/** The part of each block a selection actually covers, trimmed, with the empty ones dropped. */
function spansPerBlock(
  state: EditorState,
  from: number,
  to: number
): { from: number; to: number }[] {
  return blocksIn(state, from, to)
    .map((block) => trimmed(state, Math.max(from, block.from), Math.min(to, block.to)))
    .filter((span) => span.from < span.to);
}

/**
 * Wraps the selection **once per block it covers**, not once across the whole range.
 *
 * `**` over two paragraphs used to produce `**rest` … `rest**`, which is not emphasis to any
 * parser — a delimiter run cannot span a blank line — so the text stopped rendering and nothing
 * explained why. Per block it produces `**rest**` and `**rest**`, which is what the reference does
 * and what the user meant.
 *
 * A paragraph broken with ⇧⏎ is still *one* block, so a selection across those two lines gets one
 * pair of markers spanning the newline — correct, because a soft break inside a paragraph is not a
 * block boundary and emphasis crosses it happily.
 */
/**
 * A pair waiting for its first character — decision 148.
 *
 * An empty pair at a line start is a *block* to CommonMark: `~~~~` is a tilde fence, so ⇧⌘S on an
 * empty line drew a code block; `****` is a thematic break; `====` under a paragraph is a setext
 * underline that turns the paragraph into a heading. Every one of them is right again the moment a
 * character sits between the markers, so at a line start the toggle inserts nothing and remembers
 * the pair; the next character typed arrives wrapped, with the caret before the closing marker,
 * exactly where the empty pair would have put it. Any other move — a caret move, another edit —
 * forgets the pair. Mid-line the empty pair stays as it was: nothing there is a block.
 */
const setPendingWrap = StateEffect.define<{ open: string; close: string } | null>();

const pendingWrap = StateField.define<{ open: string; close: string } | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setPendingWrap)) return effect.value;
    return tr.docChanged || tr.selection ? null : value;
  },
});

/** The pair a caret is waiting to type into, for the bar's pressed state. */
export function pendingPair(state: EditorState): { open: string; close: string } | null {
  return state.field(pendingWrap, false) ?? null;
}

export function pendingWrapExtension(): Extension {
  return [
    pendingWrap,
    EditorView.inputHandler.of((view, from, to, text) => {
      const pair = view.state.field(pendingWrap);
      if (!pair || from !== to || text.includes("\n")) return false;
      view.dispatch({
        changes: { from, insert: pair.open + text + pair.close },
        selection: { anchor: from + pair.open.length + text.length },
        userEvent: "input.type",
      });
      return true;
    }),
  ];
}

function wrapPerBlock(
  view: EditorView,
  open: string,
  close: string,
  perLine = false
): void {
  const state = view.state;
  const { from, to } = state.selection.main;

  // No selection: an empty pair at the caret, ready to type between — or, at a line start, a pair
  // that waits for the first character (148).
  if (from === to) {
    const line = state.doc.lineAt(from);
    // "At a line start" is the **marker span**, not whitespace (151). On `1. ` the text before the
    // caret trims to `1.`, so the guard read the line as mid-line and wrote `1. ****` — a thematic
    // break inside the item, drawn as a rule, which is decision 148's own fault in a list.
    if (from <= markerSpanEnd(state, line.number)) {
      view.dispatch({ effects: setPendingWrap.of({ open, close }) });
    } else {
      view.dispatch({
        changes: { from, insert: open + close },
        selection: { anchor: from + open.length },
        userEvent: "input",
      });
    }
    view.focus();
    return;
  }

  const wrapped = (perLine ? spansPerLine : spansPerBlock)(state, from, to);
  const changes: { from: number; to?: number; insert: string }[] = [];
  for (const span of wrapped) {
    changes.push({ from: span.from, insert: open });
    changes.push({ from: span.to, insert: close });
  }
  if (changes.length === 0) return;

  const set = state.changes(changes);
  view.dispatch({ changes: set, selection: selectionAround(set, wrapped), userEvent: "input" });
  view.focus();
}

/**
 * Wraps the selection in a pair that is not the same at both ends — `<u>` … `</u>`.
 *
 * `applyWrap` above takes one marker and uses it twice, which every markdown construct but this one
 * allows. Toggling off is the same test in two halves: text already wrapped in the pair loses it.
 */
export function applyWrapPair(view: EditorView, open: string, close: string): void {
  toggleWrap(view, open, close, undefined);
}
