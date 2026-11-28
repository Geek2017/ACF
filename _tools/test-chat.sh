#!/usr/bin/env bash
# test-chat.sh: automated tests for bin/afc-chat and `agents --view unified`.
#
# Runs entirely in a throw-away sandbox under /tmp with stub CLIs and its own tmux server:
# no real model is called, no live fleet pane is touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHAT="$HERE/bin/afc-chat"
AGENTS="$HERE/bin/agents"
INFO="$HERE/bin/afc-agent-info"
CONF="$HERE/tmux/tmux.conf"

SBX=$(mktemp -d "${TMPDIR:-/tmp}/afc-chat-test.XXXXXX")
H="$SBX/home"; RT="$SBX/run"; SOCK="afcchattest-$$"; PROJ="$SBX/proj"
mkdir -p "$H/.local/bin" "$H/.local/lib/afc" "$H/.config/agents" "$H/.claude/projects/stub" \
         "$H/.claude-others" "$RT" "$PROJ"
chmod 700 "$RT"

cleanup() {
  env HOME="$H" XDG_RUNTIME_DIR="$RT" tmux -L "$SOCK" kill-server 2>/dev/null || true
  pkill -f "$H/.local/bin/afc-chat" 2>/dev/null || true
  rm -rf "$SBX"
}
trap cleanup EXIT

TMUXBIN=$(command -v tmux)
ln -s "$TMUXBIN" "$H/.local/bin/tmux"
ln -s "$AGENTS" "$H/.local/bin/agents"
ln -s "$CHAT" "$H/.local/bin/afc-chat"
ln -s "$INFO" "$H/.local/bin/afc-agent-info"
for f in afc-even afc-min afc-reflow afc-move; do
  [[ -e "$HERE/bin/$f" ]] && ln -s "$HERE/bin/$f" "$H/.local/bin/$f"
done
ln -s "$HERE/lib/afc/pb.py" "$H/.local/lib/afc/pb.py"
ln -s "$CONF" "$H/.tmux.conf"
printf 'Proj %s\n' "$PROJ" > "$H/.config/agents/projects"
printf 'main ~/.claude\nothers ~/.claude-others\n' > "$H/.config/agents/accounts"
printf 'main ~/.codex\nacctb ~/.codex-b\n' > "$H/.config/agents/accounts-codex"
printf 'start-gap 0\nview unified\n' > "$H/.config/agents/settings"
echo "0 10 30" > "$SBX/load-calm"

sb() {
  env -u TMUX -u TMUX_PANE -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_CLI_HOME \
      -u AGENTS_LIST -u AGENTS_ACCOUNTS -u AGENTS_LAYOUT -u AGENTS_SETTINGS \
      HOME="$H" XDG_RUNTIME_DIR="$RT" AGENTS_SOCK="$SOCK" AGENTS_LAYOUT_EVERY=2 \
      AGENTS_LOAD="$SBX/load-calm" AFC_AGENTS="$H/.local/bin/agents" \
      PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}
tm() { sb tmux -L "$SOCK" "$@"; }

