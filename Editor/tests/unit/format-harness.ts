/*
 * The format commands, run in plain node.
 *
 * `format/inline.ts` and `format/block.ts` touch the editor through three members only — `state`,
 * `dispatch` and `focus` — so a real `EditorState` with a stub view over it is enough to run them
 * for real: the real parser, the real transactions, no window. The WKWebView suite
 * (`commands.test.js`) still checks what a real editor does with them; this is where a rule is
 * written first, in milliseconds.
 *
 * A document with `[` and `]` has that range selected; with `|` it has a caret there.
 */

import { EditorState, EditorSelection, type TransactionSpec } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import type { EditorView } from "@codemirror/view";
import { plumeDialect } from "../../src/markdown/dialect";
import { pendingWrapExtension } from "../../src/format/inline";

export interface FormatCase {
  name: string;
  /** The document before, with `[…]` for a selection or `|` for a caret. */
  doc: string;
  /** The document after, in the same notation. */
  want: string;
}

const extensions = [markdown({ base: markdownLanguage, extensions: plumeDialect }), pendingWrapExtension()];

function parse(doc: string): { text: string; selection: ReturnType<typeof EditorSelection.range> } {
  const open = doc.indexOf("[");
  const close = doc.indexOf("]");
  if (open >= 0 && close > open) {
    const text = doc.slice(0, open) + doc.slice(open + 1, close) + doc.slice(close + 1);
    return { text, selection: EditorSelection.range(open, close - 1) };
  }
  const caret = doc.indexOf("|");
  if (caret < 0) throw new Error(`no selection or caret in ${JSON.stringify(doc)}`);
  return { text: doc.slice(0, caret) + doc.slice(caret + 1), selection: EditorSelection.cursor(caret) };
}

export function show(state: EditorState): string {
  const text = state.doc.toString();
  const { from, to } = state.selection.main;
  if (from === to) return text.slice(0, from) + "|" + text.slice(from);
  return text.slice(0, from) + "[" + text.slice(from, to) + "]" + text.slice(to);
}

/** A view that is only as much of one as the commands use. */
export class StubView {
  state: EditorState;
  constructor(doc: string) {
    const { text, selection } = parse(doc);
    this.state = EditorState.create({ doc: text, selection, extensions });
    ensureSyntaxTree(this.state, this.state.doc.length, 5000);
  }
  dispatch(...specs: TransactionSpec[]): void {
    this.state = this.state.update(...specs).state;
    ensureSyntaxTree(this.state, this.state.doc.length, 5000);
  }
  focus(): void {}
  /** What the commands are typed to take. */
  get view(): EditorView {
    return this as unknown as EditorView;
  }
}

/** Runs `command` against `doc` and reports the result in the same notation. */
export function run(command: (view: EditorView) => void, doc: string): string {
  const v = new StubView(doc);
  command(v.view);
  return show(v.state);
}

/** Runs it twice: what pressing a button two times leaves. */
export function runTwice(command: (view: EditorView) => void, doc: string): string {
  const v = new StubView(doc);
  command(v.view);
  command(v.view);
  return show(v.state);
}

export { StubView as View };
