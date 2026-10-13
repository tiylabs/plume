/*
 * What the page remembers between messages.
 *
 * The web layer owns no truth — every note, pin and setting arrives from Swift — but it has to hold
 * the last thing it was told, and a few flags of its own. They were module-level `let`s in `main.ts`;
 * an imported binding cannot be assigned, so they live as properties of one object instead.
 */

import type { DockSpaceAssignmentState, SpaceAssignmentState } from "../bridge/protocol";
import { DEFAULT_SHORTCUTS } from "./shortcuts";

export const state = {
  /** The file the note on screen is stored in, or null for a draft that has none yet. */
  currentFilename: null as string | null,

  /** Suppresses the `edited` message while Swift is loading a note into the buffer. */
  applyingRemoteEdit: false,

  /** The footer's number, and which one: a press swaps it, and it carries no bubble — a number in
   * English says its own name (decisions 124, 76). */
  footerCount: "words" as "words" | "characters",

  /** Swift owns this — it is a window property, not a document one — and mirrors it back here. */
  hiddenFromCapture: false,

  /** Likewise window state, and it changes without this layer being asked: dragging the panel turns it
   *  off (decision 40). Only ever set from Swift. */
  autoSizing: true,

  /** Which desktop the panel is assigned to. Swift's to decide — the page cannot see Spaces. */
  spaceAssignment: { mode: "unassigned", desktop: null, canKeepToOne: false } as SpaceAssignmentState,
  dockSpaceAssignment: { mode: "checking", desktop: null } as DockSpaceAssignmentState,

  /** The bindings in force, so the listeners follow a rebind from the Settings window. */
  liveShortcuts: { ...DEFAULT_SHORTCUTS } as Record<string, string>,
};
