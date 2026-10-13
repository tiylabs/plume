/*
 * The panel's web layer.
 *
 * Owns the editor, the chrome, the switcher and the format bar. Owns no truth: every note, every
 * pin and every setting arrives from Swift, and every change goes back the same way. The web layer
 * never touches a file.
 *
 * IPC is decision 4's: `WKScriptMessageHandler` inbound (window.webkit.messageHandlers.plume), and
 * `evaluateJavaScript` outbound, which lands on `window.plumeHost`.
 */

import "./styles/tokens.css";
import "./styles/plume.css";
import "./styles/markdown.css";
import "./styles/switcher.css";
import "./styles/action-panel.css";

import { EditorState } from "@codemirror/state";
import { EditorView, placeholder } from "@codemirror/view";

import { mountActionPanel } from "./ui/action-panel";
import { placeOverlay } from "./ui/overlay";
import { mountTooltips } from "./ui/tooltip";
import { mountFind } from "./ui/find";
import { mountSwitcher } from "./ui/switcher";
import { mountFormatBar } from "./ui/format-bar";
import { onLanguageChange, t, translateStaticMarkup } from "./i18n";
import { DEFAULT_SHORTCUTS, keyCaps, matchesBinding } from "./editor/shortcuts";
import { send } from "./bridge/send";
import { createHost } from "./bridge/host";
import type { HostAPI } from "./bridge/protocol";
import { actionsEl, bannerEl, closeEl, editorHost, mountThemeStyle, panelEl, switcherEl } from "./editor/dom";
import { ctx } from "./editor/ctx";
import { state } from "./editor/state";
import {
  actionHandlers, baseExtensions, clearHistory, panelShortcuts, placeholderCompartment, shortcutsCompartment,
} from "./editor/setup";
import { refreshChromeTooltips } from "./editor/chrome-tips";
import { toggleActions, toggleFormatBar, toggleSwitcher } from "./editor/overlays";
import { renderCount, reportDragRegions, scheduleContentHeight, showTitle } from "./editor/chrome";

// ---------------------------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------------------------

declare global {
  interface Window {
    plumeHost: HostAPI;
  }
}

const view = new EditorView({
  state: EditorState.create({ doc: "", extensions: baseExtensions() }),
  parent: editorHost,
});
ctx.view = view;

/* `mousedown`, and prevented: a click would blur the editor and decision 53 would redraw the note
 * under the pointer. Swapped here rather than after Swift's round trip, or the number lags the press
 * (decision 124). */
document.getElementById("word-count")!.addEventListener("mousedown", (event) => {
  event.preventDefault();
  state.footerCount = state.footerCount === "words" ? "characters" : "words";
  renderCount(view.state.doc.toString());
  send({ type: "toggleFooterCount" });
});

// Named from the first frame rather than from the first edit. The markup ships "0 words" as text
// and nothing had ever set the tip, so an untouched panel had one control the bubble could not name.
renderCount(view.state.doc.toString());

document.getElementById("format-toggle")!.addEventListener("click", toggleFormatBar);
closeEl.addEventListener("click", () => send({ type: "close" }));
document.getElementById("keep-on-top")!.addEventListener("click", () =>
  send({ type: "toggleKeepOnTop" })
);
document.getElementById("new-note")!.addEventListener("click", () =>
  send({ type: "createNote", title: "" })
);
document.getElementById("pin")!.addEventListener("click", () =>
  send({ type: "togglePin", filename: state.currentFilename })
);
document.getElementById("browse")!.addEventListener("click", () => toggleSwitcher());
document.getElementById("open-actions")!.addEventListener("click", () => toggleActions());

/* Every button names itself the same way: one string carries the shortcut and becomes the accessible
 * name, so a key cannot be advertised differently in two places (decision 58). */
mountTooltips(panelEl);
// The first call is below, after everything it reads has been built. It used to be that the binding
// table was a `let` declared further down the file, and calling this from up here threw — which took
// out `window.plumeHost` entirely and presented as the whole bridge being missing. The table now
// lives in `state`, so that particular ordering no longer exists; the first call stays where it was.

ctx.formatBar = mountFormatBar(
  document.getElementById("format-bar") as HTMLElement,
  view,
  toggleFormatBar,
  (button, level) => send({ type: "headingMenu", button, level })
);

ctx.find = mountFind({
  root: document.getElementById("find") as HTMLElement,
  panel: panelEl,
  view,
  onLayoutChange: () => {
    scheduleContentHeight();
    reportDragRegions();
  },
});

/* Both overlays are placed by one calculation whenever the panel opens, its height changes, or the
 * panel's height changes after Swift grows the window (decision 45). One `ResizeObserver`, and `top`
 * changes no size, so it cannot feed itself. */
function placeOverlays(): void {
  placeOverlay(switcherEl, panelEl);
  placeOverlay(actionsEl, panelEl);
}

new ResizeObserver(placeOverlays).observe(switcherEl);
new ResizeObserver(placeOverlays).observe(actionsEl);

const actions = ctx.actions = mountActionPanel({
  root: actionsEl,
  panel: panelEl,
  isPinned: () => panelEl.hasAttribute("data-pinned"),
  isHiddenFromCapture: () => state.hiddenFromCapture,
  isAutoSizing: () => state.autoSizing,
  spaceAssignment: () => state.spaceAssignment,
  dockSpaceAssignment: () => state.dockSpaceAssignment,
  run: (id) => actionHandlers[id]?.(),
  chooseSpace: (mode) => send({ type: "setSpaceAssignment", mode }),
  // The keys a row prints come from the bindings in force, not from a literal beside the label.
  // They were literals, so rebinding New Note in the Shortcuts tab left ⌘K still advertising ⌘N —
  // which is exactly what decision 17 forbids: "a row cannot advertise a key that does something
  // else". Rows with no binding of their own (Settings…, which the menu bar owns) keep the literal.
  keysFor: (id) => Object.hasOwn(state.liveShortcuts, id) ? keyCaps(state.liveShortcuts[id]!) : null,
  onVisibilityChange: (open, height) => {
    send({ type: "actionsOpen", open, height });
    if (!open) view.focus();
  },
});

