/*
 * Where the switcher and ⌘K sit inside the panel.
 *
 * Both are one component in two modes (decision 46), so their placement is one calculation in one
 * place rather than a literal repeated in two stylesheets. The stylesheets keep the *tokens* — this
 * reads them, so there is one set of numbers.
 *
 * The old placement was `top: 54px`, which is the right answer only for the panel that is exactly
 * tall enough to hold the panel. On a tall panel it pinned the panel under the title bar with a
 * third of the panel empty beneath it, and on a narrow panel the panel's fixed 460px left an 18px
 * margin either side — measured on a 496pt panel, which is the width this panel is actually used at.
 * The reference, in a window of the same 496×800: panel 362 wide with 67pt margins, top edge 120pt
 * down. Both of those are *relative* to the window, which is the whole difference.
 */

const root = getComputedStyle(document.documentElement);

/** Closest the panel ever comes to the top of the panel — the panel must grow to at least this. */
export const OVERLAY_TOP_MIN = Number.parseFloat(root.getPropertyValue("--overlay-top-min")) || 54;

/** Plume left under the panel. Below this the panel reads as resting on the panel's bottom corner. */
export const OVERLAY_GAP_BOTTOM =
  Number.parseFloat(root.getPropertyValue("--overlay-gap-bottom")) || 16;

/**
 * The design ceiling on either panel — the same number for both, which is what makes them one
 * rectangle in two modes.
 *
 * Read from the token rather than off the element, and that distinction is the whole reason this
 * constant exists. The stylesheets cap each panel at `min(this, the panel's own height)`, so on a
 * panel that has not grown yet `getComputedStyle(panel).maxHeight` reports the *panel's* limit — the
 * panel would report that it already fits, the panel would never grow, and the panel would stay
 * clipped at whatever height it opened in.
 */
export const OVERLAY_PANEL_HEIGHT =
  Number.parseFloat(root.getPropertyValue("--overlay-panel-height")) || 380;

/**
 * Where the top edge goes, as a fraction of the panel's height.
 *
 * Measured off the reference at two window sizes: 120/800 and 158/981, so 15–16% either way rather
 * than a fixed offset. Sitting the panel a sixth of the way down is what makes it read as placed in
 * the panel instead of hung off the title bar.
 */
const TOP_RATIO = 0.15;

/**
 * The top edge for a panel of this height in a panel of that height.
 *
 * The clamp is what keeps this consistent with the panel growing to fit (decision 45): when the panel
 * has had to grow, there is no slack left and this returns `OVERLAY_TOP_MIN` — the same number Swift
 * used to work out how tall to grow. So the panel never asks for a position the panel cannot honour,
 * and the two never argue.
 */
export function overlayTop(plumeHeight: number, panelHeight: number): number {
  const lowestThatFits = Math.max(OVERLAY_TOP_MIN, plumeHeight - panelHeight - OVERLAY_GAP_BOTTOM);
  return Math.round(Math.min(Math.max(OVERLAY_TOP_MIN, plumeHeight * TOP_RATIO), lowestThatFits));
}

/** Places one overlay, if it is on screen. A hidden panel has no height and nothing to place. */
export function placeOverlay(panel: HTMLElement, plume: HTMLElement): void {
  const height = panel.offsetHeight;
  if (height === 0) return;
  panel.style.top = `${overlayTop(plume.clientHeight, height)}px`;
}

/**
 * The height an overlay *wants*, which is not the height it currently has.
 *
 * `offsetHeight` is capped by the panel (see the `max-height` rules in the two stylesheets), so
 * reporting it would tell Swift the panel already fits and the panel would never grow — on a short
 * note ⌘K came up two and a half rows tall with everything else scrolled out of reach. The panel
 * still has to grow to hold the panel (decision 45); the CSS cap exists for when it *cannot*,
 * because the screen ran out, and a clipped panel is then the lesser of two evils.
 *
 * So: the panel's chrome — its search field, its footer if it has one, its borders — plus everything
 * its list would show, and then the design ceiling, which is the number both panels share.
 *
 * The chrome is measured as `offsetHeight - list.clientHeight` and survives the panel being clipped,
 * because clipping takes its points out of the list and the subtraction takes them back.
 *
 * This is a ceiling and not a height: a ⌘K filtered to two rows asks for two rows, and the panel it
 * is drawn in does not grow for the two it is not showing.
 *
 * Lives here because the switcher and ⌘K are one component in two modes (decision 46) and this is
 * the last thing they did differently — ⌘K measured itself and ⌘P was a constant in Swift.
 */
export function desiredOverlayHeight(panel: HTMLElement, list: HTMLElement): number {
  const chrome = panel.offsetHeight - list.clientHeight;
  return Math.min(chrome + list.scrollHeight, OVERLAY_PANEL_HEIGHT);
}

/**
 * Whether a `mousemove` is the pointer moving (183). Scrolling a list under a still pointer makes
 * WebKit send the row now beneath it a `mousemove` at the same screen point, and a list whose rows
 * follow the pointer would hand that row the selection — the arrow keys jumped back every few rows.
 * The first event after `reset` only records where the pointer is, so a list that opens under a
 * resting pointer keeps its first row.
 */
export function pointerMotion(): { moved(event: MouseEvent): boolean; reset(): void } {
  let last: { x: number; y: number } | null = null;
  return {
    moved(event) {
      const was = last;
      last = { x: event.screenX, y: event.screenY };
      return was !== null && (was.x !== last.x || was.y !== last.y);
    },
    reset() {
      last = null;
    },
  };
}
