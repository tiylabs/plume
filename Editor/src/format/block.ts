/*
 * Block formatting: lists, quotes, code blocks and headings.
 *
 * Defined once because they are pressed two ways — the format bar's buttons and the keyboard — and
 * used to be two implementations that drifted. Each is a text edit: a marker is added, changed or
 * removed at the start of the lines it applies to.
 */

import { syntaxTree } from "@codemirror/language";
import { type EditorState, type Line } from "@codemirror/state";
import type { SyntaxNode } from "@lezer/common";
import type { EditorView } from "@codemirror/view";
import { blockAt, blocksIn, containerPrefixOf, linesOf, quoteMarksOnly } from "../markdown/blocks";
import { enclosingNode } from "./inline";

/**
 * The block commands, defined once because they are pressed two ways.
 *
 * The format bar's buttons and the keyboard shortcuts used to be **two implementations of the same
 * command**, each passing its own literals to `applyBlockMarker`. So fixing the buttons left ⇧⌘7,
 * ⇧⌘8 and ⇧⌘9 doing the old thing, and the matrix — which presses buttons — passed the whole time.
 * That is decision 84 in a new costume: a suite that covers what you built is not one that covers
 * what people do, and people press the key.
 *
 * **Function declarations, not `const` arrows.** The button table is a module-scope array built at
 * import time, so an arrow declared further down is still in its temporal dead zone when the table
 * is constructed — which took out Quote, Bulleted list and Task list entirely, and the matrix said
 * so in fifteen assertions at once.
 */
/** A leading `1. ` or `1) `, which is what "already an ordered list" means. */
const ORDERED_MARKER = /^(\d+)[.)]\s/;

/** A leading `- [ ] ` or `- [x] `. Tested before `BULLET_MARKER`, which it would otherwise match. */
const TASK_MARKER = /^[-*+]\s\[[ xX]\]\s/;

/**
 * A bullet that is **not** a task.
 *
 * The negative lookahead is load-bearing rather than tidy. Without it, pressing Bulleted list on
 * `- [ ] Hi` matched the leading `- ` and "removed" it, leaving `[ ] Hi` — not a task, not a bullet,
 * not a list at all, and the only one of these faults that destroyed structure rather than doubling
 * it.
 */
const BULLET_MARKER = /^[-*+]\s(?!\[[ xX]\]\s)/;

/**
 * Any list marker of any kind, which is what the three list buttons *replace* rather than stack on.
 *
 * The three are one control with three values — a line is a bullet, or numbered, or a task, and
 * never two of those at once. Every command here used to test only for **its own** marker, so a
 * marker of a different kind was invisible to it and the new one went in front: `1. Hi` + Bulleted
 * gave `- 1. Hi`, `- Hi` + Numbered gave `1. - Hi`, and `1. Hi` + Task gave `- [ ] 1. Hi`. Each of
 * those is a list item whose *text* begins with what looks like a marker, so the panel drew both and
 * the format bar lit both buttons — which is how it was reported, as the bullet button looking
 * pressed on a numbered list. The button was telling the truth about a document the commands had
 * corrupted.
 *
 * Task first: `- [ ] ` starts with a bullet, so testing bullets first would match half of it.
 *
 * Blockquote deliberately does not use this. `> - a` is a real thing to want and CommonMark agrees;
 * a quote is a container, and these three are kinds of the same leaf.
 */
const ANY_LIST_MARKER = new RegExp(
  `(?:${TASK_MARKER.source.slice(1)}|${BULLET_MARKER.source.slice(1)}|${ORDERED_MARKER.source.slice(1)})`
);
const ANY_LIST_MARKER_AT_START = new RegExp(`^${ANY_LIST_MARKER.source}`);

/** The leading whitespace of a line, which every marker sits *after* rather than at column zero. */
function indentOf(text: string): number {
  return /^[ \t]*/.exec(text)![0].length;
}

