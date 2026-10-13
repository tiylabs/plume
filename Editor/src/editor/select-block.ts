/*
 * ⌘A, one block at a time, and the ⌫ and ⌦ keys the table commands share.
 */

import { deleteCharBackward, deleteCharForward } from "@codemirror/commands";
import { deleteMarkupBackward } from "@codemirror/lang-markdown";
import { syntaxTree } from "@codemirror/language";
import type { SyntaxNode } from "@lezer/common";
import { EditorSelection } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { keyCommand } from "../keyboard/context";
import { chain } from "../keyboard/edit";
import { backspace } from "../keyboard/backspace";
import { deleteForward } from "../keyboard/delete";
import { fencesOf, markerSpanEnd } from "../markdown/blocks";

/** The blocks ⌘A steps through, innermost first. `ListItem` over the `Paragraph` inside it, so a task
 * item, which has no paragraph, selects like every other list (decision 65). */
const SELECTABLE_BLOCKS = new Set([
  "Paragraph",
  "ATXHeading1",
  "ATXHeading2",
  "ATXHeading3",
  "ATXHeading4",
  "ATXHeading5",
  "ATXHeading6",
  "SetextHeading1",
  "SetextHeading2",
  "FencedCode",
  "CodeBlock",
  "HorizontalRule",
  "Table",
  "ListItem",
  "Blockquote",
]);
/** ⌘A selects the block; when the selection already is the block this declines and CodeMirror's
 * `selectAll` takes the note (decision 65). */
/** ⌫ as the key does it: the table, then CodeMirror's markup delete, then one character (170 reuses it). */
export const backspaceKey = chain(keyCommand(backspace), deleteMarkupBackward, deleteCharBackward);
export const deleteKey = chain(keyCommand(deleteForward), deleteCharForward);
export function selectBlockThenAll(view: EditorView): boolean {
  const state = view.state;
  const range = state.selection.main;
  if (range.from === 0 && range.to === state.doc.length) return false;

  // The smallest selectable block that **strictly contains** the selection, so a second press steps
  // *out* — paragraph, then the quote around it, then the note. Taking the innermost block at the
  // head instead sent the second press back *in*: ⌘A on a quoted note selected the quote, and ⌘A
  // again the last paragraph inside it, because the head had moved to the quote's end (decision 65,
  // amended 151). Both biases, because at a line start the node to the left is the block above.
  // A block is selected from its **content**, not from its first byte — decision 153. A list item
  // and a heading start at the line start, so ⌘A used to take `1. ` and `# ` with the text, and the
  // inline commands wrapped them: `**1. Hi**` is not a list item any more. Nothing in a marker span
  // is drawn as characters (151), so it is not something you can have selected either.
  // A code block's content is its code: its fences are never drawn either, and a range ending on the
  // closing one left its end on that 8px strip (162). A block with no code has nothing to select.
  const rangeOf = (block: SyntaxNode): { from: number; to: number } | null => {
    if (block.name !== "FencedCode") return { from: markerSpanEnd(state, state.doc.lineAt(block.from).number), to: block.to };
    const { first, last, closed } = fencesOf(state, block);
    const lastCode = closed ? last - 1 : last;
    if (lastCode <= first) return null;
    return { from: state.doc.line(first + 1).from, to: state.doc.line(lastCode).to };
  };

  let best: SyntaxNode | null = null;
  for (const bias of [-1, 1] as const) {
    for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(range.head, bias); node; node = node.parent) {
      if (!SELECTABLE_BLOCKS.has(node.name)) continue;
      // A list item's own range, not the paragraph inside it — see SELECTABLE_BLOCKS.
      const block = node.parent?.name === "ListItem" ? node.parent : node;
      const take = rangeOf(block);
      if (!take || take.from > range.from || take.to < range.to) continue;
      // Against what this press would *select*, not against the node: the range this leaves starts
      // past the marker, so comparing node starts made the second press pick the same block again
      // and ⌘A never stepped out.
      if (take.from === range.from && take.to === range.to) continue;
      if (!best || block.to - block.from < best.to - best.from) best = block;
    }
  }
  const take = best && rangeOf(best);
  if (!take) return false;

  view.dispatch({ selection: EditorSelection.range(take.from, take.to) });
  return true;
}