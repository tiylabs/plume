/*
 * The eleven formatting commands against five shapes of selection: the bytes each writes.
 *
 * The same fixture and the same expected text as `tests/webview/commands.test.js`, which runs them
 * in a real WKWebView. This copy runs the commands in plain node (see `format-harness.ts`), so a
 * change to `format/inline.ts` or `format/block.ts` is answered in milliseconds, and the two suites
 * agreeing is the check that the stub view is not hiding anything.
 *
 * `want` is the selection after the command, in the harness's notation — the WKWebView suite only
 * asserts the bytes, so this file asserts those too, with the selection stripped.
 */

import { applyBulletList, applyOrderedList, applyQuote, applyTaskList } from "../../src/format/block";
import { applyLink, applyWrap, applyWrapPair } from "../../src/format/inline";
import { View, show } from "./format-harness";
import type { EditorView } from "@codemirror/view";

// Two separate paragraphs, and a pair of lines that are one paragraph split with ⇧⏎.
const DOC = "para one\n\npara two\n\nsoft a\nsoft b\n";
const P1 = DOC.indexOf("para one");
const P2 = DOC.indexOf("para two");
const SA = DOC.indexOf("soft a");
const END = DOC.length - 1;

const SHAPES: Record<string, [number, number]> = {
  "one word": [P1, P1 + 4],
  "one paragraph": [P1, P1 + 8],
  "two paragraphs": [P1, P2 + 8],
  "soft-break pair": [SA, END],
  everything: [P1, END],
};

const COMMANDS: Record<string, (view: EditorView) => void> = {
  Bold: (v) => applyWrap(v, "**"),
  Italic: (v) => applyWrap(v, "*"),
  Strikethrough: (v) => applyWrap(v, "~~"),
  // The one pair whose halves differ: the format bar calls it as `applyWrapPair(view, "<u>", "</u>")`.
  Underline: (v) => applyWrapPair(v, "<u>", "</u>"),
  Highlight: (v) => applyWrap(v, "=="),
  "Inline code": (v) => applyWrap(v, "`"),
  Link: applyLink,
  Quote: applyQuote,
  "Numbered list": applyOrderedList,
  "Bulleted list": applyBulletList,
  "Task list": applyTaskList,
};