/**
 * The blank line a bare caret is sitting on, and nothing else.
 *
 * `blocksIn` skips blank lines by construction — they belong to no block — which is right for a
 * selection spanning several paragraphs and is why a blank line between two of them does not become
 * an empty list item. Applied to a caret alone on an empty line it meant the four block buttons did
 * **nothing at all**: no marker, no error, no movement. Bold and Code on the same empty line write
 * their markers and put the caret between them, because they are inline commands and an empty
 * selection is a legitimate thing for one to wrap.
 *
 * So the blank line is a case rather than a relaxation of the skip: one caret, one line, no
 * selection. A range that happens to cover only blank lines still yields nothing, which is the
 * behaviour the skip was written for.
 *
 * **A blank line inside a block is not one of these.** `blockAt` returns null only for a line that
 * sits between blocks; inside a fence a blank line is content (decision 90), and a marker written
 * there is three literal characters of code.
 */
function blankCaretLine(state: EditorState): Line | null {
  const range = state.selection.main;
  if (!range.empty || state.selection.ranges.length > 1) return null;
  const line = state.doc.lineAt(range.head);
  // A line of nothing but `> ` is a quote's own blank line, and a block starts on it the same way (150).
  if (quoteMarksOnly(line.text)) return line;
  if (line.text.trim() !== "") return null;
  return blockAt(state, line.from, 1) ? null : line;
}

/**
 * Blocks that a line under them can be *swallowed by* — the ones that do not close themselves.
 *
 * A heading, a fenced code block and a horizontal rule all end at their own last line, so anything
 * written under one is a new block whatever it is. A paragraph does not: CommonMark's lazy
 * continuation pulls the following line into it, and a paragraph inside a list item or a quote does
 * the same from inside them. Measured against the panel's own renderer for all seven, because the
 * tree does not say this and pandoc disagrees with it — see `needsSeparation`.
 */
const CONTINUING_BLOCKS = new Set(["Paragraph", "ListItem", "Blockquote"]);

/** The innermost list open at a line, and the indent of the item that owns it. */
function openList(
  state: EditorState,
  line: Line
): { kind: "bullet" | "ordered"; indent: number } | null {
  if (line.text.trim() === "") return null;
  let node: SyntaxNode | null = syntaxTree(state).resolveInner(
    line.from + indentOf(line.text),
    1
  );
  let item: SyntaxNode | null = null;
  for (; node; node = node.parent) {
    if (node.name === "ListItem" && !item) item = node;
    if (node.name === "BulletList" || node.name === "OrderedList") {
      return {
        kind: node.name === "BulletList" ? "bullet" : "ordered",
        indent: indentOf(state.doc.lineAt((item ?? node).from).text),
      };
    }
  }
  return null;
}

/**
 * Whether a **marker-only** line needs a blank line above it to be the block it looks like.
 *
 * Reported as an indent going weird: press ⏎ in a bullet list, which leaves `- `, then press
 * Numbered. The bytes are `- what\n1. ` and they are not wrong — pandoc reads them as a list and
 * then another list. **The panel's own parser does not**, and the panel is the thing drawing: an
 * *empty* list item cannot interrupt a paragraph, so `1. ` is a lazy continuation of the paragraph
 * inside the item above and the line draws as literal text at the item's text column. Decision 108's
 * lazy continuation again, and the third construct it has turned up in.
 *
 * The two parsers agreeing is not available here — they genuinely disagree — so the fix is to write
 * bytes that cannot be read two ways. A blank line above closes the list and both read it as a new
 * one, which is why `- what\n\n1. ` renders correctly and `- what\n1. ` does not.
 *
 * Three conditions, every one of them measured against the renderer rather than reasoned about:
 *
 *   - **Marker-only.** `- what\n1. x` is fine: an item with content interrupts a paragraph happily,
 *     and so does `- [ ] `, whose `[ ]` *is* content. Only a bare `- ` or `1. ` is empty.
 *   - **Something above that does not close itself.** A heading and a fence close, so `# h\n1. `
 *     and a fence's closing line are both fine. A paragraph, a list item and a quote do not.
 *   - **And not the same list carrying on.** `- what\n- ` is the second item of a list already
 *     open, which needs no interrupting — this is the ⏎ that put the empty item there in the first
 *     place, and separating it would turn a tight list loose.
 */