n_pass=0; n_fail=0
ok()  { n_pass=$((n_pass + 1)); printf '  pass  %s\n' "$1"; }
bad() { n_fail=$((n_fail + 1)); printf '  FAIL  %s\n' "$1"; if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed "s|$SBX|SBX|g; s/^/          /"; fi; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got:  $2"$'\n'"want: $3"; fi; }
has() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing /$3/ in:"$'\n'"${2:0:600}"; fi; }
hasnt() { if grep -qE -- "$3" <<< "$2"; then bad "$1" "unexpected /$3/ in:"$'\n'"${2:0:600}"; else ok "$1"; fi; }

# ---- Realistic JSONL stub CLIs matching real probed outputs ---------------------------------
stub() { cat > "$H/.local/bin/$1"; chmod +x "$H/.local/bin/$1"; }

stub claude <<'EOF'
#!/bin/bash
echo "claude $*" >> "$HOME/argv.log"
# Native mode (not -p): record session and wait like test-fleet.sh
if [[ " $* " != *" -p "* ]]; then
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; mkdir -p "$cfg/sessions"
  echo "{\"pid\":$$,\"sessionId\":\"native-claude-1\"}" > "$cfg/sessions/$$.json"
  echo "NATIVE_CLAUDE $*"
  if [[ -n "${STUB_EXIT_FAST:-}" ]]; then exit 0; fi
  while :; do sleep 60; done
fi
if [[ "$*" == *"NO_TODO_BASH"* ]]; then
  cat <<'JSONL'
{"type":"system","subtype":"init","session_id":"cl-sess-notodo","model":"claude-opus-5-5"}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"nt1","name":"Bash","input":{"command":"cd \"/tmp/demo/Codebase/OMS\" && grep -n \"getPricingForSkus\" -A22 amazon.js | head -30"}}],"usage":{"input_tokens":500,"output_tokens":40}}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"nt1","content":"RAW_GREP_LINE_123","is_error":false}]},"tool_use_result":{"stdout":"RAW_GREP_LINE_123","stderr":""}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"nt2","name":"Edit","input":{"file_path":"/tmp/scheduler-modern.ts"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"nt2","content":"ok","is_error":false}]}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Updated pricing cleanly."}]}}
{"type":"result","session_id":"cl-sess-notodo","result":"Updated pricing cleanly.","total_cost_usd":0.02,"usage":{"input_tokens":800,"output_tokens":100}}
JSONL
  exit 0
fi
if [[ "$*" == *"SLOW_CMD"* ]]; then
  echo '{"type":"system","subtype":"init","session_id":"cl-sess-1","model":"claude-opus-5-5"}'
  echo '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t_slow","name":"Bash","input":{"command":"sleep 10"}}],"usage":{"input_tokens":100,"output_tokens":20}}}'
  sleep 10
  exit 0
fi
cat <<'JSONL'
{"type":"system","subtype":"init","session_id":"cl-sess-1","model":"claude-opus-5-5"}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Inspect repo"}}],"usage":{"input_tokens":1000,"output_tokens":50}}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created"}]},"tool_use_result":{"task":{"id":"1","subject":"Inspect repo"}}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t2","name":"TaskCreate","input":{"subject":"Run tests"}}],"usage":{"input_tokens":1100,"output_tokens":60}}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Task #2 created"}]},"tool_use_result":{"task":{"id":"2","subject":"Run tests"}}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t3","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t4","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}]}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t5","name":"Bash","input":{"command":"echo SECRET_VERBOSE_BASH_LINE_1 && echo SECRET_VERBOSE_BASH_LINE_2"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t5","content":"SECRET_VERBOSE_BASH_LINE_1\nSECRET_VERBOSE_BASH_LINE_2","is_error":false}]},"tool_use_result":{"stdout":"SECRET_VERBOSE_BASH_LINE_1\nSECRET_VERBOSE_BASH_LINE_2","stderr":""}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t6","name":"Read","input":{"file_path":"/tmp/foo.py"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t6","content":"print(1)","is_error":false}]}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t7","name":"TaskUpdate","input":{"taskId":"2","status":"completed"}}]}}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"All checks passed cleanly."}]}}
{"type":"result","session_id":"cl-sess-1","result":"All checks passed cleanly.","total_cost_usd":0.04,"usage":{"input_tokens":1400,"output_tokens":200}}
JSONL
EOF

stub codex <<'EOF'
#!/bin/bash
echo "codex $*" >> "$HOME/argv.log"
if [[ "${1:-}" != exec ]]; then
  echo "NATIVE_CODEX $*"
  while :; do sleep 60; done
