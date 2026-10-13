/*
 * What the panel's own chrome shows and reports: the title, the footer count, the content height and
 * drag regions Swift needs, the toast and the banner.
 *
 * Each reads the elements in `dom.ts` and the page's state in `state.ts`; the editor itself is reached
 * as `ctx.view` at call time, because it is built after this module is loaded.
 */

import { noteTitle } from "../markdown/note-title";
import { caretBlankLineSlack } from "../markdown/live-preview";
import { countCharacters, countWords } from "../markdown/word-count";
import { plural, t } from "../i18n";
import { send } from "../bridge/send";
import type { Rect } from "../bridge/protocol";
import { bannerEl, bannerTextEl, closeEl, panelEl, panelTitleEl, titleBarEl, toastEl, wordCountEl } from "./dom";
import { ctx } from "./ctx";
import { state } from "./state";

/** The note's name — its first non-blank line read as prose, one `noteTitle` for the bar and the
 * switcher, followed as it is typed (decisions 2, 67). */
export function showTitle(lines: Iterable<string>): void {
  // "Untitled" rather than nothing, which is what an empty note showed until ⌘N stopped writing a
  // file the moment it was pressed. A panel with no title and no text reads as broken; the reference
  // names it, and the switcher already calls a nameless note Untitled, so this is the two agreeing.
  panelTitleEl.textContent = noteTitle(lines) || t("editor.untitled");
}
function formatWordCount(n: number): string {
  return plural("editor.count.words", n);
}
export function renderCount(text: string): void {
  if (state.footerCount === "characters") {
    const n = countCharacters(text);
    wordCountEl.textContent = plural("editor.count.characters", n);
  } else {
    wordCountEl.textContent = formatWordCount(countWords(text));
  }
}
/**
 * Tells Swift how tall the note wants to be, so the window can follow it.
 *
 * Rule 2 is implemented on the Swift side — width fixed, height grows downward until 24px from the
 * screen bottom, then the note scrolls. All the web layer contributes is the desired height.
 */
let lastReportedHeight = -1;
let heightFrame = 0;
let settlePass = false;
/**
 * Content height is asked for when the *content* changes, plus one settle pass for CodeMirror's
 * refined layout — never from the `ResizeObserver`, which fed a report → resize → re-estimate loop
 * and made the panel overshoot on every new line (decision 40, amended 2026-09-17).
 */
export function scheduleContentHeight(): void {
  if (heightFrame) return;
  heightFrame = requestAnimationFrame(() => {
    heightFrame = 0;
    settlePass = false;
    reportContentHeight();
  });
}
function reportContentHeight(): void {
  // `view.contentHeight`, never `scrollHeight`: the host is `height: 100%`, so scrollHeight equals
  // clientHeight and the panel would report its current height as the one it wants. Minus the caret's
  // blank-line slack, a rendering choice the window must not follow (`caretBlankLineSlack`).
  const content = ctx.view.contentHeight - caretBlankLineSlack(ctx.view);

  // Whichever of the three rows is laid out, found by measuring: with ⌘F open both the footer and
  // the format bar are hidden, and reading an attribute measured a `display: none` row as 0 (decision 66).
  const bar = [".find", ".format-bar", ".plume__footer"]
    .map((selector) => panelEl.querySelector<HTMLElement>(selector))
    .find((element) => (element?.offsetHeight ?? 0) > 0);
  const chrome = titleBarEl.offsetHeight + (bar?.offsetHeight ?? 0) + bannerEl.offsetHeight;

  const height = Math.ceil(content + chrome);

  // An unchanged answer is not worth a resize, and re-sending one is how a two-value oscillation
  // stays alive.
  if (height === lastReportedHeight) return;
  lastReportedHeight = height;
  send({ type: "contentHeight", height });

  // One re-measure after the window has had a frame to become the size we just asked for. If the
  // refined layout disagrees, that correction is sent and the chain stops there.
  if (settlePass) return;
  settlePass = true;
  requestAnimationFrame(() => requestAnimationFrame(reportContentHeight));
}
/** Tells Swift where the window may be dragged from. `-webkit-app-region` is inert in a WKWebView
 * (LAB, 2026-08-15), so the web layer measures the title bar minus its buttons and Swift hit-tests. */
export function reportDragRegions(): void {
  const box = (el: Element): Rect => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  };
  const bar = box(titleBarEl);
  const exclusions = Array.from(titleBarEl.querySelectorAll("button")).map(box);

  send({
    type: "dragRegions",
    titleBar: bar,
    exclusions,
    // Named rather than picked out of `exclusions` by index (decision 107). The dot is already in
    // that list — it is a button in the bar — but reading it back out means depending on document
    // order, and the pin comes and goes from this bar with the pinned state.
    close: box(closeEl),
  });
}
// ---------------------------------------------------------------------------------------------
// Toast and banner
// ---------------------------------------------------------------------------------------------

/** Auto-dismiss timers for the toast. */
let toastTimer = 0;
let toastFadeTimer = 0;

/** A transient confirmation. Out of layout, so it never disturbs the reported height. */
export function showToast(text: string, dwell?: number): void {
  toastEl.textContent = text;
  toastEl.hidden = false;
  toastEl.removeAttribute("data-fading");
  if (toastTimer) clearTimeout(toastTimer);
  if (toastFadeTimer) clearTimeout(toastFadeTimer);
  // 1900ms reads a short receipt; `dwell` is longer for the one toast that is news (decision 136).
  toastTimer = window.setTimeout(() => {
    toastEl.setAttribute("data-fading", "");
    toastFadeTimer = window.setTimeout(() => {
      toastEl.hidden = true;
    }, 200);
  }, dwell ?? 1900);
}

/**
 * The one-line status row: a conflict sibling was written, a note is downloading, or something
 * failed. Never steals the caret and never blocks typing.
 */
export function showBanner(kind: string, text: string): void {
  bannerEl.setAttribute("data-kind", kind);
  bannerTextEl.textContent = text;
  bannerEl.hidden = false;
  scheduleContentHeight();
}

export function hideBanner(): void {
  if (bannerEl.hidden) return;
  bannerEl.hidden = true;
  bannerEl.removeAttribute("data-kind");
  scheduleContentHeight();
}
