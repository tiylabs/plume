/*
 * Builds the editor into ONE self-contained HTML file at dist/index.html.
 *
 * Single file on purpose. The bundle is loaded inside a WKWebView with no network access, so anything
 * that resolves at runtime — a CDN script, an external stylesheet, a web font, a source map fetch —
 * would not merely be slow, it would not load at all. Inlining makes that failure impossible rather
 * than merely unlikely, and it means the Swift side has exactly one file to serve.
 */

import { build, context } from "esbuild";
import { readFile, writeFile, mkdir, readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const watch = process.argv.includes("--watch");

/** Safari 17 is the engine in the WKWebView on macOS 14, which is the deployment target. */
const TARGET = "safari17";


/**
 * `virtual:locales` — every language's `editor.*` strings, read from `../Locales` at build time.
 *
 * The catalogs are the same JSON files the Swift side reads (`Sources/PlumeKit/Support/Localization.swift`),
 * which is what stops the two halves of the interface drifting. Only `editor.*` keys are bundled:
 * the rest are Swift's, and shipping them here would be dead weight in a single-file page.
 *
 * **The language list is discovered, not written down** — adding `Locales/ja/strings.json` makes
 * `ja` appear here on the next build with no edit to this file.
 */
const localesPlugin = {
  name: "locales",
  setup(b) {
    b.onResolve({ filter: /^virtual:locales$/ }, () => ({ path: "locales", namespace: "locales" }));
    b.onLoad({ filter: /.*/, namespace: "locales" }, async () => {
      const dir = resolve(root, "../Locales");
      const catalogs = {};
      for (const entry of await readdir(dir, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        let table;
        try {
          table = JSON.parse(await readFile(resolve(dir, entry.name, "strings.json"), "utf8"));
        } catch {
          continue; // a language mid-translation must not break the build; LocalizationTests flags it
        }
        catalogs[entry.name] = Object.fromEntries(
          Object.entries(table).filter(([key]) => key.startsWith("editor."))
        );
      }
      return {
        contents: `export default ${JSON.stringify(catalogs)};`,
        loader: "js",
        watchDirs: [dir],
        watchFiles: Object.keys(catalogs).map((c) => resolve(dir, c, "strings.json")),
      };
    });
  },
};

const options = {
  entryPoints: [resolve(root, "src/main.ts")],
  bundle: true,
  // Nothing is written here — `write: false` keeps the outputs in memory so they can be inlined into
  // the HTML below. esbuild still needs somewhere to *name* them, and refuses to emit the CSS bundle
  // without it.
  outdir: resolve(root, "dist"),
  format: "iife",
  target: TARGET,
  platform: "browser",
  write: false,
  minify: !watch,
  // No source maps: they would be a second file the web view cannot fetch, and inlining them would
  // double the bundle for no benefit in a shipped panel.
  sourcemap: false,
  legalComments: "none",
  logLevel: "info",
  plugins: [localesPlugin],
};

async function emit(result) {
  const js = result.outputFiles.find((f) => f.path.endsWith(".js"))?.text ?? "";
  const css = result.outputFiles.find((f) => f.path.endsWith(".css"))?.text ?? "";

  const template = await readFile(resolve(root, "src/index.html"), "utf8");
  const html = template
    .replace("__STYLES__", () => css)
    .replace("__SCRIPT__", () => js);

  await mkdir(resolve(root, "dist"), { recursive: true });
  await writeFile(resolve(root, "dist/index.html"), html, "utf8");

  const kb = (n) => `${(n / 1024).toFixed(1)} kB`;
  console.log(
    `dist/index.html  ${kb(Buffer.byteLength(html))}  (js ${kb(Buffer.byteLength(js))}, css ${kb(Buffer.byteLength(css))})`
  );
}

if (watch) {
  const ctx = await context({
    ...options,
    plugins: [
      localesPlugin,
      {
        name: "emit-html",
        setup(b) {
          b.onEnd(async (result) => {
            if (result.errors.length === 0) await emit(result);
          });
        },
      },
    ],
  });
  await ctx.watch();
  console.log("watching…");
} else {
  await emit(await build(options));
}
