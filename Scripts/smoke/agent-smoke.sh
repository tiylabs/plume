#!/usr/bin/env bash
#
# End-to-end smoke test of the agent API against a built Plume Dev.app and a temporary vault.
#
#   Scripts/smoke/agent-smoke.sh ["build/Plume Dev.app"]
#
# What it does, in order:
#   1. Refuses to run if Plume Dev is already running (it must own the Dev socket itself).
#   2. Backs up "~/Library/Application Support/Plume (Debug)" and restores it on exit, whatever
#      happens — the Dev profile's real settings, state and vault path come back untouched.
#   3. Points the Dev profile at a fresh temporary vault and turns agent access on (read_write),
#      exactly as Settings would: Agent/access.json and a 0600 Agent/token.
#   4. Checks that a call without a credential fails with AUTH_FAILED and does NOT launch the app.
#   5. Drives `plume-cli mcp` over stdio (initialize → tools/list → create → search → read →
#      modify → get_operation), letting the helper launch the app in the background.
#   6. Runs the same flow through the CLI and checks both produce the same result shapes.
#   7. Quits Plume Dev and restores the backup.
#
# Never touches the release profile, its settings or ~/Documents/Plume. Development use only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${1:-$ROOT/build/Plume Dev.app}"
HELPER="$APP/Contents/MacOS/plume-cli"
SUPPORT="$HOME/Library/Application Support/Plume (Debug)"

[[ -x "$HELPER" ]] || { echo "error: no helper at $HELPER — run make dev first" >&2; exit 2; }
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | grep -qx 'com.tiylabs.plume.dev' \
	|| { echo "error: $APP is not a Dev build" >&2; exit 2; }
if pgrep -f '/Plume Dev.app/Contents/MacOS/Plume' >/dev/null; then
	echo "error: Plume Dev is running; quit it first" >&2
	exit 2
fi

WORK="$(mktemp -d /tmp/plume-cli-smoke.XXXXXX)"
VAULT="$WORK/vault"
BACKUP="$WORK/support-backup"
mkdir -p "$VAULT"
HAD_SUPPORT=0
if [[ -d "$SUPPORT" ]]; then
	HAD_SUPPORT=1
	cp -Rp "$SUPPORT" "$BACKUP"
fi

cleanup() {
	pkill -f "$APP/Contents/MacOS/Plume" 2>/dev/null || true
	for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Contents/MacOS/Plume" >/dev/null || break; sleep 0.3; done
	rm -rf "$SUPPORT"
	if [[ "$HAD_SUPPORT" -eq 1 ]]; then cp -Rp "$BACKUP" "$SUPPORT"; fi
	rm -rf "$WORK"
	echo "==> restored $SUPPORT"
}
trap cleanup EXIT

