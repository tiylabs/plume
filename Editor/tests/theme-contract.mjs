/*
 * The theme contract.
 *
 * A theme is a CSS file in ~/Library/Application Support/Plume/Themes. Plume ships two presets and
 * the user writes the rest, so the selectors those files use are a public interface that this
 * repository cannot fix up after the fact: rename `.plume-line-h1` and every user's heading theme
 * silently stops applying.
 *
 * `theme-api.txt` is that interface, one selector class per line. Three things are checked:
 *
 *   1. every class the preset themes in Themes/ use is listed;
 *   2. every `.plume-*` decoration class styled in markdown.css is listed, so a new one has to be
 *      registered on purpose rather than becoming public by accident;
 *   3. every listed `plume-*` class is still styled in markdown.css and still produced by the
 *      source — so deleting or renaming one fails here instead of in somebody's theme.
 *
 * Plain node, no dependencies:  node tests/theme-contract.mjs
 */

import { readFile, readdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const editor = resolve(here, "..");
const repo = resolve(editor, "..");

/*
 * Classes that are listed, or used by a preset theme, but that nothing produces today. Found while
 * writing this check, and left alone on purpose: the refactor that introduced this file must not
 * change behaviour. Each one is a bug to fix on its own, after which the entry is deleted.
 */
const KNOWN_DEAD = {
  "plume-line-li":
    "Themes/Compact.css:27 styles `.cm-line.plume-line-li`, but the editor only ever produces `plume-line-li-1` … `-4`, so that rule matches nothing",
};

const problems = [];
const fail = (message) => problems.push(message);

async function walk(dir, keep) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(path, keep)));
    else if (keep(path)) out.push(path);
  }
  return out;
}

// Comments are stripped first: a class named in prose (`.plume-bullet-N`) is not a selector.
const classesIn = (css) =>
  new Set([...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/\.((?:plume|cm)-[A-Za-z0-9_-]*[A-Za-z0-9_])/g)].map((m) => m[1]));

const listed = new Set(
  (await readFile(join(here, "theme-api.txt"), "utf8"))
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#")),
);


// What the source produces: a literal `"plume-x"`, or a template `plume-x-${…}` with a numeric tail.
const sources = await walk(join(editor, "src"), (p) => p.endsWith(".ts"));
const produced = new Set();
const prefixes = [];
for (const file of sources) {
  const text = await readFile(file, "utf8");
  for (const m of text.matchAll(/(?<![A-Za-z0-9_-])(plume-[a-z0-9]+(?:--?[a-z0-9]+)*)(?![A-Za-z0-9_-])/g)) produced.add(m[1]);
  for (const m of text.matchAll(/(plume-[a-z0-9-]*-)\$\{/g)) prefixes.push(m[1]);
}
const isProduced = (name) =>
  produced.has(name) || prefixes.some((p) => name.startsWith(p) && /^\d+$/.test(name.slice(p.length)));

// 1. What the preset themes use.
const themeFiles = await walk(join(repo, "Themes"), (p) => p.endsWith(".css"));
for (const file of themeFiles) {
  for (const name of classesIn(await readFile(file, "utf8"))) {
    if (!listed.has(name)) fail(`${file.slice(repo.length + 1)} uses .${name}, which is not in theme-api.txt`);
  }
}

// 2. What the editor both styles and produces. Only the `plume-*` decorations: `.plume__*` is
// chrome and `.cm-*` is CodeMirror's own. A class that is styled but never produced (`.plume-raw`)
// is dead CSS, not interface, so it does not have to be listed.
const markdownCss = await readFile(join(editor, "src/styles/markdown.css"), "utf8");
const styled = new Set([...classesIn(markdownCss)].filter((n) => n.startsWith("plume-")));
for (const name of styled) {
  if (isProduced(name) && !listed.has(name)) {
    fail(`markdown.css styles .${name} and the editor produces it, but it is not in theme-api.txt — register it if it is meant to be public`);
  }
}

// 3. Everything listed must still be styled and still produced.
for (const name of listed) {
  if (!name.startsWith("plume-")) continue;
  if (name in KNOWN_DEAD) continue;
  if (!styled.has(name)) fail(`theme-api.txt lists .${name}, but markdown.css no longer styles it`);
  if (!isProduced(name)) fail(`theme-api.txt lists .${name}, but nothing in Editor/src produces it`);
}
// A known-dead entry that has come back to life should be deleted from the table above.
for (const name of Object.keys(KNOWN_DEAD)) {
  if (isProduced(name) && styled.has(name)) fail(`.${name} is no longer dead — remove it from KNOWN_DEAD`);
}

if (problems.length) {
  console.error(`✗ theme contract: ${problems.length} problem${problems.length === 1 ? "" : "s"}`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
const dead = Object.keys(KNOWN_DEAD);
console.log(`✓ theme contract: ${listed.size} public classes, ${themeFiles.length} preset themes` +
  (dead.length ? `, ${dead.length} known-dead selector (${dead.map((n) => "." + n).join(", ")})` : ""));