function needsSeparation(
  state: EditorState,
  line: Line,
  kind: "bullet" | "ordered",
  indent: number
): boolean {
  if (line.number <= 1) return false;
  const above = state.doc.line(line.number - 1);
  if (above.text.trim() === "") return false;
  // Only at the same indent. A marker indented past the line above it is that line's *content* —
  // ⏎ then ⇥ then ⇧⌘7 is how a nested list is started, and separating there writes a blank line
  // into the middle of an item and takes the nesting with it. The nested marker-only line does
  // render as literal text for as long as it stays empty, which is until the next keystroke; that
  // is the trade, and it is the transient half of the fault rather than the one anybody reported.
  if (indent !== indentOf(above.text)) return false;
  const block = blockAt(state, above.from + indentOf(above.text), 1);
  if (!block || !CONTINUING_BLOCKS.has(block.name)) return false;
  const open = openList(state, above);
  return !(open && open.kind === kind && open.indent === indent);
}

/** What kind of list a marker starts, or null for a quote — which interrupts a paragraph fine. */
function kindOf(marker: string): "bullet" | "ordered" | null {
  if (ORDERED_MARKER.test(marker)) return "ordered";
  // A task marker is a bullet, but never a *bare* one: `[ ]` is content, so the item is not empty
  // and nothing above can swallow it.
  if (TASK_MARKER.test(marker)) return null;
  return BULLET_MARKER.test(marker) ? "bullet" : null;
}

/** Whether line `number` is a paragraph — the one neighbour a new block has to be separated from. */
function paragraphBelow(state: EditorState, number: number): boolean {
  if (number < 1 || number > state.doc.lines) return false;
  const line = state.doc.line(number);
  if (line.text.trim() === "") return false;
  return blockAt(state, line.from + indentOf(line.text), 1)?.name === "Paragraph";
}

/**
 * Starts a block on an empty line, with the caret after the marker.
 *
 * **A marker touching a paragraph is not a marker**, and this is decision 108's lazy continuation
 * one construct over — the first draft wrote the marker and nothing else, and pandoc read the
 * results as something nobody typed:
 *
 *     "a\n- "        ->  <h2>a</h2>          <- a setext underline, not a list at all
 *     "a\n1. "       ->  <p>a 1.</p>         <- lazy continuation
 *     "a\n\n- x\nb"   ->  <li>x b</li>        <- the item swallows the paragraph below it
 *
 * The first two are why a blank line goes above and `needsSeparation` decides it — the same rule
 * that stops an empty marker written under a list item being swallowed by it. The third is why one
 * goes below: the item is empty at the moment it is written and absorbs the paragraph under it as
 * soon as it has text, which is the very next keystroke. Same shape as decision 108's rule for
 * *leaving* a list: one blank line, and only where there is not one already.
 *
 * The caret is placed explicitly rather than mapped. Mapping an empty range against an insertion at
 * its own position depends on the association, and a caret sitting *before* the line's leading
 * whitespace maps to before the marker — the one position that reads as the button having inserted
 * the marker somewhere else.
 *
 * The caret then lands immediately after a marker's trailing space on its own active line, which is
 * decision 122's fault to the character: a fixed-width marker box strands that space where WebKit
 * will not put a caret after it, and the next character typed goes in front of the marker. It is
 * safe here only because `rawListMark` takes a `min-width` rather than a width, for exactly that
 * reason — a rule in another file, so this one is checked by typing into the built app.
 */