/** The document the WKWebView suite expects each command to leave, byte for byte. */
const EXPECTED: Record<string, string> = {
  "Bold · one word": "**para** one\n\npara two\n\nsoft a\nsoft b\n",
  "Bold · one paragraph": "**para one**\n\npara two\n\nsoft a\nsoft b\n",
  "Bold · two paragraphs": "**para one**\n\n**para two**\n\nsoft a\nsoft b\n",
  "Bold · soft-break pair": "para one\n\npara two\n\n**soft a\nsoft b**\n",
  "Bold · everything": "**para one**\n\n**para two**\n\n**soft a\nsoft b**\n",
  "Italic · one word": "*para* one\n\npara two\n\nsoft a\nsoft b\n",
  "Italic · one paragraph": "*para one*\n\npara two\n\nsoft a\nsoft b\n",
  "Italic · two paragraphs": "*para one*\n\n*para two*\n\nsoft a\nsoft b\n",
  "Italic · soft-break pair": "para one\n\npara two\n\n*soft a\nsoft b*\n",
  "Italic · everything": "*para one*\n\n*para two*\n\n*soft a\nsoft b*\n",
  "Strikethrough · one word": "~~para~~ one\n\npara two\n\nsoft a\nsoft b\n",
  "Strikethrough · one paragraph": "~~para one~~\n\npara two\n\nsoft a\nsoft b\n",
  "Strikethrough · two paragraphs": "~~para one~~\n\n~~para two~~\n\nsoft a\nsoft b\n",
  "Strikethrough · soft-break pair": "para one\n\npara two\n\n~~soft a\nsoft b~~\n",
  "Strikethrough · everything": "~~para one~~\n\n~~para two~~\n\n~~soft a\nsoft b~~\n",
  "Underline · one word": "<u>para</u> one\n\npara two\n\nsoft a\nsoft b\n",
  "Underline · one paragraph": "<u>para one</u>\n\npara two\n\nsoft a\nsoft b\n",
  "Underline · two paragraphs": "<u>para one</u>\n\n<u>para two</u>\n\nsoft a\nsoft b\n",
  "Underline · soft-break pair": "para one\n\npara two\n\n<u>soft a</u>\n<u>soft b</u>\n",
  "Underline · everything": "<u>para one</u>\n\n<u>para two</u>\n\n<u>soft a</u>\n<u>soft b</u>\n",
  "Highlight · one word": "==para== one\n\npara two\n\nsoft a\nsoft b\n",
  "Highlight · one paragraph": "==para one==\n\npara two\n\nsoft a\nsoft b\n",
  "Highlight · two paragraphs": "==para one==\n\n==para two==\n\nsoft a\nsoft b\n",
  "Highlight · soft-break pair": "para one\n\npara two\n\n==soft a==\n==soft b==\n",
  "Highlight · everything": "==para one==\n\n==para two==\n\n==soft a==\n==soft b==\n",
  "Inline code · one word": "`para` one\n\npara two\n\nsoft a\nsoft b\n",
  "Inline code · one paragraph": "`para one`\n\npara two\n\nsoft a\nsoft b\n",
  "Inline code · two paragraphs": "`para one`\n\n`para two`\n\nsoft a\nsoft b\n",
  "Inline code · soft-break pair": "para one\n\npara two\n\n`soft a\nsoft b`\n",
  "Inline code · everything": "`para one`\n\n`para two`\n\n`soft a\nsoft b`\n",
  "Link · one word": "[para]() one\n\npara two\n\nsoft a\nsoft b\n",
  "Link · one paragraph": "[para one]()\n\npara two\n\nsoft a\nsoft b\n",
  "Link · two paragraphs": "[para one]()\n\n[para two]()\n\nsoft a\nsoft b\n",
  "Link · soft-break pair": "para one\n\npara two\n\n[soft a\nsoft b]()\n",
  "Link · everything": "[para one]()\n\n[para two]()\n\n[soft a\nsoft b]()\n",
  "Quote · one word": "> para one\n\npara two\n\nsoft a\nsoft b\n",
  "Quote · one paragraph": "> para one\n\npara two\n\nsoft a\nsoft b\n",
  "Quote · two paragraphs": "> para one\n\n> para two\n\nsoft a\nsoft b\n",
  "Quote · soft-break pair": "para one\n\npara two\n\n> soft a\n> soft b\n",
  "Quote · everything": "> para one\n\n> para two\n\n> soft a\n> soft b\n",
  "Numbered list · one word": "1. para one\n\npara two\n\nsoft a\nsoft b\n",
  "Numbered list · one paragraph": "1. para one\n\npara two\n\nsoft a\nsoft b\n",
  "Numbered list · two paragraphs": "1. para one\n\n2. para two\n\nsoft a\nsoft b\n",
  "Numbered list · soft-break pair": "para one\n\npara two\n\n1. soft a\nsoft b\n",
  "Numbered list · everything": "1. para one\n\n2. para two\n\n3. soft a\nsoft b\n",
  "Bulleted list · one word": "- para one\n\npara two\n\nsoft a\nsoft b\n",
  "Bulleted list · one paragraph": "- para one\n\npara two\n\nsoft a\nsoft b\n",
  "Bulleted list · two paragraphs": "- para one\n\n- para two\n\nsoft a\nsoft b\n",
  "Bulleted list · soft-break pair": "para one\n\npara two\n\n- soft a\nsoft b\n",
  "Bulleted list · everything": "- para one\n\n- para two\n\n- soft a\nsoft b\n",
  "Task list · one word": "- [ ] para one\n\npara two\n\nsoft a\nsoft b\n",
  "Task list · one paragraph": "- [ ] para one\n\npara two\n\nsoft a\nsoft b\n",
  "Task list · two paragraphs": "- [ ] para one\n\n- [ ] para two\n\nsoft a\nsoft b\n",
  "Task list · soft-break pair": "para one\n\npara two\n\n- [ ] soft a\nsoft b\n",
  "Task list · everything": "- [ ] para one\n\n- [ ] para two\n\n- [ ] soft a\nsoft b\n",
};

/** ⌘L parks the caret in the empty `()` so a URL can be pasted, so a second press has a caret rather
 * than a selection: it is the one command that deliberately does not round-trip. */
const NOT_REVERSIBLE = new Set(Object.keys(EXPECTED).filter((k) => k.startsWith("Link ·")));

function selected(range: [number, number]): View {
  const v = new View("|" + DOC);
  v.dispatch({ selection: { anchor: range[0], head: range[1] } });
  return v;
}

/** Every case is one command on one shape: the bytes written, and then the same press again. */
export const cases: { name: string; doc: string; want: string }[] = [];

export function press(doc: string): string {
  const [command, shape, times] = doc.split("::") as [string, string, string];
  const v = selected(SHAPES[shape]!);
  for (let i = 0; i < Number(times); i += 1) COMMANDS[command]!(v.view);
  return v.state.doc.toString();
}

for (const command of Object.keys(COMMANDS)) {
  for (const shape of Object.keys(SHAPES)) {
    const key = `${command} · ${shape}`;
    cases.push({ name: `${key} writes these bytes`, doc: `${command}::${shape}::1`, want: EXPECTED[key]! });
    // Pressing it twice leaves the note exactly as it was: a toggle, not a one-way door.
    if (!NOT_REVERSIBLE.has(key)) {
      cases.push({ name: `${key}, pressed twice, is the note again`, doc: `${command}::${shape}::2`, want: DOC });
    }
  }
}

void show;
