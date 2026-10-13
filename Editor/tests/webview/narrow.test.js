/**
 * The ⌘K panel at a panel width nobody designed the labels for.
 *
 * Run at **380**, which is inside the band this rule exists for: below 420 the shortcut chips wrap
 * under their labels, and 380 is far enough in that a stray pixel of rounding cannot decide the result. The suite that
 * measures the overlays at rest runs at 460 and cannot see any of this — the probe's window is one
 * width, and until this file it was hardwired to 460.
 *
 * Assert both parts of the narrow layout: every action label fits, and every bound shortcut chip is
 * visible below its label. Geometry catches a rule that exists in CSS but loses in the rendered row.
 */
export async function run(view, bar, doc) {
  const failures = [];
  let checked = 0;
  const check = (name, want, got, ok = want === got) => {
    checked += 1;
    if (!ok) failures.push({ case: `narrow · ${name}`, want: String(want), got: String(got) });
  };
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  window.plumeHost.loadNote("2026-09-12-1200-note.md", "Groceries\n", 0, false);
  window.plumeHost.openActions();
  // Past the chips' 150ms transition, which starts from the stylesheet's own initial value.
  await sleep(400);

  const rows = [...doc.querySelectorAll(".actions__row")];
  check("the panel has its rows", true, rows.length >= 14, rows.length >= 14);

  // The one that matters. A label whose `scrollWidth` exceeds its box is a label wearing an
  // ellipsis, and at this width every one of them used to.
  const clipped = rows
    .map((row) => row.querySelector(".actions__label"))
    .filter((label) => label.scrollWidth > label.clientWidth)
    .map((label) => label.textContent);
  check(
    "no row's label is truncated",
    "none",
    clipped.length ? clipped.join(", ") : "none",
    clipped.length === 0
  );

  // And the keys remain visible below their labels instead of disappearing to make room.
  // Only the rows that *have* a shortcut. Recently Deleted and Rename File… are deliberately
  // unbound (decisions 35, 103), and their empty chip group has no height either — which cost one
  // assertion a false red before the reason was read.
  const keys = rows
    .map((row) => row.querySelector(".actions__keys"))
    .filter((el) => el && el.querySelector("kbd"));
  check("the rows that have a shortcut still carry it", true, keys.length >= 13, keys.length >= 13);
  const keyRows = keys.filter((el) => el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0);
  check("all bound shortcuts are visible", keys.length, keyRows.length);
  check("keys have their own line", true, keys.every((el) => {
    const row = el.closest(".actions__row");
    const label = row?.querySelector(".actions__label");
    return row && label && row.getBoundingClientRect().height > label.getBoundingClientRect().height;
  }));

  // Assign to Desktop names the setting in force, so its width depends on the setting: the longest
  // of its labels has to fit too, not just the None the panel opens with — and so do its choices,
  // indented under it. A search shows them without walking to the row.
  const search = doc.querySelector(".actions__search");
  for (const [mode, desktop] of [["oneSpace", 12], ["everySpace", null]]) {
    window.plumeHost.openActions(); // a toggle: this closes it, so the labels are drawn afresh
    window.plumeHost.setSpaceAssignment(mode, desktop, true);
    window.plumeHost.openActions();
    search.value = "desk";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    const cut = [...doc.querySelectorAll(".actions__row .actions__label")]
      .filter((label) => label.scrollWidth > label.clientWidth)
      .map((label) => label.textContent);
    const shown = doc.querySelectorAll(".actions__row--choice").length;
    check(`Assign to Desktop's choices show for a search (${mode})`, 3, shown);
    check(`Assign to Desktop fits (${mode})`, "none", cut.length ? cut.join(", ") : "none", cut.length === 0);
  }

  return { checked, failures };
}
