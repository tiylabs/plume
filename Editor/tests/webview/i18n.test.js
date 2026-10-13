/*
 * The editor's language switch, against the real bundle in a real WKWebView.
 *
 * What it guards: that `applySettings({ language })` re-says everything the editor built once — the
 * title, the footer count, static markup, the ⌘K rows — and that a language nobody shipped falls
 * back to English rather than to blank text. The catalogs are the real `Locales/*` files, bundled
 * by `build.mjs`, so this also proves a language directory reaches the page.
 *
 * Deliberately names `zh-Hans` and not "the second language": it asserts the shipped translation, so
 * a key that lost its Chinese text fails here as well as in `LocalizationTests`.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export async function run(view, bar, doc) {
  const failures = []; let checked = 0;
  const check = (name, want, got) => { checked++; if (want !== got) failures.push({ case: name, want: String(want), got: String(got) }); };
  const host = window.plumeHost;
  const txt = (sel) => (doc.querySelector(sel)?.textContent ?? "").trim();
  const aria = (sel) => doc.querySelector(sel)?.getAttribute("aria-label") ?? "";

  host.loadNote("a.md", "", 0, false);
  check("en: footer", "0 words", txt("#word-count"));
  check("en: title", "Untitled", txt("#plume-title"));

  host.applySettings({ language: "zh-Hans" });
  await sleep(50);
  check("zh: footer", "0 个词", txt("#word-count"));
  check("zh: title", "无标题", txt("#plume-title"));
  check("zh: static aria", "格式", aria("#format-bar"));
  check("zh: actions placeholder", "搜索操作…", doc.getElementById("actions-search").placeholder);
  check("zh: new-note tip", "新建笔记", aria("#new-note").replace(/\s*⌘.*/, ""));
  check("zh: find placeholder", "在笔记中查找…", doc.querySelector(".find__input").placeholder);
  check("zh: lang attr", "zh-Hans", doc.documentElement.lang);

  host.openActions(); await sleep(50);
  const rows = [...doc.querySelectorAll(".actions__label")].map((e) => e.textContent.trim());
  check("zh: action panel row 0", "新建笔记", rows[0]);
  check("zh: no English left in action rows", 0, rows.filter((r) => /^[A-Za-z ]+…?$/.test(r)).length);

  host.showNotes([], 0, ""); await sleep(30);
  check("zh: empty switcher", "还没有笔记", txt(".switcher__empty-title"));
  host.applySettings({ language: "xx-unknown" }); await sleep(30);
  check("unknown language falls back to en", "0 words", txt("#word-count"));
  return { checked, failures };
}