const switcher = ctx.switcher = mountSwitcher({
  root: switcherEl,
  panel: panelEl,
  onQuery: (query) => send({ type: "requestNotes", query }),
  onOpen: (filename) => send({ type: "openNote", filename }),
  onCreate: (title) => send({ type: "createNote", title }),
  onPin: (filename) => send({ type: "togglePin", filename }),
  onDelete: (filename) => send({ type: "deleteNote", filename }),
  isDeleteKey: (event) => matchesBinding(event, state.liveShortcuts.deleteNote ?? DEFAULT_SHORTCUTS.deleteNote!),
  deleteKeyCaps: () => keyCaps(state.liveShortcuts.deleteNote ?? DEFAULT_SHORTCUTS.deleteNote!).join(""),
  onRequestDeleted: () => send({ type: "requestDeleted" }),
  onRestore: (storedName) => send({ type: "restoreDeleted", storedName }),
  onForgetDeleted: (storedName) => send({ type: "forgetDeleted", storedName }),
  onVisibilityChange: (open, height) => {
    send({ type: "switcherOpen", open, height });
    if (!open) view.focus();
  },
});

/* Clicking outside an open overlay closes it and never reaches the note. `mousedown`, prevented: by
 * the time a click completes focus has already left the panel's input (decision 52). */
document.getElementById("overlay-scrim")!.addEventListener("mousedown", (event) => {
  event.preventDefault();
  actions.close();
  switcher.close();
});
refreshChromeTooltips();

/** An open overlay's own shortcut closes it: focus is in a plain `<input>` outside CodeMirror, so the
 * keymap never sees the second press. Capture phase, only while open (decision 45). */
document.addEventListener(
  "keydown",
  (event) => {
    // Only while an overlay is up. With the caret in the editor, CodeMirror's keymap is already
    // handling both of these properly and this must stay out of its way.
    if (!actions.isOpen() && !switcher.isOpen()) return;

    const binding = (action: string) => state.liveShortcuts[action] ?? DEFAULT_SHORTCUTS[action] ?? "";

    // Each key keeps its own meaning from inside either panel: it closes its own panel, and swaps
    // to it from the other one. Handling only the closing half left ⌘K doing nothing at all while
    // the switcher was open, which is a different kind of dead key from the one being fixed.
    if (matchesBinding(event, binding("actionPanel"))) {
      event.preventDefault();
      event.stopPropagation();
      actions.isOpen() ? actions.close() : toggleActions();
      return;
    }
    if (matchesBinding(event, binding("browseNotes"))) {
      event.preventDefault();
      event.stopPropagation();
      switcher.isOpen() ? switcher.close() : toggleSwitcher();
    }
  },
  true
);

// ---------------------------------------------------------------------------------------------
// Inbound — everything Swift can ask the web layer to do
// ---------------------------------------------------------------------------------------------

mountThemeStyle();

const host = createHost({
  view,
  actions,
  switcher,
  shortcutsCompartment,
  panelShortcuts,
  clearHistory,
  refreshChromeTooltips,
  toggleSwitcher,
  toggleActions,
});

window.plumeHost = host;

/* A language switch re-says everything built once: the static markup, the title and footer count,
 * the empty-note prompt, and every chrome tooltip. Open overlays render fresh each time they open,
 * and Swift closes the Settings window — the only place the switch is made — so none of those can
 * be on screen in the old language. The first call is the initial pass: the HTML ships English. */
function retranslate(): void {
  translateStaticMarkup();
  refreshChromeTooltips();
  view.dispatch({
    effects: placeholderCompartment.reconfigure(placeholder(t("editor.placeholder"))),
  });
  showTitle(view.state.doc.iterLines());
  renderCount(view.state.doc.toString());
}
onLanguageChange(retranslate);
translateStaticMarkup();

/* Hover arrives from Swift (`setHover`): the page's own `mouseenter` only fires once the panel has been
 * clicked (decisions 41, 120). The web layer owns no truth. */

// Clicking the banner acknowledges it. That is the whole dismissal affordance: a conflict banner
// with an ✕ would be a control the user must operate before the panel looks normal again, which is
// the interruption decision 8 rules out.
bannerEl.addEventListener("click", () => host.hideBanner());

// Drag regions only, on every title-bar relayout. Never content height: the window's size is not an
// input to how tall the content wants to be, and reporting it here is what made the panel overshoot
// (decision 40, amended 2026-09-17).
new ResizeObserver(() => {
  reportDragRegions();
  placeOverlays();
}).observe(panelEl);

/* The pin enters and leaves the title bar with the panel's pinned state (decision 54), which moves
 * the buttons beside it — and the drag-exclusion rects Swift hit-tests are measured from those
 * boxes. This is the same hook the title's old scroll-gated reveal needed, pointed at the one
 * attribute that still changes the bar's layout. */
new MutationObserver(reportDragRegions).observe(panelEl, {
  attributes: true,
  attributeFilter: ["data-pinned", "data-keep-on-top"],
});

reportDragRegions();
send({ type: "ready" });
