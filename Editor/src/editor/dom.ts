/*
 * The elements of the panel's own markup, looked up once.
 *
 * The page is a single HTML file whose structure is fixed, so a missing element is a build error to
 * be found immediately, not a case to handle: these are cast, not checked.
 */

const byId = (id: string): HTMLElement => document.getElementById(id) as HTMLElement;

export const panelEl = byId("plume");
export const titleBarEl = byId("titlebar");
export const closeEl = byId("close");
export const panelTitleEl = byId("plume-title");
export const wordCountEl = byId("word-count");
export const editorHost = byId("editor-host");
export const toastEl = byId("toast");
export const bannerEl = byId("banner");
export const bannerTextEl = byId("banner-text");
export const actionsEl = byId("actions");
export const switcherEl = byId("switcher");

/// Where a user's markdown theme lands (decision 19). Appended last so it wins the cascade against
/// the bundled stylesheets without needing !important. Created here but not attached: module top
/// levels have no side effects except `main.ts`, so `main.ts` calls `mountThemeStyle`.
export const themeStyleEl = document.createElement("style");
themeStyleEl.id = "markdown-theme";

export function mountThemeStyle(): void {
  document.head.appendChild(themeStyleEl);
}
