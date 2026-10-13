/*
 * The bridge, as a contract: everything the page can tell Swift (`OutboundMessage`) and everything
 * Swift can tell the page (`HostAPI`).
 *
 * Neither side is checked by a compiler against the other, so the Swift side is held to this file by
 * `Tests/PlumeKitTests/Bridge/BridgeContractTests.swift`, which reads it as text and fails when the
 * names, the argument counts or the message fields disagree. `main.ts` types its `host` object as
 * `HostAPI`, so TypeScript itself fails when the page stops implementing a method.
 *
 * To add a message or a method: add it here, in `BridgeMessage` / `EditorCommand` in
 * Sources/PlumeKit/Bridge/, and in `main.ts`. A test goes red until all three agree.
 */

export type OutboundMessage =
  | { type: "ready" }
  | { type: "edited"; text: string; caret: number }
  | { type: "caret"; caret: number; scrollLine: number }
  | { type: "requestNotes"; query: string }
  | { type: "openNote"; filename: string }
  | { type: "createNote"; title: string }
  | { type: "togglePin"; filename: string | null }
  | { type: "deleteNote"; filename: string }
  | { type: "close" }
  | { type: "contentHeight"; height: number }
  | { type: "switcherOpen"; open: boolean; height: number }
  | { type: "actionsOpen"; open: boolean; height: number }
  | { type: "revealInFinder" }
  /**
   * ⌘-click on a link (decision 138). Carries the node's raw text, not a URL: whether that text may
   * be opened at all is `LinkTarget.resolve`'s question, in PlumeKit where it is tested.
   */
  | { type: "openLink"; target: string }
  /** ⌘K row fifteen (decision 103). Swift owns the vault, so the page can only ask. */
  | { type: "renameFile" }
  | { type: "openSettings" }
  | { type: "copyAsMarkdown"; text: string }
  | { type: "exportNote"; text: string }
  | { type: "toggleHideFromCapture" }
  | { type: "toggleAutoSizing" }
  /** ⌘K's Assign to Desktop: `Settings.SpaceAssignment`'s raw value. Swift works out the desktop. */
  | { type: "setSpaceAssignment"; mode: string }
  | { type: "toggleKeepOnTop" }
  | { type: "toggleFooterCount" }
  | { type: "duplicateNote"; text: string }
  | { type: "requestDeleted" }
  | { type: "restoreDeleted"; storedName: string }
  | { type: "forgetDeleted"; storedName: string }
  | { type: "textSize"; action: "in" | "out" | "reset" }
  | { type: "navigate"; back: boolean }
  | { type: "dragRegions"; titleBar: Rect; exclusions: Rect[]; close: Rect }
  | { type: "headingMenu"; button: Rect; level: number | null };

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** A row of the switcher, as PlumeKit's `SwitcherRow` encodes it. */
export interface NoteSummary {
  filename: string;
  title: string;
  /** Preformatted by PlumeKit: "now", "42m", "2h", "Thu", "Jul 30", "May 12, 2025". */
  time: string;
  preview: string;
  /** "Pinned", "Today", "Yesterday", "This week", "July"… Absent when the list is flat. */
  band?: string;
  pinned?: boolean;
  current?: boolean;
  /** Set when the query matched the body: the snippet replaces the preview, highlighted. */
  match?: { pre: string; hit: string; post: string };
}

/** The panel's Space assignment, from Swift — the page cannot see Spaces. */
export interface SpaceAssignmentState {
  /** `Settings.SpaceAssignment`'s raw value: `unassigned`, `oneSpace` or `everySpace`. */
  mode: string;
  /** The desktop This Desktop names: the one kept to, or the one it would keep to if chosen now. */
  desktop: number | null;
  /** Whether Swift can tell desktops apart at all. Without it there is no This Desktop to offer. */
  canKeepToOne: boolean;
}

/** The system observation takes precedence over Plume's saved assignment. */
export interface DockSpaceAssignmentState {
  mode: "checking" | "unknown" | "unassigned" | "oneSpace" | "everySpace";
  desktop: number | null;
}

/** What `applySettings` carries. Every key is optional: Swift sends the whole set, a test sends one. */
export interface PanelSettings {
  appearance?: string;
  accent?: string;
  accentDark?: string;
  textSize?: number;
  panelOpacity?: number;
  glass?: boolean;
  themeCSS?: string;
  shortcuts?: Record<string, string>;
  footerCount?: string;
  language?: string;
}

/**
 * Everything Swift can call on `window.plumeHost`, by name and by argument list.
 *
 * `EditorCommand` in PlumeKit has one case per method here; the contract test compares the two.
 */
export interface HostAPI {
  /** Loads a note and puts the caret back exactly where it was. */
  loadNote(filename: string, text: string, caret: number, pinned: boolean): void;
  focusEditor(): void;
  resetHistory(): void;
  setNoteFilename(filename: string): void;
  setPinned(pinned: boolean): void;
  setFocused(focused: boolean): void;
  applySettings(settings: PanelSettings): void;
  showNotes(notes: NoteSummary[], total: number, query: string): void;
  showDeleted(notes: NoteSummary[]): void;
  setHiddenFromCapture(hidden: boolean): void;
  setKeepOnTop(on: boolean): void;
  setSpaceAssignment(mode: string, desktop: number | null, canKeepToOne: boolean): void;
  setDockSpaceAssignment(mode: DockSpaceAssignmentState["mode"], desktop: number | null): void;
  setAutoSizing(on: boolean): void;
  /** The close dot alone, from the same read as `setHover`. */
  setCloseHover(inside: boolean): void;
  setHover(inside: boolean): void;
  /** Where the pointer is, on every move: the page gets no mouse events in the state the panel lives in. */
  setPointer(x: number, y: number): void;
  openSwitcher(): void;
  openActions(): void;
  /** Chosen from the native heading menu. */
  setHeadingLevel(level: number): void;
  /** A transient confirmation. `dwell` (ms) is longer for the one toast that is news. */
  showToast(text: string, dwell?: number): void;
  showBanner(kind: string, text: string): void;
  hideBanner(): void;
}
