/*
 * Everything Swift can ask the page to do: `window.plumeHost`, typed as `HostAPI`.
 *
 * Built by a factory rather than written at the top level so that this module has no startup side
 * effects and no hidden order. What it needs that is built in `main.ts` — the editor, the two
 * overlays, the keymap pieces — arrives as `deps`, a typed list: reading it tells you what the host
 * touches.
 */

import { Transaction } from "@codemirror/state";
import type { Compartment, Extension } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { setLanguage } from "../i18n";
import { hideTooltip, setPointer } from "../ui/tooltip";
import { setHeading } from "../ui/format-bar";
import type { mountActionPanel } from "../ui/action-panel";
import type { mountSwitcher } from "../ui/switcher";
import type { DockSpaceAssignmentState, HostAPI, NoteSummary } from "./protocol";
import { hideBanner, renderCount, scheduleContentHeight, showBanner, showTitle, showToast } from "../editor/chrome";
import { panelEl, themeStyleEl } from "../editor/dom";
import { DEFAULT_SHORTCUTS } from "../editor/shortcuts";
import { state } from "../editor/state";

export interface HostDeps {
  view: EditorView;
  actions: ReturnType<typeof mountActionPanel>;
  switcher: ReturnType<typeof mountSwitcher>;
  shortcutsCompartment: Compartment;
  panelShortcuts: (bindings: Record<string, string>) => Extension;
  clearHistory: () => void;
  refreshChromeTooltips: () => void;
  toggleSwitcher: () => void;
  toggleActions: () => void;
}