function startBlockOnBlankLine(
  view: EditorView,
  line: Line,
  markerFor: (index: number, indent: number) => string
): void {
  const state = view.state;
  const indent = indentOf(line.text);
  // After the quote marks on a quote's blank line (150): the marker is the quote's content.
  const quoted = quoteMarksOnly(line.text);
  const at = line.from + (quoted ? containerPrefixOf(line.text) : indent);
  const marker = markerFor(0, indent);
  const kind = kindOf(marker);
  // Inside a quote the separating line is `>`, and it goes in front of the line, not the marker.
  const above = !quoted && kind && needsSeparation(state, line, kind, indent) ? "\n" : "";
  const below = !quoted && paragraphBelow(state, line.number + 1) ? "\n" : "";
  view.dispatch({
    changes: { from: at, insert: above + marker + below },
    selection: { anchor: at + above.length + marker.length },
    userEvent: "input",
  });
  view.focus();
}

/**
 * Puts a marker on **each block** the selection covers, and on nothing else.
 *
 * This replaced a per-*line* prefix, which was wrong three ways at once and all three were visible
 * in one screenshot: blank lines between paragraphs became empty list items, a paragraph broken
 * with ⇧⏎ became two items rather than one, and an ordered list wrote "1." on every line because
 * the prefix was a constant string.
 *
 * One marker per block fixes all three. `blocksIn` skips blank lines by construction — they belong
 * to no block — and a soft-wrapped paragraph is one block, so it takes one marker with its
 * continuation lines indented to sit under the text rather than under the marker.
 *
 * @param markerFor  the marker for the n-th block, given its indent so an ordered list can count
 *                   each nesting level separately.
 * @param existing   what already counts as this marker, for the toggle-off test.
 * @param replaces   what a *different* kind of the same thing looks like, which this one takes the
 *                   place of rather than sitting in front of.
 */
function applyBlockMarker(
  view: EditorView,
  markerFor: (index: number, indent: number) => string,
  existing: RegExp,
  replaces?: RegExp,
  container = false
): void {
  const state = view.state;
  const blocks = blocksIn(state, state.selection.main.from, state.selection.main.to);
  if (blocks.length === 0) {
    const blank = blankCaretLine(state);
    if (blank) startBlockOnBlankLine(view, blank, markerFor);
    return;
  }

  const doc = state.doc;
  // Everything is measured after the leading whitespace, not at column zero. A nested item is
  // indented — `   1. a` — so a marker anchored at `^` matched nothing on it, and the command
  // cheerfully wrote its own marker in front of the indent: `-    1. a`, which is a top-level
  // bullet whose text happens to start with spaces. Every list in the report was nested, which is
  // why this arrived alongside the stacking rather than after it.
  //
  // And past the quote marks, for a list: the quote is the container, so its `>` stays outermost
  // whichever button was pressed first — Quote then Numbered used to write `1. > `, a quote inside
  // a list item, and Bullet on a quoted numbered item `- > 1. ` (decision 150). The quote command
  // itself is the container and sits in front of everything but the indent.
  const prefixOf = container ? indentOf : containerPrefixOf;
  const markerStart = (line: { from: number; text: string }) => line.from + prefixOf(line.text);
  const body = (text: string) => text.slice(prefixOf(text));

  // Off only when every block already carries **this** marker — on a mixed selection the button
  // should finish the job rather than strip the markers from half of it. A selection of a bullet
  // and a numbered item is mixed in exactly this sense, so Bulleted converts the numbered one.
  const removing = blocks.every((block) => existing.test(body(doc.lineAt(block.from).text)));

  const changes: { from: number; to: number; insert: string }[] = [];

  blocks.forEach((block, index) => {
    const lines = linesOf(state, block);
    const first = lines[0]!;
    const text = body(first.text);
    const own = existing.exec(text)?.[0].length ?? 0;
    // Going on, a marker of another kind is *replaced*; coming off, only our own is taken, so a
    // press that removes cannot also eat something it did not put there.
    const had = removing ? own : Math.max(own, replaces?.exec(text)?.[0].length ?? 0);
    const insert = removing ? "" : markerFor(index, indentOf(first.text));
    const start = markerStart(first);

    // A marker-only line changing kind needs the same blank line a new one does.
    //
    // This is the reported case: ⏎ in a bullet list leaves `- `, and Numbered turned it into a line
    // the panel drew as literal text at the item's text column. An empty item cannot interrupt the
    // paragraph above it, so `- what\n1. ` is a lazy continuation to this parser — while pandoc
    // reads it as two lists, which is what made the bytes look right. `needsSeparation` carries the
    // conditions and the measurements behind them.
    const kind = removing ? null : kindOf(insert);
    const empty = text.length === had;
    const lead =
      kind && empty && needsSeparation(state, doc.lineAt(first.from), kind, indentOf(first.text))
        ? "\n"
        : "";

    // The blank line goes in front of the line's own indentation, not between it and the marker —
    // `  - ` with the newline after the two spaces is a line of whitespace and an unindented item.
    if (lead) changes.push({ from: first.from, to: first.from, insert: lead });
    changes.push({ from: start, to: start + had, insert });

    // Continuation lines follow the marker in or out, so the text stays aligned under itself.
    for (const line of lines.slice(1)) {
      const indent = /^ */.exec(line.text)![0].length;
      // A quote is a container and marks every line it holds: `> ` on each line going in, and off
      // each line coming out — it used to strip the first line only (150).
      if (container) {
        const mark = existing.exec(line.text.slice(indent))?.[0].length ?? 0;
        if (removing && mark > 0) changes.push({ from: line.from + indent, to: line.from + indent + mark, insert: "" });
        if (!removing && mark === 0) changes.push({ from: line.from + indent, to: line.from + indent, insert });
        continue;
      }
      if (removing) {
        const drop = Math.min(indent, had);
        if (drop > 0) changes.push({ from: line.from, to: line.from + drop, insert: "" });
      }
      // No literal indent on the way in. Spaces in a proportional font are ~8px where the list's
      // own indent is 26 (decision 55's lesson), so they misaligned rather than aligned — live
      // preview indents the continuation line instead, which is where every other list indent
      // comes from. CommonMark reads an unindented continuation as part of the item regardless.
    }
  });

  const set = state.changes(changes);
  view.dispatch({ changes: set, selection: state.selection.map(set, 1), userEvent: "input" });
  view.focus();
}