fi
cat >/dev/null
cat <<'JSONL'
{"type":"thread.started","thread_id":"cx-thread-42"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i0","type":"todo_list","items":[{"text":"Check git status","completed":true},{"text":"Run build","completed":false}]}}
{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"/bin/bash -lc 'git status'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"/bin/bash -lc 'git status'","aggregated_output":"CODEX_RAW_STDOUT_HIDDEN\n","exit_code":0,"status":"completed"}}
{"type":"item.started","item":{"id":"i2","type":"command_execution","command":"/bin/bash -lc 'false'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"/bin/bash -lc 'false'","aggregated_output":"boom\n","exit_code":1,"status":"completed"}}
{"type":"item.completed","item":{"id":"i3","type":"todo_list","items":[{"text":"Check git status","completed":true},{"text":"Run build","completed":true}]}}
{"type":"item.completed","item":{"id":"i4","type":"agent_message","text":"Codex reply ready."}}
{"type":"turn.completed","usage":{"input_tokens":2400,"output_tokens":120}}
JSONL
EOF

stub gemini <<'EOF'
#!/bin/bash
echo "gemini $*" >> "$HOME/argv.log"
if [[ " $* " != *" stream-json "* ]]; then
  echo "NATIVE_GEMINI $*"
  while :; do sleep 60; done
fi
cat <<'JSONL'
{"type":"init","session_id":"gem-sess-7","model":"gemini-4-argon"}
{"type":"tool_use","tool_name":"write_todos","tool_id":"gt0","parameters":{"todos":[{"description":"Audit files","status":"completed"},{"description":"Run check","status":"in_progress"}]}}
{"type":"tool_result","tool_id":"gt0","status":"success","output":"ok"}
{"type":"tool_use","tool_name":"run_shell_command","tool_id":"gt1","parameters":{"command":"ls -la"}}
{"type":"tool_result","tool_id":"gt1","status":"success","output":"GEMINI_RAW_LS_OUTPUT"}
{"type":"tool_use","tool_name":"write_todos","tool_id":"gt2","parameters":{"todos":[{"description":"Audit files","status":"completed"},{"description":"Run check","status":"completed"}]}}
{"type":"tool_result","tool_id":"gt2","status":"success","output":"ok"}
{"type":"message","role":"assistant","content":"Gemini ","delta":true}
{"type":"message","role":"assistant","content":"finished.","delta":true}
{"type":"result","status":"success","stats":{"total_tokens":1800,"input_tokens":1500,"output_tokens":300}}
JSONL
EOF

stub agy <<'EOF'
#!/bin/bash
echo "agy $*" >> "$HOME/argv.log"
if [[ " $* " != *" stream-json "* ]]; then
  echo "NATIVE_AGY $*"
  while :; do sleep 60; done
fi
TASKF="$HOME/agy-brain/task.md"
mkdir -p "${TASKF%/*}"
printf -- '- [x] Map wiring\n- [x] Run verification\n' > "$TASKF"
cat <<JSONL
{"event":"init","conversation_id":"agy-conv-9"}
{"event":"step_update","step_update":{"conversation_id":"agy-conv-9","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"write_file","tool_info":{"name":"write_file","parameters":{"Path":"$TASKF"}}}}
{"event":"step_update","step_update":{"conversation_id":"agy-conv-9","step_index":1,"state":"DONE","step_type":"tool","tool_name":"write_file","duration_seconds":0.2,"tool_info":{"name":"write_file","parameters":{"Path":"$TASKF"}}}}
{"event":"step_update","step_update":{"conversation_id":"agy-conv-9","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"pytest -q"}}}}
{"event":"step_update","step_update":{"conversation_id":"agy-conv-9","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.5,"tool_info":{"name":"run_command","parameters":{"CommandLine":"pytest -q"},"output":"Command exited with code 0.\nAGY_RAW_TEST_LOG"}}}
{"event":"result","result":{"conversation_id":"agy-conv-9","status":"SUCCESS","response":"Antigravity complete.","usage":{"total_tokens":3200,"input_tokens":2800,"output_tokens":400}}}
JSONL
EOF

stub copilot <<'EOF'
#!/bin/bash
echo "copilot $*" >> "$HOME/argv.log"
if [[ " $* " != *" --output-format json "* ]]; then
  echo "NATIVE_COPILOT $*"
  while :; do sleep 60; done
fi
cat <<'JSONL'
{"type":"session.start","sessionId":"cp-sess-3","data":{"model":"gpt-5.6-sol"}}
{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"update_todo","arguments":{"todos":[{"title":"Check PR","status":"completed"}]}}}
{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":true}}
{"type":"tool.execution_start","data":{"toolCallId":"c2","toolName":"bash","arguments":{"command":"gh pr status"}}}
{"type":"tool.execution_complete","data":{"toolCallId":"c2","success":true,"result":{"content":"COPILOT_RAW_STDOUT"}}}
{"type":"assistant.message","data":{"content":"Copilot done."}}
{"type":"result","exitCode":0,"usage":{"inputTokens":900,"outputTokens":100}}
JSONL
EOF

stub opencode <<'EOF'
#!/bin/bash
echo "opencode $*" >> "$HOME/argv.log"
if [[ "${1:-}" != run ]]; then
  echo "NATIVE_OPENCODE $*"
  while :; do sleep 60; done
fi
cat <<'JSONL'
{"type":"step_start","sessionID":"oc-sess-5"}
{"type":"tool_use","sessionID":"oc-sess-5","part":{"tool":"todowrite","callID":"o1","state":{"status":"completed","input":{"todos":[{"content":"Deploy worker","status":"completed"}]}}}}
{"type":"tool_use","sessionID":"oc-sess-5","part":{"tool":"bash","callID":"o2","state":{"status":"completed","input":{"command":"wrangler whoami"},"output":"OPENCODE_RAW_STDOUT"}}}
{"type":"text","sessionID":"oc-sess-5","part":{"text":"OpenCode done."}}
{"type":"step_finish","sessionID":"oc-sess-5","part":{"tokens":{"input":700,"output":80},"cost":0.01}}
JSONL
EOF

echo "1. Provider adapters (checklist + 1-line bash folding across all 6 providers)"

out=$(sb "$H/.local/bin/afc-chat" --tool claude --account main --once "test claude")
has   "Claude: renders circled └ ✓ task tree" "$out" '└ ✓ Inspect repo'
has   "Claude: shows completed tasks" "$out" '✓ Run tests'
has   "Claude: shows 1-line folded summary (bash + read)" "$out" 'Ran 1 shell command, read 1 file'
hasnt "Claude: hides raw bash command string" "$out" 'echo SECRET_VERBOSE'
hasnt "Claude: hides verbose raw bash stdout" "$out" 'SECRET_VERBOSE_BASH_LINE_1'
has   "Claude: prints clean reply" "$out" 'All checks passed cleanly\.'

out_nt=$(sb "$H/.local/bin/afc-chat" --tool claude --account main --once "NO_TODO_BASH fix pricing")
has   "No-todo task: auto-synthesizes clean task tree regardless of task" "$out_nt" '└ ✓ '
has   "No-todo task: translates ugly bash grep into clean 'Searching codebase'" "$out_nt" '✓ Searching codebase'
has   "No-todo task: shows clean file edit step" "$out_nt" '✓ Editing scheduler-modern\.ts'
hasnt "No-todo task: never puts user prompt in task list" "$out_nt" '✓ NO_TODO_BASH'
hasnt "No-todo task: never prints raw cd/grep bash command" "$out_nt" 'getPricingForSkus'
hasnt "No-todo task: hides raw grep stdout" "$out_nt" 'RAW_GREP_LINE_123'

out=$(sb "$H/.local/bin/afc-chat" --tool codex --account main --once "test codex")
has   "Codex: renders todo_list checklist" "$out" '✓ Check git status'
has   "Codex: summarizes 2 commands with 1 failed" "$out" 'Ran 2 shell commands · 1 failed'
hasnt "Codex: hides raw command output" "$out" 'CODEX_RAW_STDOUT_HIDDEN'
has   "Codex: prints clean reply" "$out" 'Codex reply ready\.'

out=$(sb "$H/.local/bin/afc-chat" --tool gemini --once "test gemini")
has   "Gemini: renders write_todos checklist" "$out" '✓ Audit files'
has   "Gemini: folds shell command into 1 line" "$out" 'Ran 1 shell command'
hasnt "Gemini: hides raw shell output" "$out" 'GEMINI_RAW_LS_OUTPUT'
has   "Gemini: prints streamed reply" "$out" 'Gemini finished\.'

out=$(sb "$H/.local/bin/afc-chat" --tool agy --once "test agy")
has   "Antigravity: parses task.md into checklist tree" "$out" '✓ Map wiring'
has   "Antigravity: folds run_command into 1 line" "$out" 'Ran 1 shell command'
hasnt "Antigravity: hides raw command output" "$out" 'AGY_RAW_TEST_LOG'
has   "Antigravity: prints clean reply" "$out" 'Antigravity complete\.'

out=$(sb "$H/.local/bin/afc-chat" --tool copilot --once "test copilot")
has   "Copilot: renders update_todo checklist" "$out" '✓ Check PR'
has   "Copilot: folds bash into 1 line" "$out" 'Ran 1 shell command'
hasnt "Copilot: hides raw bash output" "$out" 'COPILOT_RAW_STDOUT'
has   "Copilot: prints reply" "$out" 'Copilot done\.'

out=$(sb "$H/.local/bin/afc-chat" --tool opencode --once "test opencode")
has   "OpenCode: renders todowrite checklist" "$out" '✓ Deploy worker'
has   "OpenCode: folds bash into 1 line" "$out" 'Ran 1 shell command'
hasnt "OpenCode: hides raw bash output" "$out" 'OPENCODE_RAW_STDOUT'
has   "OpenCode: prints reply" "$out" 'OpenCode done\.'

echo "2. Interactive PTY: multi-turn resume, /steps expand, /mode, /model, /provider, Ctrl+C interrupt"

: > "$H/argv.log"
pty_out=$(sb python3 - <<'PY'
import os, pty, select, subprocess, time, re

def strip_ansi(s):
    return re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07", "", s)

master, slave = pty.openpty()
p = subprocess.Popen(
    [os.path.expanduser("~/.local/bin/afc-chat"), "--tool", "claude", "--account", "main"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True,
)
os.close(slave)

def read_until(pat, timeout=8.0):
    buf = ""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                chunk = os.read(master, 4096).decode("utf-8", "replace")
            except OSError:
                break
            buf += chunk
            if re.search(pat, strip_ansi(buf)):
                return buf
    return buf

out = read_until(r"❯ ")
os.write(master, b"first prompt\n")
out += read_until(r"All checks passed cleanly")
out += read_until(r"❯ ")

# /steps reveals the folded bash command & stdout
os.write(master, b"/steps\n")
out += read_until(r"SECRET_VERBOSE_BASH_LINE_1")
out += read_until(r"❯ ")

# Second turn must resume cl-sess-1!
os.write(master, b"second prompt\n")
out += read_until(r"All checks passed cleanly")
out += read_until(r"❯ ")

# Slash commands: /mode, /model set, /effort, /provider codex
os.write(master, b"/mode plan\n")
out += read_until(r"Permission mode is now plan")
os.write(master, b"/model set claude-sonnet-5-5\n")
out += read_until(r"claude-sonnet-5-5")

# Ctrl+C during a slow turn interrupts without killing afc-chat (and live view shows clean label, NOT raw 'sleep 10')
os.write(master, b"SLOW_CMD\n")
out += read_until(r"Running shell command", timeout=4.0)
time.sleep(0.2)
os.write(master, b"\x03")
out += read_until(r"Interrupted")
out += read_until(r"❯ ")

# Switch provider in-place to codex and run a turn
os.write(master, b"/provider codex main\n")
out += read_until(r"Switched to Codex")
os.write(master, b"hello codex\n")
out += read_until(r"Codex reply ready")
out += read_until(r"❯ ")

os.write(master, b"/quit\n")
p.wait(timeout=5)
os.close(master)
print(strip_ansi(out))
PY
)

has "PTY: /steps reveals hidden bash stdout" "$pty_out" 'SECRET_VERBOSE_BASH_LINE_1'
has "PTY: /mode plan switches mode" "$pty_out" 'Permission mode is now plan'
has "PTY: /model set updates model" "$pty_out" 'Model is now claude-sonnet-5-5'
has "PTY: Ctrl+C interrupts running turn cleanly" "$pty_out" 'Interrupted'
has "PTY: /provider codex switches provider live" "$pty_out" 'Codex reply ready\.'
has "PTY: turn 2 passed --resume cl-sess-1 to Claude" "$(cat "$H/argv.log")" '--resume cl-sess-1'

echo "3. Fleet tmux integration: agents --view unified, --who, --running, afc-agent-info, layout save/restore, --view classic round-trip, --doctor"

sb "$H/.local/bin/agents" </dev/null >/dev/null 2>&1
sleep 1.5
p0=$(tm display -p -t agents:1.1 '#{pane_pid}')
tm split-window -fh -t agents:1 "$H/.local/bin/agents --pane codex $p0 main"
tm split-window -v  -t agents:1.2 "$H/.local/bin/agents --pane agy $p0"
sleep 1.5

p_cl=$(tm display -p -t agents:1.1 '#{pane_pid}')
p_cx=$(tm display -p -t agents:1.2 '#{pane_pid}')
p_ag=$(tm display -p -t agents:1.3 '#{pane_pid}')

is  "agents --view reports unified" "$(sb "$H/.local/bin/agents" --view)" "view: unified"
is  "agents --who identifies unified Claude pane" "$(sb "$H/.local/bin/agents" --who "$p_cl")" "claude main"
is  "agents --who identifies unified Codex pane"  "$(sb "$H/.local/bin/agents" --who "$p_cx")" "codex main"
is  "agents --who identifies unified Agy pane"    "$(sb "$H/.local/bin/agents" --who "$p_ag")" "agy"
is  "agents --running counts all 3 unified panes" "$(sb "$H/.local/bin/agents" --running)" "3"

# Run one turn inside Codex pane so session_id & tokens populate runtime state JSON
tm send-keys -t agents:1.2 "hi codex" Enter
sleep 2
info_cx=$(sb "$H/.local/bin/afc-agent-info" codex "$p_cx")
chat_cx=$(sb "$H/.local/bin/afc-agent-info" --chat codex "$p_cx")
has "afc-agent-info reads live tokens from afc-chat runtime JSON" "$info_cx" '3k'
has "afc-agent-info --chat reads exact Codex thread_id from afc-chat" "$chat_cx" '^cx-thread-42	'

# Layout save captures exact unified sessions
sleep 3
layout_txt=$(cat "$H/.local/state/afc/layout" 2>/dev/null || true)
has "saved layout records unified Claude pane" "$layout_txt" $'^P\tclaude\tmain\t'
has "saved layout records unified Codex pane with exact session id" "$layout_txt" $'^P\tcodex\tmain\tcx-thread-42\t'
has "saved layout records unified Agy pane" "$layout_txt" $'^P\tagy\t'

# Switch all idle panes to classic view: restarts unified panes back into native CLIs on same chat!
vout=$(sb "$H/.local/bin/agents" --view classic all 2>&1)
has "agents --view classic all restarts all 3 idle unified panes" "$vout" '3 pane\(s\) restarted in the classic view'
sleep 1.5
has "Codex restarted in native view with exact resumed thread id" "$(tm capture-pane -p -t agents:1.2)" 'NATIVE_CODEX resume cx-thread-42'

# Switch back to unified view and verify --doctor reports clean view & zero unknown settings
vout2=$(sb "$H/.local/bin/agents" --view unified all 2>&1)
has "agents --view unified all switches panes back to unified" "$vout2" '3 pane\(s\) restarted in the unified view'
doc=$(sb "$H/.local/bin/agents" --doctor 2>&1 || true)
has   "agents --doctor reports unified view ok" "$doc" 'ok +View: unified \(afc-chat\)'
hasnt "agents --doctor reports no unknown setting for view" "$doc" 'unknown names in .*settings:.*view'

# 4. format_markdown colors ```diff (- red, + green) and plain You:/SITREP lines (red/green)
md_chk=$(python3 - "$CHAT" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("afc_chat_mod", sys.argv[1])
spec = importlib.util.spec_from_loader("afc_chat_mod", loader)
mod = importlib.util.module_from_spec(spec)
sys.modules["afc_chat_mod"] = mod
loader.exec_module(mod)
mod.TTY_OUT = True
sample = "```diff\n- You: push sandbox\n\n+ SITREP · D:MDMP · M:OODA · P5 ASSESS · Done: ok\n```\nYou: plain\nSITREP · D:MDMP · M:OODA"
out = mod.format_markdown(sample, 100)
red, green = mod.C["red"], mod.C["green"]
assert f"\033[{red}m- You: push sandbox\033[0m" in out, out
assert f"\033[{green}m+ SITREP · D:MDMP · M:OODA · P5 ASSESS · Done: ok\033[0m" in out, out
assert f"\033[{red}mYou: plain\033[0m" in out, out
assert f"\033[{green}mSITREP · D:MDMP · M:OODA\033[0m" in out, out
print("MD_SITREP_OK")
PY
)
has "format_markdown paints You:/- You: red and SITREP/+ SITREP green" "$md_chk" 'MD_SITREP_OK'

echo
echo "$n_pass passed, $n_fail failed."
(( n_fail == 0 ))
