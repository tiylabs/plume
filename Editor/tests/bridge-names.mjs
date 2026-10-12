/*
 * The names that cross the Swift ⇄ web bridge, checked from both ends.
 *
 *   web → Swift   `OutboundMessage` in TypeScript    ⇄   the `case "…"` table that decodes them in Swift
 *   Swift → web   `editor.call("…")` in Swift         ⇄   the methods on the `host` object in TypeScript
 *
 * Neither direction is checked by a compiler, because the other side is a string. A message the
 * page stops sending, or a method Swift calls that no longer exists, is a silent no-op at runtime.
 * So this reads both sides as text and fails when they disagree, and freezes the result in
 * `bridge-names.txt` so adding, removing or renaming one is a visible, reviewed change.
 *
 * This is the interim guard. It is replaced by a typed contract test once the protocol moves into
 * PlumeKit (docs/architecture-refactor-plan.md, PR 3.5).
 *
 *   node tests/bridge-names.mjs            check
 *   node tests/bridge-names.mjs --update   rewrite bridge-names.txt after a deliberate change
 */

import { readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const editor = resolve(here, "..");
const repo = resolve(editor, "..");
const snapshotPath = join(here, "bridge-names.txt");

async function walk(dir, keep) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(path, keep)));
    else if (keep(path)) out.push(path);
  }
  return out;
}

const sorted = (set) => [...set].sort();
const diff = (a, b) => sorted(a).filter((x) => !b.has(x));

// ---- the TypeScript side -------------------------------------------------------------------
const tsFiles = (await walk(join(editor, "src"), (p) => p.endsWith(".ts"))).filter(
  (p) => /\/src\/main\.ts$|\/src\/bridge\//.test(p),
);
const tsText = (await Promise.all(tsFiles.map((f) => readFile(f, "utf8")))).join("\n");

function block(text, startPattern, endPattern) {
  const start = text.search(startPattern);
  if (start < 0) throw new Error(`cannot find ${startPattern}`);
  const rest = text.slice(start);
  const end = rest.search(endPattern);
  return end < 0 ? rest : rest.slice(0, end);
}

const outbound = new Set(
  [...block(tsText, /type OutboundMessage\s*=/, /\n\n/).matchAll(/\{\s*type:\s*"(\w+)"/g)].map((m) => m[1]),
);
const host = new Set(
  [...block(tsText, /const host\s*=\s*\{/, /\n\};/).matchAll(/^ {2}(?:async )?([A-Za-z]\w*)\(/gm)].map((m) => m[1]),
);

// ---- the Swift side ------------------------------------------------------------------------
const swiftFiles = await walk(join(repo, "Sources"), (p) => p.endsWith(".swift") && !/Tests/.test(p));
const swiftTexts = await Promise.all(swiftFiles.map(async (f) => [f, await readFile(f, "utf8")]));

const decoder = swiftTexts.find(([, text]) => text.includes("init?(body: Any)"));
if (!decoder) throw new Error("cannot find the Swift message decoder (init?(body: Any))");
const decoded = new Set(
  [...block(decoder[1], /switch type\s*\{/, /\n\s*default:/).matchAll(/case "(\w+)":/g)].map((m) => m[1]),
);

const called = new Set();
for (const [, text] of swiftTexts) {
  for (const m of text.matchAll(/\bcall(?:JSON)?\(\s*"(\w+)"/g)) called.add(m[1]);
}

// ---- compare -------------------------------------------------------------------------------
const problems = [];
for (const name of diff(outbound, decoded)) problems.push(`the page sends "${name}", but Swift does not decode it`);
for (const name of diff(decoded, outbound)) problems.push(`Swift decodes "${name}", but the page never sends it`);
for (const name of diff(called, host)) problems.push(`Swift calls ${name}(), but the page's host object has no such method`);

const snapshot =
  "# The names that cross the bridge. Checked by bridge-names.mjs; regenerate with --update.\n" +
  `# web -> Swift (${outbound.size})\n` + sorted(outbound).map((n) => `outbound ${n}`).join("\n") + "\n" +
  `# Swift -> web (${host.size})\n` + sorted(host).map((n) => `host ${n}`).join("\n") + "\n";

if (process.argv.includes("--update")) {
  await writeFile(snapshotPath, snapshot);
  console.log(`wrote ${snapshotPath}`);
} else {
  const frozen = await readFile(snapshotPath, "utf8").catch(() => "");
  if (frozen !== snapshot) {
    const was = new Set(frozen.split("\n").filter((l) => /^(outbound|host) /.test(l)));
    const now = new Set(snapshot.split("\n").filter((l) => /^(outbound|host) /.test(l)));
    for (const line of diff(now, was)) problems.push(`new bridge name not in bridge-names.txt: ${line}`);
    for (const line of diff(was, now)) problems.push(`bridge name removed or renamed: ${line}`);
    if (!problems.length) problems.push("bridge-names.txt differs from the sources (formatting only) — run with --update");
  }
}

if (problems.length) {
  console.error(`✗ bridge names: ${problems.length} problem${problems.length === 1 ? "" : "s"}`);
  for (const p of problems) console.error(`  - ${p}`);
  console.error("  after a deliberate change, run: node tests/bridge-names.mjs --update");
  process.exit(1);
}
console.log(`✓ bridge names: ${outbound.size} messages web→Swift, ${host.size} host methods (${called.size} called from Swift)`);
