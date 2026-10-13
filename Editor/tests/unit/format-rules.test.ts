/*
 * What the format commands do at the edges: toggling, nesting, headings, code blocks, and a wrap
 * pressed with nothing selected.
 *
 * **These describe what the commands do today**, written down when `format-bar.ts` was split into
 * `format/inline.ts` and `format/block.ts`, so that the split — and anything after it — changes
 * them on purpose or not at all. They are not a specification: a case here that reads oddly (an
 * empty pair left inside a word) is a thing the code does, kept so that changing it is a decision.
 * `format-commands.test.ts` is the matrix of eleven commands against five selections.
 *
 * Notation: `[…]` is a selection, `|` a caret. `fn::` names the command; `x2` presses it twice.
 */

import {
  applyBulletList, applyCodeBlock, applyOrderedList, applyQuote, applyTaskList, setHeading,
} from "../../src/format/block";
import { applyWrap, applyWrapPair } from "../../src/format/inline";
import { View, show } from "./format-harness";
import type { EditorView } from "@codemirror/view";

type Command = (view: EditorView) => void;

const COMMANDS: Record<string, Command> = {
  "h1": (v) => setHeading(v, 1),
  "h2": (v) => setHeading(v, 2),
  "bold": (v) => applyWrap(v, "**"),
  "italic": (v) => applyWrap(v, "*"),
  "code": (v) => applyWrap(v, "`"),
  "underline": (v) => applyWrapPair(v, "<u>", "</u>"),
  "numbered": applyOrderedList,
  "bullet": applyBulletList,
  "task": applyTaskList,
  "quote": applyQuote,
  "codeblock": applyCodeBlock,
};

/** `doc` is `command[,command…]::document`. Each command runs once, in order. */
export const press = (doc: string): string => {
  const split = doc.indexOf("::");
  const v = new View(doc.slice(split + 2));
  for (const name of doc.slice(0, split).split(",")) COMMANDS[name]!(v.view);
  return show(v.state);
};

export const cases: { name: string; doc: string; want: string }[] = [
  // Headings
  { name: "a heading is `#`s and a space at the line start", doc: "h2::he|llo", want: "## he|llo" },
  { name: "the same level again takes it off", doc: "h2,h2::he|llo", want: "he|llo" },
  { name: "another level replaces the one there", doc: "h1::## he|llo", want: "# he|llo" },
  { name: "a selection over two paragraphs heads each, not the blank line between", doc: "h2::[one\n\ntwo]", want: "## [one\n\n## two]" },

  // Inline wraps
  { name: "bold on a selection wraps it", doc: "bold::[hello]", want: "**[hello]**" },
  { name: "bold on a word's inside leaves an empty pair at the caret", doc: "bold::he|llo", want: "he**|**llo" },
  { name: "bold at a line's end leaves an empty pair at the caret", doc: "bold::hello |", want: "hello **|**" },
  { name: "bold on a selection that is already bold takes it off", doc: "bold::**[hello]**", want: "[hello]" },
  { name: "bold with the caret inside bold takes it off", doc: "bold::**he|llo**", want: "he|llo" },
  { name: "italic inside bold nests", doc: "italic::**[hello]**", want: "***[hello]***" },
  { name: "code wraps a selection in backticks", doc: "code::[a b]", want: "`[a b]`" },
  { name: "pressing bold twice on a selection is the text again", doc: "bold,bold::[hello]", want: "[hello]" },
  { name: "underline with nothing selected writes nothing until a character is typed", doc: "underline::|", want: "|" },
  { name: "underline wraps a selection in its two different halves", doc: "underline::[hello]", want: "<u>[hello]</u>" },

  // Lists
  { name: "numbered on a single line", doc: "numbered::|a", want: "1. |a" },
  { name: "numbered twice is the line again", doc: "numbered,numbered::|a", want: "|a" },
  { name: "a bullet then numbered replaces the marker", doc: "bullet,numbered::|a", want: "1. |a" },
  { name: "task on a bullet keeps the item and adds the box", doc: "task::- |a", want: "- [ ] |a" },
  { name: "task on a numbered item replaces the number with a bullet and a box", doc: "task::1. |a", want: "- [ ] |a" },
  { name: "bullet inside a quote goes inside it", doc: "bullet::> |a", want: "> - |a" },
  { name: "numbered on three lines of one paragraph marks the first only", doc: "numbered::[a\nb\nc]", want: "1. [a\nb\nc]" },

  // A list command over a different kind of list swaps the marker rather than stacking a second one
  { name: "bullet on a numbered item swaps the number for a dash", doc: "bullet::1. |a", want: "- |a" },
  { name: "numbered on a bullet swaps the dash for a number", doc: "numbered::- |a", want: "1. |a" },
  { name: "numbered on a task item keeps the box: the number replaces the dash only", doc: "numbered::- [ ] |a", want: "1. [ ] |a" },
  { name: "bullet on a task item drops the dash and leaves the box", doc: "bullet::- [ ] |a", want: "[ ] |a" },
  { name: "bullet on a bullet takes it off", doc: "bullet::- |a", want: "|a" },
  { name: "numbered on a numbered item takes it off", doc: "numbered::1. |a", want: "|a" },
  { name: "a list item keeps its indent when its marker is swapped", doc: "numbered::  - |a", want: "  1. |a" },
  { name: "bullet across two numbered items swaps both", doc: "bullet::[1. a\n\n2. b]", want: "[- a\n\n- b]" },
  // The box is written on its own, so a second press stacks a second box rather than toggling it off
  { name: "task on task writes a second box (it is not a toggle)", doc: "task::- [ ] |a", want: "- [ ] [ ] |a" },

  // Quotes
  { name: "quote on a list item puts the quote outside the marker", doc: "quote::- |a", want: "> - |a" },
  { name: "quote on a quoted line takes the quote off", doc: "quote::> |a", want: "|a" },
  { name: "quote on a plain line", doc: "quote::|a", want: "> |a" },

  // Code blocks
  { name: "code block around a selection, caret after the code", doc: "codeblock::[a\nb]", want: "```\na\nb|\n```" },
  { name: "code block on an empty line opens an empty one", doc: "codeblock::|", want: "```\n|\n```" },
  { name: "pressing it twice takes the fences off again", doc: "codeblock,codeblock::[a\nb]", want: "a\nb|" },
];
