/*
 * The shape of everything the page can tell Swift.
 *
 * Mirrors `BridgeMessage` in Sources/Plume/Bridge/BridgeMessage.swift. Neither side is checked by a
 * compiler against the other, so `Editor/tests/bridge-names.mjs` reads both and fails when the sets
 * of names disagree.
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
