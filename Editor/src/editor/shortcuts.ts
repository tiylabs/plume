/*
 * The shortcut vocabulary: the actions that can be rebound, their shipped keys, how a binding is
 * printed as key caps, and how a keydown is matched against one.
 *
 * Pure — no editor, no DOM state — so the panel, the switcher and the tooltips all read one table.
 */

/**
 * The shortcuts the Settings window can rebind (design frame 3c).
 *
 * Keyed by the same action names `Settings.shortcutActions` uses on the Swift side — the two lists
 * have to agree, and naming the action rather than the key is what lets the binding change without
 * anything here knowing.
 */
export const DEFAULT_SHORTCUTS: Record<string, string> = {
  newNote: "Mod-n",
  browseNotes: "Mod-p",
  navigateBack: "Mod-[",
  navigateForward: "Mod-]",
  pinPlume: "Shift-Mod-p",
  formatBar: "Alt-Mod-,",
  actionPanel: "Mod-k",
  revealInFinder: "Alt-Mod-r",
  deleteNote: "Ctrl-x",
  findInNote: "Mod-f",
  findReplace: "Alt-Mod-f",
  copyAsMarkdown: "Shift-Mod-c",
  exportNote: "Shift-Mod-e",
  hideFromCapture: "Shift-Mod-h",
  duplicateNote: "Mod-d",
  autoSizing: "Shift-Mod-/",
  spaceBehaviour: "Alt-Mod-s",
};
/**
 * A CodeMirror binding string as key caps — "Shift-Mod-p" becomes ⇧ ⌘ P.
 *
 * Apple's display order (⌃⌥⇧⌘, then the key), matching what the Shortcuts tab prints in Swift, so
 * the same action reads the same in both places.
 */
export function keyCaps(binding: string): string[] {
  if (!binding) return [];
  const parts = binding.split("-");
  const key = parts.pop() ?? "";
  const held = parts.map((p) => p.toLowerCase());

  const caps: string[] = [];
  if (held.includes("ctrl") || held.includes("control")) caps.push("⌃");
  if (held.includes("alt") || held.includes("option")) caps.push("⌥");
  if (held.includes("shift")) caps.push("⇧");
  if (held.includes("mod") || held.includes("cmd") || held.includes("meta")) caps.push("⌘");

  caps.push(key.length === 1 ? key.toUpperCase() : key);
  return caps;
}
/**
 * Does this keydown match a CodeMirror-style binding string — "Mod-k", "Shift-Mod-p", "Alt-Mod-,"?
 *
 * Needed only by the overlay-closing listener below. Everything else goes through CodeMirror's own
 * keymap, which does this properly; this is the one place a key has to be recognised outside it.
 */
export function matchesBinding(event: KeyboardEvent, binding: string): boolean {
  const parts = binding.split("-");
  const wanted = parts.pop()?.toLowerCase() ?? "";
  let mod = false;
  let shift = false;
  let alt = false;
  let ctrl = false;
  for (const part of parts) {
    switch (part.toLowerCase()) {
      case "mod":
      case "cmd":
      case "meta":
        mod = true;
        break;
      case "shift":
        shift = true;
        break;
      case "alt":
      case "option":
        alt = true;
        break;
      case "ctrl":
      case "control":
        ctrl = true;
        break;
    }
  }
  return (
    event.key.toLowerCase() === wanted &&
    event.metaKey === mod &&
    event.shiftKey === shift &&
    event.altKey === alt &&
    event.ctrlKey === ctrl
  );
}