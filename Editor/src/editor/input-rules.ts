/*
 * Input rules: what typing a character does when it completes a construct.
 *
 * Each takes nothing and returns an extension, and reads only the editor it is installed in, so none
 * of them knows about the panel. They were in `main.ts` for no reason but that it was where they
 * were first written.
 */

import { Prec, type Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markerSpanEnd, notAPlace, ruleLine } from "../markdown/blocks";

/** A new bullet takes the marker the list above it uses — to CommonMark a change of character
 * starts a second list (decision 59). Only with a list directly above at the same indent. */
export function bulletInputRule(): Extension {
  return EditorView.inputHandler.of((view, from, to, text) => {
    if (text !== " ") return false;

    const line = view.state.doc.lineAt(from);
    const typed = /^(\s*)([-*+])$/.exec(line.text.slice(0, from - line.from));
    if (!typed) return false;

    const indent = typed[1];
    const marker = typed[2];

    // The nearest line above that is a bullet at this indent. A blank line does not end a list, so
    // it is skipped; anything else does.
    let above = line.number - 1;
    let previous: string | null = null;
    while (above >= 1) {
      const candidate = view.state.doc.line(above);
      if (candidate.text.trim() === "") {
        above -= 1;
        continue;
      }
      const match = new RegExp(`^${indent}([-*+])\\s`).exec(candidate.text);
      previous = match?.[1] ?? null;
      break;
    }

    if (!previous || previous === marker) return false;

    view.dispatch({
      changes: { from: from - 1, to, insert: previous + " " },
      selection: { anchor: from + 1 },
      userEvent: "input.type",
    });
    return true;
  });
}
export function checkboxInputRule(): Extension {
  return EditorView.inputHandler.of((view, from, to, text) => {
    if (text !== " ") return false;

    const line = view.state.doc.lineAt(from);
    const before = line.text.slice(0, from - line.from);

    // Only on a line of its own. After a list marker `[] ` is text: a line is one kind of item (155).
    // On a line of its own — `[]` becomes a whole list item, which is what Typora does and what you
    // mean when you start a line that way.
    const indent = /^(\s*)\[\]$/.exec(before)?.[1];
    if (indent !== undefined) {
      const start = line.from + indent.length;
      view.dispatch({
        changes: { from: start, to, insert: "- [ ] " },
        selection: { anchor: start + 6 },
        userEvent: "input.type",
      });
      return true;
    }

    return false;
  });
}
/**
 * A fence is finished the moment it is typed — decision 160.
 *
 * The backtick that makes ```` ``` ```` open a block also writes its closing fence and one empty code
 * line, and the caret goes there. Left alone, the caret stood on the opening fence — an 8px strip
 * that is not a place (151) — and what was typed next went into an info string nobody can see. Only
 * when it opens a block: the same three characters closing an open one are just typed.
 */
export function fenceInputRule(): Extension {
  return Prec.high(EditorView.inputHandler.of((view, from, to, text) => {
    if (from !== to || (text !== "`" && text !== "~")) return false;
    const state = view.state;
    const line = state.doc.lineAt(from);
    if (from !== line.to) return false;
    const typed = /^([ \t]*)(```|~~~)$/.exec(line.text + text);
    if (!typed) return false;

    const after = state.update({ changes: { from, insert: text } }).state;
    const tree = ensureSyntaxTree(after, after.doc.length, 50) ?? syntaxTree(after);
    const block = tree.resolveInner(line.from + typed[1]!.length, 1);
    let fenced: typeof block | null = block;
    while (fenced && fenced.name !== "FencedCode") fenced = fenced.parent;
    if (!fenced || fenced.from !== line.from + typed[1]!.length) return false;
    let marks = 0;
    for (let child = fenced.firstChild; child; child = child.nextSibling) if (child.name === "CodeMark") marks += 1;
    if (marks !== 1) return false;

    const indent = typed[1]!;
    view.dispatch({
      changes: { from, insert: `${text}\n${indent}\n${indent}${typed[2]}` },
      selection: { anchor: from + 2 + indent.length },
      userEvent: "input.type",
      scrollIntoView: true,
    });
    return true;
  }));
}
/**
 * A rule is finished the moment it is typed — decision 152.
 *
 * `---` on a line of its own draws a 1px line with nothing in it, and that line is not a place the
 * caret can sit (151): parked there it is drawn below the rule, three hidden characters to the
 * right of where the text starts, over whatever line comes next. So the character that completes
 * the break also moves the caret to the first place under the rule, adding a line when the rule
 * ends the note. The same step ↓ takes from a rule, taken for the person who just made one.
 *
 * Only a line that is the break and nothing else, and only when the tree agrees it is one: `---`
 * directly under a paragraph is a setext underline, and the caret has to stay on it or the rest of
 * what they type scatters (151).
 */
export function ruleInputRule(): Extension {
  return EditorView.inputHandler.of((view, from, to, text) => {
    if (from !== to || !/^[-*_]$/.test(text)) return false;
    const state = view.state;
    const line = state.doc.lineAt(from);
    if (from !== line.to) return false;
    if (!new RegExp(`^[ \\t]*(?:\\${text}[ \\t]*)+$`).test(line.text)) return false;
    // Not on the note's first line. A rule there separates nothing, and `---` at the top of an
    // empty note is how a YAML frontmatter fence is typed — adding a line under it would break the
    // bytes of something Plume does not interpret and must not damage (121).
    if (line.number === 1) return false;

    const after = state.update({ changes: { from, to, insert: text } }).state;
    if (!ruleLine(after, line.number)) return false;

    // The first line under the rule the caret may rest on. A blank line between two paragraphs is
    // not one (146), so this lands where ↓ would.
    let n = line.number + 1;
    while (n <= after.doc.lines && notAPlace(after, n)) n += 1;
    if (n > after.doc.lines) {
      // Nothing below to land on: the rule takes a line of its own and the caret the one after it.
      view.dispatch({
        changes: { from, to, insert: `${text}\n` },
        selection: { anchor: from + text.length + 1 },
        userEvent: "input.type",
        scrollIntoView: true,
      });
      return true;
    }
    view.dispatch({
      changes: { from, to, insert: text },
      selection: { anchor: markerSpanEnd(after, n) },
      userEvent: "input.type",
      scrollIntoView: true,
    });
    return true;
  });
}