/**
 * The numbered list, which numbers — and continues from a list already above it.
 *
 * It used to go through the line prefix with a constant `"1. "`, so three selected lines became
 * "1." three times: legal CommonMark, and a list that cannot count in an editor which draws the
 * literal number the buffer holds rather than rendering one.
 */
export function applyOrderedList(view: EditorView): void {
  const state = view.state;
  const blocks = blocksIn(state, state.selection.main.from, state.selection.main.to);
  // The blank line the caret is on is the anchor when there is no block to take one from. Without
  // this the count is read off `blocks[0]`, which does not exist, and every press on an empty line
  // under a list that had reached 7 would have written `1.` — the number being the whole point of
  // the button that writes it.
  const blank = blocks.length === 0 ? blankCaretLine(state) : null;
  if (blocks.length === 0 && !blank) return;

  // Look past the blank line that separates a paragraph from the list above it — otherwise
  // extending a list always restarts at one, because the line directly above is never the list.
  //
  // Only a line at the **same indent** counts. A nested list is a different list, so continuing
  // from its parent would number a new top-level item after the deepest number above it — and
  // continuing from a *child* would be worse still.
  const firstLine = blank ?? state.doc.lineAt(blocks[0]!.from);
  const depth = indentOf(firstLine.text);
  let start = 1;
  for (let n = firstLine.number - 1; n >= 1; n--) {
    const text = state.doc.line(n).text;
    if (text.trim() === "") continue;
    const indent = indentOf(text);
    if (indent > depth) continue;
    if (indent === depth) {
      const previous = ORDERED_MARKER.exec(text.slice(containerPrefixOf(text)));
      if (previous) start = Number(previous[1]) + 1;
    }
    break;
  }

  // Each nesting level counts for itself.
  //
  // A flat `start + index` across every block in the selection numbered straight through the
  // indents — `1. Hi`, `2. A`, `   3. a`, `   4. b` — and the renumbering filter then left the
  // nested pair alone, correctly, because decision 85 keeps a run's first number when the author
  // chose it. It could not tell that nobody had.
  //
  // A deeper level restarts at 1, and going back out resets it, which is what a sublist is.
  const counters = new Map<number, number>();
  applyBlockMarker(
    view,
    (_index, indent) => {
      for (const level of [...counters.keys()]) if (level > indent) counters.delete(level);
      const next = (counters.get(indent) ?? (indent === depth ? start : 1) - 1) + 1;
      counters.set(indent, next);
      return `${next}. `;
    },
    ORDERED_MARKER,
    ANY_LIST_MARKER_AT_START
  );
}