# Use fresh settings: existing Dev sync remotes and note pointers must not enter the test vault.
rm -rf "$SUPPORT"
# The Dev profile, pointed at the temporary vault, with agent access on.
mkdir -p "$SUPPORT/Agent"
chmod 700 "$SUPPORT/Agent"
python3 - "$SUPPORT" "$VAULT" <<'PY'
import json, os, secrets, sys, uuid
support, vault = sys.argv[1:]
path = os.path.join(support, "settings.json")
settings = {"vaultPath": vault, "checkForUpdates": False, "launchAtLogin": False}
json.dump(settings, open(path, "w"), indent=2)
state_path = os.path.join(support, "state.json")
state = {}
state["vaultEverCreated"] = True
state.pop("lastUsedFilename", None)
json.dump(state, open(state_path, "w"), indent=2)
json.dump({"permission": "read_write", "generation": str(uuid.uuid4())}, open(os.path.join(support, "Agent/access.json"), "w"))
token = "plm_" + secrets.token_urlsafe(32)
fd = os.open(os.path.join(support, "Agent/token"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, (token + "\n").encode())
os.close(fd)
PY
TOKEN="$(tr -d '\n' < "$SUPPORT/Agent/token")"

echo "==> no credential: AUTH_FAILED, and the app is not launched"
set +e
OUT="$(env -u PLUME_CLI_TOKEN "$HELPER" notes list --json)"
STATUS=$?
set -e
[[ $STATUS -eq 1 ]] || { echo "expected exit 1, got $STATUS"; exit 1; }
echo "$OUT" | grep -q '"code":"AUTH_FAILED"' || { echo "expected AUTH_FAILED: $OUT"; exit 1; }
sleep 1
if pgrep -f "$APP/Contents/MacOS/Plume" >/dev/null; then echo "the app was launched without a credential"; exit 1; fi
echo "    ok"

echo "==> MCP over stdio, then the CLI"
PLUME_CLI_TOKEN="$TOKEN" python3 - "$HELPER" "$VAULT" <<'PY'
import json, os, subprocess, sys, time, uuid
helper, vault = sys.argv[1:]

def check(condition, message):
    if not condition:
        print("FAILED:", message)
        sys.exit(1)

# ---- MCP -------------------------------------------------------------------------------------
proc = subprocess.Popen([helper, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
next_id = 0
def rpc(method, params=None, notify=False):
    global next_id
    message = {"jsonrpc": "2.0", "method": method}
    if params is not None: message["params"] = params
    if not notify:
        next_id += 1
        message["id"] = next_id
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()
    if notify: return None
    while True:
        line = proc.stdout.readline()
        check(line, "the MCP server closed stdout")
        reply = json.loads(line)          # every stdout line must be JSON-RPC
        check(reply.get("jsonrpc") == "2.0", "non-protocol line on stdout: " + line)
        if reply.get("id") == message["id"]: return reply

def call(name, arguments):
    started = time.time()
    reply = rpc("tools/call", {"name": name, "arguments": arguments})
    elapsed = time.time() - started
    result = reply["result"]
    check(not result["isError"], f"{name} failed: {result['content'][0]['text']}")
    return result["structuredContent"], elapsed

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
check(init["result"]["capabilities"]["tools"]["listChanged"] is True, "tools capability")
rpc("notifications/initialized", notify=True)
started = time.time()
tools = rpc("tools/list")["result"]["tools"]
launch = time.time() - started
names = [t["name"] for t in tools]
check(names == ["get_writing_context", "list_notes", "search_notes", "read_note", "create_note", "modify_note", "get_operation"], f"tools: {names}")
print(f"    tools/list (includes launching Plume Dev): {launch:.2f}s, {len(names)} tools")

context, _ = call("get_writing_context", {})
check("first non-blank line" in context["format"]["guide"], "format guide")
created_id = str(uuid.uuid4())
created, t_create = call("create_note", {"markdown": "# Smoke test note\n\n## 方案\n\n采用 HTTP 服务。\n", "request_id": created_id})
check(created["state"] == "saved" and created["saved_locally"], "create saved")
on_disk = open(os.path.join(vault, created["filename"])).read()
check(on_disk == "# Smoke test note\n\n## 方案\n\n采用 HTTP 服务。\n", "created file on disk")
again, _ = call("create_note", {"markdown": "# Smoke test note\n\n## 方案\n\n采用 HTTP 服务。\n", "request_id": created_id})
check(again["operation_id"] == created["operation_id"], "idempotent create")
check(len([f for f in os.listdir(vault) if f.endswith(".md")]) == 1, "no second note")
found, t_search = call("search_notes", {"query": "HTTP"})
check(found["results"][0]["note"]["note_ref"] == created["note_ref"], "search finds it")
read, t_read = call("read_note", {"note_ref": created["note_ref"]})
check(read["markdown"] == on_disk and read["source"] == "disk", "read")
modify_id = str(uuid.uuid4())
modified, t_modify = call("modify_note", {"note_ref": created["note_ref"], "expected_version": read["version"],
    "changes": [{"kind": "replace", "old_text": "采用 HTTP 服务。", "new_text": "采用本地 stdio MCP。"},
                {"kind": "append", "text": "\n- [ ] 完成\n"}], "request_id": modify_id})
check(modified["changed"], "modify changed")
check(open(os.path.join(vault, created["filename"])).read() == "# Smoke test note\n\n## 方案\n\n采用本地 stdio MCP。\n\n- [ ] 完成\n", "modified on disk")
conflict = rpc("tools/call", {"name": "modify_note", "arguments": {"note_ref": created["note_ref"], "expected_version": read["version"],
    "changes": [{"kind": "append", "text": "x\n"}], "request_id": str(uuid.uuid4())}})["result"]
check(conflict["isError"] and conflict["structuredContent"]["error"]["code"] == "VERSION_CONFLICT", "stale version conflicts")
status, _ = call("get_operation", {"request_id": modify_id})
check(status["state"] == "saved" and status["kind"] == "modify", "get_operation")
proc.stdin.close()
proc.wait(timeout=10)
stderr = proc.stderr.read()
print(f"    MCP flow ok — create {t_create*1000:.0f} ms, search {t_search*1000:.0f} ms, read {t_read*1000:.0f} ms, modify {t_modify*1000:.0f} ms")

# ---- CLI --------------------------------------------------------------------------------------
def cli(*args, stdin=None):
    run = subprocess.run([helper, *args, "--json"], input=stdin, capture_output=True, text=True)
    check(run.returncode == 0, f"CLI {args} exited {run.returncode}: {run.stdout} {run.stderr}")
    return json.loads(run.stdout)

cli_id = str(uuid.uuid4())
c_created = cli("notes", "create", "--request-id", cli_id, stdin="# CLI note\n\nalpha beta\n")
check(set(c_created) == set(created), f"CLI create has the MCP result's fields: {sorted(set(c_created) ^ set(created))}")
c_found = cli("notes", "search", "--query", "alpha")
check(set(c_found) == set(found) and c_found["results"][0]["note"]["filename"] == c_created["filename"], "CLI search")
c_read = cli("notes", "read", "--ref", c_created["note_ref"])
check(set(c_read) == set(read) and c_read["markdown"] == "# CLI note\n\nalpha beta\n", "CLI read")
c_modify = cli("notes", "modify", stdin=json.dumps({"note_ref": c_created["note_ref"], "expected_version": c_read["version"],
    "changes": [{"kind": "replace", "old_text": "alpha", "new_text": "gamma"}], "request_id": str(uuid.uuid4())}))
check(set(c_modify) == set(modified) and c_modify["changed"], "CLI modify")
c_status = cli("operations", "get", "--request-id", cli_id)
check(set(c_status) == set(status) and c_status["state"] == "saved", "CLI operations get")
c_list = cli("notes", "list")
check(c_list["total"] == 2, "two notes in the vault")
bad = subprocess.run([helper, "notes", "search"], capture_output=True, text=True)
check(bad.returncode == 2 and bad.stdout == "", "usage error exits 2 with nothing on stdout")
print("    CLI flow ok — same result fields as MCP")
PY

echo "==> agent smoke passed"
