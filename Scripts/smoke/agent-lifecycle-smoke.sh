#!/usr/bin/env bash
#
# Lifecycle smoke test of the agent API: the AppKit paths `agent-smoke.sh` does not reach, run
# against a built Plume Dev.app and temporary vaults.
#
#   Scripts/smoke/agent-lifecycle-smoke.sh ["build/Plume Dev.app"]
#
# The unit suites drive NoteAccessHandler directly; these checks exist because the parts in
# between — applicationShouldTerminate, the settings watcher re-pointing the vault, the launch-time
# vault chooser, a process killed by the kernel — only exist in the running app. Each scenario:
#
#   A. Vault missing at launch: a helper that launches the app hears VAULT_UNAVAILABLE within the
#      ready timeout instead of hanging, while the existing chooser is on screen; nothing is created
#      at the missing path. The chooser itself is dismissed by killing the app — choosing a folder
#      in it is the one step left to a person (acceptance M4).
#   B. Quit (a normal terminate, as ⌘Q sends) while a stream of writes is running: every request the
#      app accepted ends `saved` or `rejected`, and a relaunch leaves nothing pending.
#   C. kill -9 while a stream of writes is running: after relaunch every accepted request is settled
#      (`saved`, `rejected` or `outcome_unknown`), none is `accepted`/`prepared`, and no append was
#      applied twice.
#   D. Vault re-pointed (settings.json edited, as Settings and a hand edit both do) while a stream of
#      writes is running: no note is written into the old folder after the switch, old note_refs
#      answer VAULT_CHANGED, and a create retried with an old request ID returns its original note
#      rather than creating a second one in the new vault.
#
# Same isolation as agent-smoke.sh: refuses to run while Plume Dev is running, backs up
# "~/Library/Application Support/Plume (Debug)" and restores it on exit, and uses only temporary
# vaults. Never touches the release profile. Development use only.
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

WORK="$(mktemp -d /tmp/plume-cli-lifecycle.XXXXXX)"
BACKUP="$WORK/support-backup"
HAD_SUPPORT=0
if [[ -d "$SUPPORT" ]]; then
	HAD_SUPPORT=1
	cp -Rp "$SUPPORT" "$BACKUP"
fi

cleanup() {
	pkill -9 -f "$APP/Contents/MacOS/Plume" 2>/dev/null || true
	for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Contents/MacOS/Plume" >/dev/null || break; sleep 0.3; done
	rm -rf "$SUPPORT"
	if [[ "$HAD_SUPPORT" -eq 1 ]]; then cp -Rp "$BACKUP" "$SUPPORT"; fi
	rm -rf "$WORK"
	echo "==> restored $SUPPORT"
}
trap cleanup EXIT

# A normal quit — NSApplication.terminate, the path ⌘Q takes — without the keyboard. Not osascript:
# Apple Events to another app need the Automation permission, which would prompt mid-run; asking
# NSRunningApplication to terminate needs none. SIGTERM is not the same thing: AppKit does not route
# it through applicationShouldTerminate.
cat > "$WORK/quit.swift" <<'SWIFT'
import AppKit
for app in NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]) { app.terminate() }
SWIFT
swiftc -O "$WORK/quit.swift" -o "$WORK/quit" 2>/dev/null

# Everything else is one Python driver: it needs to run writes concurrently with app lifecycle
# events and then read the journal back, which is awkward to express in shell.
python3 - "$APP" "$HELPER" "$SUPPORT" "$WORK" <<'PY'
import json, os, secrets, shutil, signal, subprocess, sys, threading, time, uuid

app, helper, support, work = sys.argv[1:]
binary = os.path.join(app, "Contents/MacOS/Plume")

def check(condition, message):
    if not condition:
        print("FAILED:", message)
        sys.exit(1)

def quit_app():
    subprocess.run([os.path.join(work, "quit"), "com.tiylabs.plume.dev"], check=True)

def pids():
    out = subprocess.run(["pgrep", "-f", binary], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]

