/**
 * ⌘K's Assign to Desktop — the one row that opens rather than runs.
 *
 * The Dock's three-way *Assign To* (None, This Desktop, All Desktops), unfolding in place under the
 * row. Asserted on what a reader sees (the row's label, which choices show, which is ticked and
 * which is selected) and on the one thing Swift hears, `setSpaceAssignment`, because those are the
 * two places this can be wrong: a row that shows the right tick and sends nothing, or one that sends
 * a choice nobody saw selected.
 */
export async function run(view, bar, doc) {
  const failures = [];
  let checked = 0;
  const check = (name, want, got, ok = want === got) => {
    checked += 1;
    if (!ok) failures.push({ case: `assign to desktop · ${name}`, want: String(want), got: String(got) });
  };

  const sent = [];
  const host = (window.webkit ??= {});
  const handlers = (host.messageHandlers ??= {});
  const real = handlers.plume;
  handlers.plume = { postMessage: (m) => { sent.push(m); real?.postMessage?.(m); } };

  const plume = doc.getElementById("plume");
  const search = doc.querySelector(".actions__search");
  const isOpen = () => plume.hasAttribute("data-actions");
  const press = (key) =>
    search.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  const typeInto = (text) => {
    search.value = text;
    search.dispatchEvent(new Event("input", { bubbles: true }));
  };
  const label = (row) => row?.querySelector(".actions__label")?.textContent ?? "";
  const spaceRow = () => doc.querySelector(".actions__row[aria-expanded]");
  const choices = () => [...doc.querySelectorAll(".actions__row--choice")];
  const choiceLabels = () => choices().map(label).join("|");
  const ticked = () => choices().filter((row) => row.getAttribute("aria-checked") === "true").map(label).join("|");
  const selected = () => label(doc.querySelector('.actions__row[aria-selected="true"]'));
  const open = () => {
    if (!isOpen()) window.plumeHost.openActions();
  };
  const close = () => {
    if (isOpen()) press("Escape");
  };
  const toSpaceRow = () => {
    const index = Number(spaceRow().dataset.index);
    for (let i = 0; i < index; i += 1) press("ArrowDown");
  };

  window.plumeHost.loadNote("2026-09-12-1200-note.md", "Groceries\n", 0, false);
  window.plumeHost.setSpaceAssignment("unassigned", 2, true);
  window.plumeHost.setDockSpaceAssignment("unassigned", null);
  open();

  check("the row says what is in force", "Assign To: None", label(spaceRow()));
  check("folded when the panel opens", "false", spaceRow()?.getAttribute("aria-expanded"));
  check("no choices until asked for", 0, choices().length);

  toSpaceRow();
  check("the row can be selected", label(spaceRow()), selected());
  sent.length = 0;
  press("ArrowRight");
  check("→ unfolds it", "true", spaceRow()?.getAttribute("aria-expanded"));
  check("three choices, in the Dock's order", "None|This Desktop (2)|All Desktops", choiceLabels());
  check("the one in force is ticked", "None", ticked());
  check("and selected", "None", selected());
  check(
    "unfolding asks Swift for the room",
    true,
    sent.some((m) => m.type === "actionsOpen" && m.open),
    sent.some((m) => m.type === "actionsOpen" && m.open)
  );

  press("ArrowLeft");
  check("← folds it", "false", spaceRow()?.getAttribute("aria-expanded"));
  check("and the selection goes back to the row", label(spaceRow()), selected());

  sent.length = 0;
  press("Enter");
  check("⏎ on the row unfolds it", "true", spaceRow()?.getAttribute("aria-expanded"));
  check(
    "rather than setting anything",
    0,
    sent.filter((m) => m.type === "setSpaceAssignment").length
  );
  check("and the panel stays open", true, isOpen());

  press("ArrowDown");
  press("ArrowDown");
  check("the choices are walked like rows", "All Desktops", selected());
  sent.length = 0;
  press("Enter");
  check("⏎ on a choice sends it", "everySpace", sent.find((m) => m.type === "setSpaceAssignment")?.mode);
  check("and closes the panel", false, isOpen());

  // What the row shows next is Swift's word, not the click's: Swift may refuse This Desktop.
  window.plumeHost.setSpaceAssignment("oneSpace", 3, true);
  open();
  check("one desktop is named by the desktop", "Assign To: Desktop 3", label(spaceRow()));
  check("and folded again", "false", spaceRow()?.getAttribute("aria-expanded"));

  typeInto("all desk");
  check("a search for a choice finds the row", true, Boolean(spaceRow()), Boolean(spaceRow()));
  check("with its choices showing", "None|This Desktop (3)|All Desktops", choiceLabels());
  check("the one in force still ticked", "This Desktop (3)", ticked());

  sent.length = 0;
  const allDesktops = choices().find((row) => label(row) === "All Desktops");
  allDesktops?.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  check("a click on a choice sends it", "everySpace", sent.find((m) => m.type === "setSpaceAssignment")?.mode);
  close();

  // Without SkyLight, Swift cannot tell desktops apart, and a This Desktop that does nothing would be
  // a dead row (decision 31).
  window.plumeHost.setSpaceAssignment("unassigned", null, false);
  open();
  toSpaceRow();
  press("ArrowRight");
  check("without desktops there are two choices", "None|All Desktops", choiceLabels());
  close();

  // ⌥⌘S: a three-way setting's key lands on its three choices, on the one in force.
  view.dispatch({ selection: { anchor: 0 } });
  doc.querySelector(".cm-content").dispatchEvent(
    new KeyboardEvent("keydown", {
      key: "s", code: "KeyS", metaKey: true, altKey: true, bubbles: true, cancelable: true,
    })
  );
  check("⌥⌘S opens ⌘K", true, isOpen());
  check("unfolded", "true", spaceRow()?.getAttribute("aria-expanded"));
  check("on the one in force", "None", selected());
  close();

  // A system assignment arriving while a choice is selected disables it immediately.
  window.plumeHost.setSpaceAssignment("unassigned", 2, true);
  open();
  typeInto("desk");
  press("ArrowDown");
  sent.length = 0;
  window.plumeHost.setDockSpaceAssignment("oneSpace", 4);
  check("primary label shows result without source", "Assign To: Desktop 4", label(spaceRow()));
  check("no secondary status", null, doc.querySelector(".actions__space-status"));
  check("live update keeps search", "desk", search.value);
  check("disabled selection returns to parent", label(spaceRow()), selected());
  check("three choices remain visible", 3, choices().length);
  check("all choices disabled", true, choices().every((row) => row.getAttribute("aria-disabled") === "true"));
  check("system desktop is ticked with its number and source", "This Desktop (4, assigned by macOS)", ticked());
  check("only the system choice carries the source", 1, choices().filter((row) => label(row).includes("assigned by macOS")).length);
  check("guidance gives recovery path", true, doc.querySelector(".actions__space-explanation")?.textContent.includes("Right-click Plume in the Dock to assign a desktop"));
  for (const row of choices()) row.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  check("disabled clicks keep menu open", true, isOpen());
  check("disabled clicks keep parent selected", label(spaceRow()), selected());
  press("ArrowDown");
  check("keyboard skips disabled choices", label(spaceRow()), selected());
  press("Enter");
  check("disabled choices send nothing", 0, sent.filter((m) => m.type === "setSpaceAssignment").length);

  window.plumeHost.setSpaceAssignment("everySpace", null, false);
  window.plumeHost.setDockSpaceAssignment("everySpace", null);
  check("All Desktops uses plain parent label", "Assign To: All Desktops", label(spaceRow()));
  check("three disabled choices without SkyLight", 3, choices().length);
  check("All Desktops system result is ticked", "All Desktops (assigned by macOS)", ticked());
  window.plumeHost.setDockSpaceAssignment("oneSpace", null);
  check("unresolved UUID stays assigned", "Assign To: Assigned desktop", label(spaceRow()));
  check("unresolved system desktop is still ticked", "This Desktop (assigned by macOS)", ticked());
  window.plumeHost.setDockSpaceAssignment("unknown", null);
  check("unknown does not claim None", true, doc.querySelector(".actions__space-explanation")?.textContent.includes("Unable to confirm"));
  window.plumeHost.setSpaceAssignment("unassigned", 2, true);
  window.plumeHost.setDockSpaceAssignment("unassigned", null);
  check("cancellation restores Plume label", "Assign To: None", label(spaceRow()));
  check("cancellation enables choices", true, choices().every((row) => row.getAttribute("aria-disabled") === "false"));
  check("cancellation restores tick", "None", ticked());
  check("cancellation removes guidance", null, doc.querySelector(".actions__space-explanation"));
  sent.length = 0;
  choices().find((row) => label(row) === "All Desktops").dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  check("choices work after cancellation", "everySpace", sent.find((m) => m.type === "setSpaceAssignment")?.mode);
  close();

  window.plumeHost.setDockSpaceAssignment("oneSpace", 4);
  open();
  check("folded row shows assignment without source", "Assign To: Desktop 4", label(spaceRow()));
  window.plumeHost.applySettings({ language: "zh-Hans" });
  close();
  open();
  check("translated parent label has no source", "桌面分配：桌面 4", label(spaceRow()));
  toSpaceRow();
  press("ArrowRight");
  check("translated system choice", "当前桌面（桌面 4，由系统分配）", ticked());
  check("translated guidance", "无法在当前菜单中操作，请在Dock中右键Plume操作分配桌面", doc.querySelector(".actions__space-explanation")?.textContent);
  const checkedLabel = choices().find((row) => row.getAttribute("aria-checked") === "true").querySelector(".actions__label");
  check("system choice fits", true, checkedLabel.scrollWidth <= checkedLabel.clientWidth);
  window.plumeHost.setDockSpaceAssignment("everySpace", null);
  check("translated all desktops choice", "全部桌面（由系统分配）", ticked());
  const mainLabel = spaceRow().querySelector(".actions__label");
  const guidance = doc.querySelector(".actions__space-explanation");
  check("label fits", true, mainLabel.scrollWidth <= mainLabel.clientWidth);
  check("guidance fits", true, guidance.scrollWidth <= guidance.clientWidth);
  close();
  window.plumeHost.setDockSpaceAssignment("unassigned", null);
  window.plumeHost.applySettings({ language: "en" });

  handlers.plume = real;
  return { checked, failures };
}
