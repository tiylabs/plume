/*
 * What the agent API promises about the editor, against the real bundle in a real WKWebView.
 *
 * Two promises, each made in a file an agent reads or a result it receives:
 *
 * 1. The format guide (`App/Resources/Agent/format.md`, `capabilities.json`) says what renders. An
 *    agent writes to it, so a claim the editor does not keep produces notes that look wrong to the
 *    person. Each claim the guide makes is one case here; changing what renders means changing
 *    the guide and this file together.
 * 2. An agent's change to the open note arrives as `loadNote` of the same file (the session's
 *    "write, then reload"). That must replace the text, clamp the caret, and leave nothing for ⌘Z
 *    to walk back into — the guide and the tool descriptions say an agent change is undone through
 *    Settings' restore, not ⌘Z.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function run(view, bar, doc) {
  const failures = [];
  let checked = 0;
  const check = (name, want, got) => {
    checked += 1;
    if (want !== got) failures.push({ case: name, want: String(want), got: String(got) });
  };
  const host = window.plumeHost;

  /** Loads `text` with the caret at the very end, so the lines under test are not the caret's. */
  const render = async (text) => {
    host.loadNote("format.md", text + "\nend\n", (text + "\nend\n").length, false);
    await sleep(30);
    return [...doc.querySelectorAll(".cm-line")];
  };
  const count = (selector) => doc.querySelectorAll(".cm-content " + selector).length;

  // ---- the format guide -----------------------------------------------------------------------
  let lines = await render("# Title\n\nbody");
  check("format: '# ' starts a heading", true, lines[0].classList.contains("plume-line-h1"));

  lines = await render("x\n\n#Title");
  check("format: '#' without a space is text", false, lines[2].classList.contains("plume-line-h1"));

  await render("x\n\n- [ ] to do\n- [x] done");
  check("format: bullet tasks draw boxes", 2, count(".plume-task"));

  await render("x\n\n1. [ ] stays text");
  check("format: a numbered item's [ ] is text", 0, count(".plume-task"));

  await render("x\n\n==marked== and <u>under</u>");
  check("format: ==highlight== renders", 1, count(".plume-mark"));
  check("format: <u>underline</u> renders", 1, count(".plume-underline"));

  await render("x\n\n`==not marked==`");
  check("format: == inside code is not a highlight", 0, count(".plume-mark"));

  await render("x\n\n**bold** *italic* ~~gone~~ `code`");
  check("format: strong", 1, count(".plume-strong"));
  check("format: emphasis", 1, count(".plume-em"));
  check("format: strikethrough", 1, count(".plume-strike"));
  check("format: inline code", 1, count(".plume-code"));

  lines = await render("---\ntitle: front matter");
  check("format: a first-line --- is not a rule (no front matter)", false, lines[0].classList.contains("plume-rule"));

  lines = await render("x\n\n---");
  check("format: --- later in the note is a rule", true, lines[2].classList.contains("plume-rule"));

  lines = await render("x\n\n- - item");
  check("format: a second marker on the line does not nest", 1, lines[2].querySelectorAll(".plume-list-marker").length);

  lines = await render("x\n\n- # not a heading");
  check("format: a heading inside a list item is text", false, lines[2].classList.contains("plume-line-h1"));

  lines = await render("x\n\n> # not a heading in a quote");
  check("format: a heading inside a quote is text", false, lines[2].classList.contains("plume-line-h1"));
  check("format: but the quote is a quote", true, lines[2].classList.contains("plume-line-quote"));

  await render("x\n\n| a | b |\n|---|---|\n| 1 | 2 |");
  check("format: tables are kept as text, not drawn", 0, doc.querySelectorAll(".cm-content table").length);

  lines = await render("x\n\n```\n- [ ] code\n```");
  check("format: fenced code is code", true, lines[3].classList.contains("plume-line-code"));
  check("format: no box inside code", 0, count(".plume-task"));

  // ---- an agent change to the open note ------------------------------------------------------
  const before = "# Agent\n\na long paragraph that the agent will shorten\n";
  const after = "# Agent\n\nshort\n";
  host.loadNote("open.md", before, 0, false);
  // Typing earlier in this sitting puts something in the history that ⌘Z could otherwise reach.
  view.dispatch({ changes: { from: 9, insert: "typed earlier " }, userEvent: "input.type" });
  // The session reloads the same file with the caret it recorded, which may now be past the end.
  host.loadNote("open.md", after, before.length, false);
  await sleep(20);
  check("reload: the new text is shown", after, view.state.doc.toString());
  check("reload: the caret is clamped to the new length", after.length, view.state.selection.main.head);
  const undo = () => view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", {
    key: "z", code: "KeyZ", metaKey: true, bubbles: true, cancelable: true,
  }));
  undo();
  undo();
  check("reload: ⌘Z cannot walk back into the text the agent replaced", after, view.state.doc.toString());

  return { checked, failures };
}
