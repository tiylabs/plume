/*
 * The markdown formatting keys, as a CodeMirror keymap.
 */

import { EditorView } from "@codemirror/view";
import { applyLink, applyWrap, applyWrapPair } from "./inline";
import { applyBulletList, applyCodeBlock, applyOrderedList, applyQuote, applyTaskList, setHeading } from "./block";

/**
 * The markdown formatting keys — and they are deliberately **not** rebindable.
 *
 * Plume's shortcuts come in two tiers and this is the second one. Tier 1 is Plume's own furniture —
 * ⌘K, ⌘P, ⌘N, ⌘, and the rest of the ⌘K rows — which is a matter of taste and machine, so it lives in
 * `Settings.shortcutActions`, appears in the Shortcuts tab, and has a Restore Defaults button for
 * when somebody paints themselves into a corner. Tier 2 is *markdown convention*: ⌘B has meant bold
 * in every editor anyone has used for thirty years. Offering to rebind it invites a user to break
 * something no one wants broken, and costs a row in the tab to do it.
 *
 * The keys match Raycast's Format palette exactly, for decision 39's reason: the person switching
 * already has them in their fingers. ⌥⌘1/2/3 are here too, so every fixed markdown key has one home
 * rather than being split between this file and the editor's keymap.
 *
 * Each entry stays a plain text edit — decision 5 holds at the keyboard as it does at the format bar.
 */
export const MARKDOWN_FORMAT_KEYS: {
  key: string;
  /** What the Shortcuts tab prints beside it, since these are shown but not recorded. */
  label: string;
  run: (view: EditorView) => boolean;
}[] = [
  { key: "Mod-b", label: "Bold", run: (v) => (applyWrap(v, "**"), true) },
  { key: "Mod-i", label: "Italic", run: (v) => (applyWrap(v, "*"), true) },
  { key: "Shift-Mod-s", label: "Strikethrough", run: (v) => (applyWrap(v, "~~"), true) },
  { key: "Mod-e", label: "Inline code", run: (v) => (applyWrap(v, "`"), true) },
  { key: "Mod-l", label: "Link", run: (v) => (applyLink(v), true) },
  { key: "Mod-u", label: "Underline", run: (v) => (applyWrapPair(v, "<u>", "</u>"), true) },
  { key: "Shift-Mod-m", label: "Highlight", run: (v) => (applyWrap(v, "=="), true) },
  { key: "Alt-Mod-c", label: "Code block", run: (v) => (applyCodeBlock(v), true) },
  { key: "Shift-Mod-b", label: "Quote", run: (v) => (applyQuote(v), true) },
  { key: "Shift-Mod-7", label: "Numbered list", run: (v) => (applyOrderedList(v), true) },
  { key: "Shift-Mod-8", label: "Bulleted list", run: (v) => (applyBulletList(v), true) },
  { key: "Shift-Mod-9", label: "Task list", run: (v) => (applyTaskList(v), true) },
  { key: "Alt-Mod-1", label: "Heading 1", run: (v) => (setHeading(v, 1), true) },
  { key: "Alt-Mod-2", label: "Heading 2", run: (v) => (setHeading(v, 2), true) },
  { key: "Alt-Mod-3", label: "Heading 3", run: (v) => (setHeading(v, 3), true) },
];
