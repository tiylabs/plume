/*
 * The chrome's tooltips: every button names itself, and prints the shortcut in force.
 */

import { t } from "../i18n";
import { describe } from "../ui/tooltip";
import { panelEl } from "./dom";
import { DEFAULT_SHORTCUTS, keyCaps } from "./shortcuts";
import { state } from "./state";

/** The chrome's tooltips read the binding in force, re-read whenever settings arrive — decision 68's
 * rule, its fourth instance (92). */
const CHROME_TIPS: [selector: string, label: string, action: string | null][] = [
  ["#close", "editor.tip.close", null],
  ["#keep-on-top", "editor.tip.keepOnTop", null],
  ["#pin", "editor.tip.unpin", "pinPlume"],
  ["#open-actions", "editor.tip.actions", "actionPanel"],
  ["#browse", "editor.tip.notes", "browseNotes"],
  ["#new-note", "editor.tip.newNote", "newNote"],
  ["#format-toggle", "editor.tip.format", "formatBar"],
  // The find bar's disclosure is the **only** place ⌥⌘F is printed anywhere in the app — it has no
  // ⌘K row (decision 72) and no Shortcuts row. If this string goes stale the key is documented
  // nowhere, which is why it is listed here rather than left as a literal beside its neighbours.
  ["[data-disclosure]", "editor.tip.replace", "findReplace"],
];
export function refreshChromeTooltips(): void {
  for (const [selector, labelKey, action] of CHROME_TIPS) {
    const element = document.querySelector<HTMLElement>(selector);
    if (!element) continue;
    // The thumbtack names the thing it will do, so its text follows the state.
    const label = t(
      selector === "#keep-on-top" && panelEl.hasAttribute("data-keep-on-top")
        ? "editor.tip.keepOnTop.on"
        : labelKey
    );
    const binding = action ? state.liveShortcuts[action] ?? DEFAULT_SHORTCUTS[action] : undefined;
    describe(element, binding ? `${label} ${keyCaps(binding).join("")}` : label);
  }
}