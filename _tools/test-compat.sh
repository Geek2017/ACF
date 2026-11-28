#!/usr/bin/env bash
# test-compat.sh: tests for cross-platform hardening and tmux 3.8 compatibility:
#   - share/llm-usage/nobrowser/* shims (Linux/KDE6/macOS/WSL) and bin/llm-usage agy_read blocking
#   - bin/afc-gemini-effort (set/show/ensure/fit, Linux /proc, and mocked macOS macproc fallback)
#   - tmux 3.8 single-quoted '%%' in rename-window (tmux/tmux.conf and bin/afc-menu) on a live server
#   - lib/afc/pb.py protobuf wire decoding (normal + truncated boundary input)
#
#   bash _tools/test-compat.sh            run all checks
#   bash _tools/test-compat.sh --keep     leave temp dir for inspection
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0
while (( $# )); do
  case "$1" in
    --keep) KEEP=1 ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done

T=$(mktemp -d /tmp/acf-test-compat.XXXXXX)
SOCK="acf-test-compat-$$"
TB="$HOME/.local/bin/tmux"; [[ -x "$TB" ]] || TB=$(command -v tmux) || { echo "tmux is needed" >&2; exit 2; }
cleanup() {
  "$TB" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  (( KEEP )) && echo "kept: $T" || rm -rf "$T"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "  ok:   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1${2:+ ($2)}"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

echo "1. Browser-blocking shims (share/llm-usage/nobrowser/) & bin/llm-usage"
SHIM_DIR="$HERE/share/llm-usage/nobrowser"
EXPECTED_SHIMS=(gio gnome-open kde-open kde-open5 kde-open6 kioclient kioclient5 open sensible-browser www-browser x-www-browser xdg-open wslview explorer.exe)
missing_shims=()
mkdir -p "$T/rt/llm-usage"
for s in "${EXPECTED_SHIMS[@]}"; do
  if [[ ! -x "$SHIM_DIR/$s" ]]; then
    missing_shims+=("$s")
  else
    XDG_RUNTIME_DIR="$T/rt" "$SHIM_DIR/$s" "https://accounts.google.com/o/oauth2/auth?x=12345678901234567890" || missing_shims+=("$s:rc")
  fi
done
check "all 14 cross-platform nobrowser shims exist, are executable, and exit 0" \
  '[[ ${#missing_shims[@]} -eq 0 ]]' "${missing_shims[*]:-}"

log_lines=$(wc -l < "$T/rt/llm-usage/nobrowser.log" 2>/dev/null || echo 0)
max_len=$(awk '{ if (length > m) m = length } END { print m+0 }' "$T/rt/llm-usage/nobrowser.log" 2>/dev/null || echo 999)
check "nobrowser shims log every blocked call and truncate lines <=60 chars" \
  '[[ "$log_lines" -eq 14 && "$max_len" -le 60 ]]' "lines=$log_lines max_len=$max_len"

# Verify bin/llm-usage agy_read sets PATH (nobrowser first) and BROWSER shim
agy_check=$(python3 - "$HERE" "$T" <<'PY'
import importlib.machinery, importlib.util, os, stat, sys
here, tmp = sys.argv[1], sys.argv[2]
fake_home = os.path.join(tmp, "llm-home")
fake_bin = os.path.join(tmp, "fake-bin")
fake_rt = os.path.join(tmp, "agy-rt")
os.makedirs(os.path.join(fake_home, ".config", "agents"), exist_ok=True)
os.makedirs(fake_bin, exist_ok=True)
os.makedirs(os.path.join(fake_rt, "llm-usage"), exist_ok=True)
# Fake agy that invokes $BROWSER, open, kde-open6, wslview and exits with no quota JSON
fake_agy = os.path.join(fake_bin, "agy")
with open(fake_agy, "w") as f:
    f.write("""#!/bin/sh
echo "BROWSER=$BROWSER" > "$TMP_PROBE"
echo "PATH0=$(printf '%s' "$PATH" | cut -d: -f1)" >> "$TMP_PROBE"
"$BROWSER" "https://example.test/from-browser-var"
open "https://example.test/from-open"
kde-open6 "https://example.test/from-kde6"
wslview "https://example.test/from-wsl"
exit 0
""")
os.chmod(fake_agy, 0o755)
probe = os.path.join(tmp, "agy-probe.txt")
os.environ["HOME"] = fake_home
os.environ["XDG_RUNTIME_DIR"] = fake_rt
os.environ["TMP_PROBE"] = probe
os.environ["PATH"] = fake_bin + ":" + os.environ.get("PATH", "")

loader = importlib.machinery.SourceFileLoader("llm_usage_mod", os.path.join(here, "bin", "llm-usage"))
spec = importlib.util.spec_from_loader("llm_usage_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.TMUX_ENV = dict(os.environ)
err = mod.agy_read("testacct")
probe_txt = open(probe).read()
log_txt = open(os.path.join(fake_rt, "llm-usage", "nobrowser.log")).read()
assert err and err.startswith("no data:"), f"unexpected err: {err}"
assert "nobrowser/xdg-open" in probe_txt, f"BROWSER not set to shim: {probe_txt}"
assert "nobrowser" in probe_txt.splitlines()[1], f"PATH does not start with nobrowser: {probe_txt}"
for tok in ("xdg-open", "open", "kde-open6", "wslview"):
    assert tok in log_txt, f"missing {tok} in nobrowser.log: {log_txt}"
print("OK")
PY
)
rc=$?
check "bin/llm-usage agy_read prepends nobrowser to PATH and sets BROWSER shim" '[[ $rc -eq 0 && "$agy_check" == "OK" ]]' "$agy_check"

echo "2. bin/afc-gemini-effort (settings + Linux /proc + mocked macOS macproc)"
gem_check=$(python3 - "$HERE" "$T" <<'PY'
import datetime, importlib.machinery, importlib.util, json, os, sys, time, types
here, tmp = sys.argv[1], sys.argv[2]
ghome = os.path.join(tmp, "gem-home")
os.makedirs(os.path.join(ghome, ".gemini"), exist_ok=True)
own_file = os.path.join(tmp, "gemini-effort-own")
os.environ["AFC_GEMINI_EFFORT_FILE"] = own_file

# Seed a user custom override that must be preserved
with open(os.path.join(ghome, ".gemini", "settings.json"), "w") as f:
    json.dump({"modelConfigs": {"customOverrides": [{"match": {"model": "custom-x"}, "keep": True}]}}, f)

loader = importlib.machinery.SourceFileLoader("afc_gem", os.path.join(here, "bin", "afc-gemini-effort"))
spec = importlib.util.spec_from_loader("afc_gem", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

# 2a. set / fit / ensure / default
assert mod.main(["--home", ghome, "set", "xhigh"]) == 0
s = mod.load(ghome)
overrides = s["modelConfigs"]["customOverrides"]
assert any(o.get("keep") is True for o in overrides), "user override dropped"
neon = [o for o in overrides if o.get("match", {}).get("model") == "gemini-4-neon"][0]
argon = [o for o in overrides if o.get("match", {}).get("model") == "gemini-4-argon"][0]
assert neon["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"] == "XHIGH"
assert argon["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"] == "HIGH"

# Drop fleet overrides and verify `ensure` restores them
with open(os.path.join(ghome, ".gemini", "settings.json"), "w") as f:
    json.dump({"modelConfigs": {"customOverrides": [{"match": {"model": "custom-x"}, "keep": True}]}}, f)
assert mod.current(mod.load(ghome)) == "default"
assert mod.main(["--home", ghome, "ensure"]) == 0
assert mod.current(mod.load(ghome)) == "xhigh"

assert mod.main(["--home", ghome, "set", "default"]) == 0
assert mod.current(mod.load(ghome)) == "default"
assert len(mod.load(ghome)["modelConfigs"]["customOverrides"]) == 1

# 2b. Linux /proc helpers on current process
pid = os.getpid()
assert mod.proc_cwd(pid) == os.path.realpath(os.getcwd())
assert mod.proc_start(pid) > 1_700_000_000
assert len(mod.proc_args(pid)) >= 1

# 2c. Mocked macOS macproc path (must never touch /proc)
proj = os.path.join(tmp, "mac-proj")
cdir = os.path.join(ghome, ".gemini", "tmp", "h1", "chats")
os.makedirs(proj, exist_ok=True)
os.makedirs(cdir, exist_ok=True)
with open(os.path.join(ghome, ".gemini", "tmp", "h1", ".project_root"), "w") as f:
    f.write(proj + "\n")
now = time.time()
uid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
cfile = os.path.join(cdir, "session-2026-11-25T10-00-aaaaaaaa.jsonl")
ts_iso = datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
with open(cfile, "w") as f:
    f.write(json.dumps({"sessionId": uid, "startTime": ts_iso}) + "\n")
    f.write(json.dumps({"type": "gemini", "model": "gemini-4-neon", "timestamp": ts_iso}) + "\n")

fake_mp = types.ModuleType("macproc")
fake_mp.info = lambda p: (1, "gemini", int(now) - 1) if p == 4242 else None
fake_mp.argv_env = lambda p: (["gemini", "--resume", uid], {}) if p == 4242 else ([], {})
fake_mp.cwd = lambda p: proj if p == 4242 else ""

orig_mac, orig_mp = mod.MAC, mod._MACPROC
try:
    mod.MAC = True
    mod._MACPROC = fake_mp
    got_id, got_path = mod.chat_of(ghome, 4242)
    assert got_id == uid and got_path == cfile, (got_id, got_path)
    got_id2, got_path2 = mod.chat_of(ghome, 4242, said=uid)
    assert got_id2 == uid and got_path2 == cfile, (got_id2, got_path2)
    # Boundary: vanished PID raises OSError cleanly (and main returns 1)
    assert mod.main(["--home", ghome, "chat", "99999"]) == 1
finally:
    mod.MAC, mod._MACPROC = orig_mac, orig_mp
print("OK")
PY
)
rc=$?
check "afc-gemini-effort set/ensure/default, Linux /proc, and macOS macproc fallback pass" \
  '[[ $rc -eq 0 && "$gem_check" == *"OK"* ]]' "$gem_check"

echo "3. tmux 3.8 rename-window single-quoted '%%' (tmux.conf + afc-menu)"
# Verify tmux.conf loads cleanly on isolated tmux 3.8 server and bindings use string-template -- '%%'
conf_err=$(env -u TMUX "$TB" -L "$SOCK" -f "$HERE/tmux/tmux.conf" new-session -d -s s1 -n init '/bin/sleep 60' 2>&1)
check "tmux/tmux.conf loads cleanly on tmux 3.8 without errors" '[[ -z "$conf_err" ]]' "$conf_err"

keys_out=$(env -u TMUX "$TB" -L "$SOCK" list-keys 2>&1)
check "MouseDown3Status and prefix < use string-template rename-window -- '%%'" \
  '[[ "$keys_out" == *"rename-window -t '\''#{window_id}'\'' -- '\''%%'\''"* && "$keys_out" != *"rename-window -t \"#{window_id}\" \"%%\""* ]]' \
  "$(printf '%s\n' "$keys_out" | grep 'rename-window')"

# Verify bin/afc-menu tab_ctx_cmd emits string-template -- '%%'
menu_check=$(python3 - "$HERE" <<'PY'
import importlib.machinery, importlib.util, os, sys
here = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("afc_menu_mod", os.path.join(here, "bin", "afc-menu"))
spec = importlib.util.spec_from_loader("afc_menu_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
ctx = {"sock": "/tmp/s", "client": "/dev/pts/1", "win": "@1", "pane": "%1", "pid": "1", "cwd": "/tmp", "session": "agents"}
secs = mod.build_command_sections(ctx)
cmds = [it["cmd"] for _, items in secs for it in items if it.get("cmd")]
tab_menu = [c for c in cmds if "display-menu" in c and "Swap Left" in c]
assert tab_menu, "tab context menu command not found"
assert "rename-window -t" in tab_menu[0] and "--" in tab_menu[0] and "%%" in tab_menu[0], tab_menu[0]
assert 'rename-window -t "#{window_id}" "%%"' not in tab_menu[0], tab_menu[0]
print("OK")
PY
)
rc=$?
check "bin/afc-menu tab_ctx_cmd emits string-template rename-window -- '%%'" '[[ $rc -eq 0 && "$menu_check" == "OK" ]]' "$menu_check"

# Live tmux 3.8 test of command-prompt template replacement with apostrophe, quotes, $HOME, and -flag
live_rename=$(python3 - "$TB" "$SOCK" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
tb, sock = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items() if k != "TMUX"}
env["TERM"] = "xterm-256color"
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
proc = subprocess.Popen([tb, "-L", sock, "attach-session", "-t", "s1"], env=env,
                        stdin=slave, stdout=slave, stderr=slave, start_new_session=True, close_fds=True)
os.close(slave)
time.sleep(0.3)
cl = subprocess.run([tb, "-L", sock, "list-clients", "-F", "#{client_name}"], env=env,
                    capture_output=True, text=True, check=True).stdout.strip().splitlines()[0]

def drain():
    while select.select([master], [], [], 0.05)[0]:
        try: os.read(master, 4096)
        except OSError: break

def rename_via_prompt(text):
    drain()
    subprocess.run([tb, "-L", sock, "command-prompt", "-b", "-t", cl, "-F", "-I", "",
                    "rename-window -t '#{window_id}' -- '%%'"], env=env, check=True)
    time.sleep(0.15)
    os.write(master, (text + "\r").encode())
    time.sleep(0.25)
    drain()
    return subprocess.run([tb, "-L", sock, "display-message", "-p", "-t", "s1", "#{window_name}"],
                          env=env, capture_output=True, text=True, check=True).stdout.strip()

try:
    for name in ("bob's tab", "-v", '$HOME', 'a"b'):
        got = rename_via_prompt(name)
        assert got == name, f"expected {name!r}, got {got!r}"
finally:
    os.close(master)
    proc.terminate()
    proc.wait(timeout=5)
print("OK")
PY
)
rc=$?
check "live tmux 3.8 rename-window -- '%%' preserves apostrophes, flags, \$HOME, and quotes" \
  '[[ $rc -eq 0 && "$live_rename" == "OK" ]]' "$live_rename"

echo "4. lib/afc/pb.py protobuf decoder (normal + truncated boundary)"
pb_check=$(python3 - "$HERE" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib", "afc"))
import pb
# Field 1 = varint 150, Field 2 = string "hello"
raw = b"\x08\x96\x01\x12\x05hello"
assert pb.pb_get(raw, 1) == 150
assert pb.pb_text(pb.pb_get(raw, 2)) == "hello"
# Truncated length-delimited field must not crash
trunc = list(pb.pb_fields(b"\x12\x7fshort"))
assert isinstance(trunc, list)
print("OK")
PY
)
rc=$?
check "lib/afc/pb.py decodes valid fields and handles truncated input safely" \
  '[[ $rc -eq 0 && "$pb_check" == "OK" ]]' "$pb_check"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
