/*
 * The parts that are built once, at startup, and then read from everywhere.
 *
 * The editor, the two overlays and the two footer bars are created in `main.ts` in an order that
 * matters — each is built from things that exist by then — and a dozen functions use them later,
 * from handlers that only ever run after startup. Importing them as bindings would make every
 * module's evaluation order a question; reading them off this object at call time makes it none.
 *
 * Filled in by `main.ts` before anything can call in. Nothing here is optional except the two bars,
 * which `updateListener` can reach while the editor is still being constructed.
 */

import type { EditorView } from "@codemirror/view";
import type { mountActionPanel } from "../ui/action-panel";
import type { mountFind } from "../ui/find";
import type { mountFormatBar } from "../ui/format-bar";
import type { mountSwitcher } from "../ui/switcher";

interface Parts {
  view: EditorView;
  actions: ReturnType<typeof mountActionPanel>;
  switcher: ReturnType<typeof mountSwitcher>;
  formatBar: ReturnType<typeof mountFormatBar> | undefined;
  find: ReturnType<typeof mountFind> | undefined;
}

export const ctx = {} as Parts;