export function createHost(deps: HostDeps): HostAPI {
  const { view, actions, switcher, shortcutsCompartment, panelShortcuts, clearHistory, refreshChromeTooltips, toggleSwitcher, toggleActions } = deps;

  return {
    /**
     * Loads a note and puts the caret back exactly where it was (decision 11).
     *
     * The whole document is replaced rather than diffed: this only runs on a note switch or an
     * external-change reload, and a diff would be a second place for the buffer to drift from the file.
     */
    loadNote(filename: string, text: string, caret: number, pinned: boolean): void {
      state.applyingRemoteEdit = true;
      // An empty name means a draft: ⌘N no longer touches the disk, so the panel can hold a note that
      // has no file yet. Stored as null rather than "" so every `currentFilename ?` guard here —
      // Delete Note, Pin Note — declines instead of naming a file that does not exist.
      state.currentFilename = filename || null;
  
      const clamped = Math.max(0, Math.min(caret, text.length));
      // `finally`, because a throw here used to leave the flag set for the rest of the session: every
      // later edit was then silently never sent, so never written (164).
      try {
        view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert: text },
          selection: { anchor: clamped },
          scrollIntoView: true,
          // Loading a note is not an edit: without this annotation the first ⌘Z undid the load, emptied
          // the note, and the write model flushed the empty buffer (decision 80).
          annotations: Transaction.addToHistory.of(false),
        });
        // And a fresh stack, so undo cannot reach back past this note into the last one.
        clearHistory();
      } finally {
        state.applyingRemoteEdit = false;
      }
  
      panelEl.toggleAttribute("data-pinned", pinned);
      document.getElementById("pin")!.setAttribute("aria-pressed", String(pinned));
      showTitle(text.split("\n"));
      renderCount(text);
      scheduleContentHeight();
    },
  
    /** Puts the caret in the editor without changing anything — what a summon does. */
    focusEditor(): void {
      view.focus();
    },
  
    /** Undo describes one sitting with the note: the buffer survives a dismissal offscreen, so a summon
     * starts the history fresh rather than reaching back across it (decision 80, amended 2026-09-17;
     * decision 51's reasoning). */
    resetHistory(): void {
      clearHistory();
    },
  
    /**
     * The draft on screen has just become a real file.
     *
     * Deliberately not `loadNote`: the buffer is already correct and the user is typing in it, so
     * re-sending the document would replace it under their hands and move the caret. Only the name
     * changes.
     */
    setNoteFilename(filename: string): void {
      state.currentFilename = filename || null;
    },
  
    setPinned(pinned: boolean): void {
      panelEl.toggleAttribute("data-pinned", pinned);
      document.getElementById("pin")!.setAttribute("aria-pressed", String(pinned));
    },
  
    setFocused(focused: boolean): void {
      // Kept for anything that genuinely cares about key state. It no longer drives the chrome —
      // decision 41 moved that to the cursor — and so it no longer changes the title bar's layout,
      // which is why the drag regions do not need re-reporting here any more.
      panelEl.toggleAttribute("data-focused", focused);
    },
  
    /** Appearance, accent, theme and key bindings. The CSS keys off these attributes and variables. */
    applySettings(settings): void {
      // First: the rest of this method re-renders text, and it should come out in the right language.
      if (settings.language) setLanguage(settings.language);
  
      const root = document.documentElement;
      if (settings.appearance && settings.appearance !== "system") {
        root.setAttribute("data-appearance", settings.appearance);
      } else {
        root.removeAttribute("data-appearance");
      }
      if (settings.panelOpacity !== undefined) {
        const opacity = Math.min(1, Math.max(0, settings.panelOpacity));
        root.setAttribute("data-vibrancy", opacity < 1 ? "on" : "off");
        root.style.setProperty("--panel-opacity", String(opacity));
        // Liquid Glass scrim, cubic so the slider has real range. Unfocused is the base; focused is
        // lifted toward opaque so a panel you are reading or editing is the deeper one. At the fully
        // transparent end the unfocused panel is bare glass and the focused one keeps a light wash.
        const base = opacity ** 3;
        root.style.setProperty("--panel-glass-alpha", String(base));
        root.style.setProperty("--panel-glass-alpha-focus", String(base + (1 - base) * 0.3));
        // Preserve the original dark scrim (60% at the default 70% light opacity),
        // while both themes reach fully transparent and fully opaque at the endpoints.
        root.style.setProperty("--panel-opacity-dark", String(Math.max(0, opacity - (1 - opacity) / 3)));
      }
      if (settings.glass !== undefined) {
        if (settings.glass) root.setAttribute("data-material", "glass");
        else root.removeAttribute("data-material");
      }
      if (settings.textSize) root.style.setProperty("--text-size", `${settings.textSize}px`);
      if (settings.accent) {
        root.style.setProperty("--accent-light", settings.accent);
        root.style.setProperty("--accent-dark", settings.accentDark ?? settings.accent);
      }
  
      // Decision 19: a theme is a CSS file. Swift reads it and hands over the text; all that happens
      // here is that it goes last in the cascade, after tokens/plume/markdown, so a theme can override
      // any token without !important and without knowing the stylesheet order.
      if (settings.themeCSS !== undefined) themeStyleEl.textContent = settings.themeCSS;
  
      if (settings.footerCount === "words" || settings.footerCount === "characters") {
        state.footerCount = settings.footerCount;
        renderCount(view.state.doc.toString());
      }
  
      if (settings.shortcuts) {
        state.liveShortcuts = { ...DEFAULT_SHORTCUTS, ...settings.shortcuts };
        view.dispatch({
          effects: shortcutsCompartment.reconfigure(panelShortcuts(settings.shortcuts)),
        });
        // The chrome's bubbles print keys too, and a rebind has to reach them or a button goes on
        // advertising a key that now does something else — decision 17's rule, in its fourth place.
        refreshChromeTooltips();
      }
    },
  
    showNotes(notes: NoteSummary[], total: number, query: string): void {
      switcher.render(notes, total, query);
    },
  
    /** Recently Deleted's rows (decision 20). Same shape, same list, different verb on ⏎. */
    showDeleted(notes: NoteSummary[]): void {
      switcher.renderDeleted(notes);
    },
  
    setHiddenFromCapture(hidden: boolean): void {
      state.hiddenFromCapture = hidden;
    },
  
    setKeepOnTop(on: boolean): void {
      panelEl.toggleAttribute("data-keep-on-top", on);
      document.getElementById("keep-on-top")!.setAttribute("aria-pressed", String(on));
      refreshChromeTooltips();
    },
  
    setSpaceAssignment(mode: string, desktop: number | null, canKeepToOne: boolean): void {
      state.spaceAssignment = { mode, desktop, canKeepToOne };
      actions.refresh();
    },
  
    setDockSpaceAssignment(mode: DockSpaceAssignmentState["mode"], desktop: number | null): void {
      if (state.dockSpaceAssignment.mode === mode && state.dockSpaceAssignment.desktop === desktop) return;
      state.dockSpaceAssignment = { mode, desktop };
      actions.refresh();
    },
  
    setAutoSizing(on: boolean): void {
      state.autoSizing = on;
    },
  
    /** The close dot alone, from the same read as `setHover`: `:hover` cannot, because the page gets no
     * mouse events with the panel over another app (decision 107). */
    setCloseHover(inside: boolean): void {
      panelEl.toggleAttribute("data-close-hover", inside);
    },
  
    setHover(inside: boolean): void {
      panelEl.toggleAttribute("data-hover", inside);
      // The dot cannot be hovered when the panel is not: both come from one pointer read, and leaving
      // the panel behind a stale `data-close-hover` would strand a lit dot on a dimmed bar.
      if (!inside) panelEl.removeAttribute("data-close-hover");
      // The pointer can leave a *window* without the page seeing a leave event, and the chrome it was
      // over is about to fade out from under any tooltip naming it.
      if (!inside) hideTooltip();
    },
  
    /** Where the pointer is, from Swift, on every move: the page gets no mouse events in the state the
     * panel lives in (decision 120). */
    setPointer(x: number, y: number): void {
      setPointer(x, y);
    },
  
    openSwitcher(): void {
      // Toggle, not open: this is what ⌘P and the menu bar's "Browse Notes…" both land on, and a
      // second press of either should close the list rather than silently do nothing.
      toggleSwitcher();
    },
  
    openActions(): void {
      // Same contract as `openSwitcher`, for the menu bar's "Actions…". Frame 2a leans on the menu bar
      // as one of ⌘K's two discovery paths; this is that path.
      toggleActions();
    },
  
    /** Chosen from the native heading menu. */
    setHeadingLevel(level: number): void {
      setHeading(view, level);
    },
  
    showToast,
  
    showBanner,
  
    hideBanner,
  };
}