/** The three list kinds and the quote, each written once. See the note above `ORDERED_MARKER`. */
export function applyBulletList(view: EditorView): void {
  applyBlockMarker(view, () => "- ", BULLET_MARKER, ANY_LIST_MARKER_AT_START);
}

export function applyTaskList(view: EditorView): void {
  applyBlockMarker(view, () => "- [ ] ", TASK_MARKER, ANY_LIST_MARKER_AT_START);
}

/** No `replaces`: `> - a` is a real thing to want, so a quote stacks where a list kind replaces. */
export function applyQuote(view: EditorView): void {
  applyBlockMarker(view, () => "> ", /^>\s?/, undefined, true);
}

/**
 * Wraps the selected lines in a fenced code block, or opens an empty one.
 *
 * Whole lines, never part of one: a fence is only a fence at the start of a line, so wrapping a
 * selection mid-sentence would write three backticks into the middle of a paragraph and render as
 * literal text. With no selection it opens an empty block and puts the caret inside it, which is
 * what the button is for most of the time.
 */
export function applyCodeBlock(view: EditorView): void {
  // Inside one already: take the fences off rather than wrapping the block in a second block,
  // which is what every other button on this bar now does when it is drawn pressed.
  const fenced = enclosingNode(view.state, "FencedCode");
  if (fenced) {
    const doc = view.state.doc;
    const first = doc.lineAt(fenced.from);
    const last = doc.lineAt(Math.min(fenced.to, doc.length));
    view.dispatch({
      changes: [
        { from: first.from, to: Math.min(first.to + 1, doc.length) },
        { from: Math.max(last.from - 1, first.from), to: last.to },
      ],
      userEvent: "input",
    });
    view.focus();
    return;
  }

  const { from, to } = view.state.selection.main;
  const first = view.state.doc.lineAt(from);
  const last = view.state.doc.lineAt(to);
  const body = view.state.doc.sliceString(first.from, last.to);

  view.dispatch({
    changes: { from: first.from, to: last.to, insert: "```\n" + body + "\n```" },
    // Inside the block: past the opening fence and its newline.
    selection: { anchor: first.from + 4 + body.length },
    scrollIntoView: true,
  });
}

/**
 * Sets, changes or clears the heading level of the caret's line.
 *
 * Not `applyLinePrefix("# ")`: that toggles one exact string, so going from H1 to H2 produced
 * `# ## ` rather than a heading. Any existing marker is stripped first, and asking for the level a
 * line already has clears it — which is what a pressed button should do when you press it again.
 */
export function setHeading(view: EditorView, level: number): void {
  const state = view.state;
  const doc = state.doc;
  // Per block, so the blank line between two paragraphs does not become `# ` — which is what
  // iterating lines did, and it is not even a heading, just a hash on an empty line.
  const blocks = blocksIn(state, state.selection.main.from, state.selection.main.to);
  const changes = [];

  for (const block of blocks) {
    const line = doc.lineAt(block.from);
    const existing = /^(#{1,6})\s+/.exec(line.text);
    const already = existing?.[1]?.length === level;
    const insert = already ? "" : "#".repeat(level) + " ";
    changes.push({ from: line.from, to: line.from + (existing?.[0]?.length ?? 0), insert });
  }

  const set = view.state.changes(changes);
  view.dispatch({ changes: set, selection: view.state.selection.map(set, 1) });
  view.focus();
}
