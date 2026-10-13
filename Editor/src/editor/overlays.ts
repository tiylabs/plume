/*
 * The two overlays (⌘P, ⌘K) and the format bar: opening, closing, and the rule that only one thing
 * is open at a time.
 *
 * They are built in `main.ts`; these functions reach them through `ctx` when called, which is
 * always after startup.
 */

import { panelEl } from "./dom";
import { ctx } from "./ctx";
import { reportDragRegions, scheduleContentHeight } from "./chrome";

export function toggleFormatBar(): void {
  // One footer row, never two (decision 22). Find and the format bar are both that row, so opening
  // either has to put the other away.
  ctx.find?.close();
  panelEl.toggleAttribute("data-format-bar");
  ctx.formatBar?.refresh();
  // The bar and the footer are different heights, so swapping them changes how much room the note
  // has — and the window has to follow.
  scheduleContentHeight();
  reportDragRegions();
}

/** One slot: opening either panel closes the other first, here rather than at every call site
 * (decision 45). */
export function toggleSwitcher(): void {
  ctx.actions.close();
  ctx.switcher.toggle();
}

export function toggleActions(): void {
  ctx.switcher.close();
  ctx.actions.toggle();
}

export function openSpaceAssignment(): void {
  ctx.switcher.close();
  ctx.actions.openSpaceAssignment();
}