def wait_gone(timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not pids(): return True
        time.sleep(0.2)
    return False

def configure(vault, ever_created=True):
    """Fresh Dev settings pointing at `vault`, with agent access on, as Settings would write them."""
    shutil.rmtree(support, ignore_errors=True)
    os.makedirs(os.path.join(support, "Agent"))
    os.chmod(os.path.join(support, "Agent"), 0o700)
    json.dump({"vaultPath": vault, "checkForUpdates": False, "launchAtLogin": False},
              open(os.path.join(support, "settings.json"), "w"), indent=2)
    json.dump({"vaultEverCreated": ever_created}, open(os.path.join(support, "state.json"), "w"), indent=2)
    json.dump({"permission": "read_write", "generation": str(uuid.uuid4())},
              open(os.path.join(support, "Agent/access.json"), "w"))
    token = "plm_" + secrets.token_urlsafe(32)
    fd = os.open(os.path.join(support, "Agent/token"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, (token + "\n").encode())
    os.close(fd)
    return token

def cli(token, *args, stdin=None):
    env = dict(os.environ, PLUME_CLI_TOKEN=token)
    run = subprocess.run([helper, *args, "--json"], input=stdin, capture_output=True, text=True, env=env, timeout=60)
    try:
        body = json.loads(run.stdout) if run.stdout.strip() else {}
    except json.JSONDecodeError:
        body = {"raw": run.stdout}
    return run.returncode, body

def ok(token, *args, stdin=None):
    code, body = cli(token, *args, stdin=stdin)
    check(code == 0, f"{args} exited {code}: {body}")
    return body

def journal():
    folder = os.path.join(support, "Agent/Operations")
    records = []
    if not os.path.isdir(folder): return records
    for name in os.listdir(folder):
        if name.endswith(".json"):
            try: records.append(json.load(open(os.path.join(folder, name))))
            except Exception as error: check(False, f"unreadable journal record {name}: {error}")
    return records

def launch(token):
    """Lets the helper launch the app in the background, the way an agent's first call does."""
    started = time.time()
    body = ok(token, "notes", "list")
    return body, time.time() - started

class AppendStream:
    """Appends one distinct line per request to one note, as fast as the app answers."""
    def __init__(self, token, ref):
        self.token, self.ref = token, ref
        self.sent, self.answers = [], {}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
    def run(self):
        n = 0
        while not self.stop.is_set():
            code, read = cli(self.token, "notes", "read", "--ref", self.ref)
            if code != 0:
                time.sleep(0.05); continue
            n += 1
            rid = str(uuid.uuid4())
            self.sent.append((rid, f"- line {n}"))
            code, body = cli(self.token, "notes", "modify", stdin=json.dumps({
                "note_ref": self.ref, "expected_version": read["version"],
                "changes": [{"kind": "append", "text": f"- line {n}\n"}], "request_id": rid}))
            self.answers[rid] = body.get("state") or body.get("error", {}).get("code")
            # Two writes per second keeps under the 30-per-minute limit for the whole run.
            time.sleep(0.5)
    def __enter__(self):
        self.thread.start(); return self
    def __exit__(self, *exc):
        self.stop.set(); self.thread.join(timeout=90)

def settled(records):
    return [r for r in records if r["state"] in ("accepted", "prepared")]

# ---- A. Vault missing at launch -------------------------------------------------------------------
print("==> A. vault missing at launch: VAULT_UNAVAILABLE, nothing recreated")
missing = os.path.join(work, "missing-vault")
token = configure(missing, ever_created=True)
started = time.time()
code, body = cli(token, "notes", "list")
elapsed = time.time() - started
check(code == 1 and body.get("error", {}).get("code") == "VAULT_UNAVAILABLE", f"expected VAULT_UNAVAILABLE: {body}")
check(not body["error"].get("retryable", False), "VAULT_UNAVAILABLE is not retryable")
check(pids(), "the app was launched and is showing the chooser")
check(not os.path.exists(missing), "the missing vault was not recreated in the background")
started2 = time.time()
code, body = cli(token, "notes", "list")
again = time.time() - started2
check(code == 1 and body["error"]["code"] == "VAULT_UNAVAILABLE", "a second call while the chooser is up answers the same")
print(f"    launch + answer {elapsed:.2f}s, while the chooser is up {again*1000:.0f} ms")
for pid in pids(): os.kill(pid, signal.SIGKILL)
check(wait_gone(), "Plume Dev did not exit")

# ---- B. Quit while writes are running ------------------------------------------------------------
print("==> B. quit while writes stream: every accepted write settles")
vault = os.path.join(work, "vault-b"); os.makedirs(vault)
token = configure(vault)
launch(token)
note = ok(token, "notes", "create", "--request-id", str(uuid.uuid4()), stdin="# Quit test\n\n")
with AppendStream(token, note["note_ref"]) as stream:
    time.sleep(2.5)
    # A normal terminate: the same NSApplication.terminate path ⌘Q takes, minus the keyboard.
    quit_app()
    check(wait_gone(), "Plume Dev did not quit")
    stream.stop.set()
records = journal()
check(not settled(records), f"left pending after quit: {[r['state'] for r in settled(records)]}")
launch(token)
check(not settled(journal()), "pending after relaunch")
text = open(os.path.join(vault, note["filename"])).read()
saved = [line for rid, line in stream.sent if any(r["request_id"] == rid and r["state"] == "saved" for r in journal())]
for line in saved: check(text.count(line + "\n") == 1, f"{line!r} saved but not exactly once in the note")
print(f"    {len(stream.sent)} writes sent, {len(saved)} saved, none left pending")
quit_app()
check(wait_gone(), "Plume Dev did not quit")

# ---- C. kill -9 while writes are running ---------------------------------------------------------
print("==> C. kill -9 while writes stream: relaunch settles everything, nothing applied twice")
vault = os.path.join(work, "vault-c"); os.makedirs(vault)
token = configure(vault)
launch(token)
note = ok(token, "notes", "create", "--request-id", str(uuid.uuid4()), stdin="# Crash test\n\n")
with AppendStream(token, note["note_ref"]) as stream:
    time.sleep(2.7)
    for pid in pids(): os.kill(pid, signal.SIGKILL)
    check(wait_gone(), "Plume Dev survived SIGKILL")
    stream.stop.set()
before = {r["request_id"]: r["state"] for r in journal()}
launch(token)
time.sleep(1)
after = journal()
check(not settled(after), f"still pending after relaunch: {[r['state'] for r in settled(after)]}")
text = open(os.path.join(vault, note["filename"])).read()
for rid, line in stream.sent:
    check(text.count(line + "\n") <= 1, f"{line!r} appended more than once")
    status = next((r["state"] for r in after if r["request_id"] == rid), None)
    if status == "saved": check(text.count(line + "\n") == 1, f"{line!r} is saved but missing from the note")
    # Retrying a request after the crash is answered from the journal, never re-applied.
    if status is not None:
        code, body = cli(token, "operations", "get", "--request-id", rid)
        check(code == 0 and body["state"] == status, f"get_operation for {rid}: {body}")
recovered = sum(1 for rid, s in before.items() if s in ("accepted", "prepared"))
print(f"    {len(stream.sent)} writes sent, {recovered} were mid-flight at the kill, all settled on relaunch")
quit_app()
check(wait_gone(), "Plume Dev did not quit")

# ---- D. Vault re-pointed while writes are running ------------------------------------------------
print("==> D. vault switch while writes stream: nothing lands in the old folder afterwards")
old = os.path.join(work, "vault-d-old"); new = os.path.join(work, "vault-d-new")
os.makedirs(old); os.makedirs(new)
token = configure(old)
launch(token)
create_id = str(uuid.uuid4())
note = ok(token, "notes", "create", "--request-id", create_id, stdin="# Switch test\n\n")
with AppendStream(token, note["note_ref"]) as stream:
    time.sleep(2.2)
    settings_path = os.path.join(support, "settings.json")
    settings = json.load(open(settings_path))
    settings["vaultPath"] = new
    json.dump(settings, open(settings_path + ".tmp", "w"), indent=2)
    os.replace(settings_path + ".tmp", settings_path)
    # The watcher picks the edit up asynchronously; wait until the app answers from the new vault.
    deadline = time.time() + 10
    while time.time() < deadline:
        code, body = cli(token, "notes", "read", "--ref", note["note_ref"])
        if code == 1 and body["error"]["code"] in ("VAULT_CHANGED", "INVALID_NOTE_REF"): break
        time.sleep(0.2)
    else:
        check(False, "the app never switched to the new vault")
    switched_at = time.time()
    snapshot = open(os.path.join(old, note["filename"])).read()
    time.sleep(2)
    stream.stop.set()
check(open(os.path.join(old, note["filename"])).read() == snapshot, "the old note changed after the switch")
check(not settled(journal()), "pending writes after the switch")
check(body["error"]["code"] == "VAULT_CHANGED", f"an old note_ref answers VAULT_CHANGED: {body}")
retry = ok(token, "notes", "create", "--request-id", create_id, stdin="# Switch test\n\n")
check(retry["operation_id"] == note["operation_id"], "an old create ID returns its original operation")
check(not [f for f in os.listdir(new) if f.endswith(".md") and "switch" in f.lower()], "no second note in the new vault")
# The journal stores dates as milliseconds since 1970.
late = [rid for rid, _ in stream.sent if stream.answers.get(rid) == "saved"
        and any(r["request_id"] == rid and r["vault_path"].rstrip("/").endswith("vault-d-old")
                and r["updated_at"] / 1000 > switched_at for r in journal())]
check(not late, f"writes saved into the old vault after the switch: {late}")
print(f"    {len(stream.sent)} writes sent; after the switch the old note is unchanged and the old create ID is not replayed")
quit_app()
check(wait_gone(), "Plume Dev did not quit")
PY

echo "==> agent lifecycle smoke passed"
