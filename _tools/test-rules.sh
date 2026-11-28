#!/usr/bin/env bash
# test-rules.sh: tests for bin/afc-rules, the rule check of TokenOps projects. Touches nothing of yours:
# a made-up TokenOps project, hand-written chat files of each tool and a stand-in home folder, all
# under one temp folder that is removed afterwards.
#
#   bash _tools/test-rules.sh                  test bin/afc-rules of this folder
#   bash _tools/test-rules.sh --rules FILE     test another copy (its afc-logs: AFC_RULES_LOGS, else beside it)
#   bash _tools/test-rules.sh --keep           leave the temp folder for a look
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RULES="$HERE/bin/afc-rules"; KEEP=0
while (( $# )); do
  case "$1" in
    --rules) RULES="$2"; shift ;;
    --keep) KEEP=1 ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done
[[ -n "${AFC_RULES_LOGS:-}" || -f "$(dirname "$(readlink -f "$RULES")")/afc-logs" ]] || export AFC_RULES_LOGS="$HERE/bin/afc-logs"

T=$(mktemp -d /tmp/acf-rules-test.XXXXXX)
(( KEEP )) || trap 'rm -rf "$T"' EXIT
export HOME="$T/home" AFC_RULES_STATE="$T/state" AGENTS_SETTINGS="$T/settings" AGENTS_PROJECT_MODES="$T/project-modes.json" AGENTS_SOCK="acfrules-none-$$"
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CLI_HOME
mkdir -p "$HOME" "$AFC_RULES_STATE"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | head -c 600; }
nodec() { [[ "$1" != *'"decision"'* ]]; }
setmode() { printf 'rules %s\nstyle-ste off\ncode-do178c off\n' "$1" > "$AGENTS_SETTINGS"; }
rules() { python3 -I "$RULES" "$@"; }
hook() { local tool=$1 ev=$2 json=$3; printf '%s' "$json" | python3 -I "$RULES" hook "$tool" "$ev" 2>"$T/err"; }

# ---- a TokenOps project ------------------------------------------------------------------------
P="$T/proj"; mkdir -p "$P/.git" "$P/_ai/fixes" "$P/_ai/skills/a" "$P/_ai/skills/b" "$P/_ai/skills/c" "$P/src" "$P/_tools"
cat > "$P/_ai/TOKENOPS.json" <<'EOF'
{"version": 1, "generator": "TokenOps", "files": [
 {"path": "_ai/INDEX.md"}, {"path": "_ai/FIXES.md"}, {"path": "_ai/UPDATES.md"}, {"path": "_ai/WORKFLOW.md"},
 {"path": "CLAUDE.md"}, {"path": "AGENTS.md"}, {"path": "GEMINI.md"}, {"path": "_tools/check-fixes.py"},
 {"path": "_ai/skills/a/SKILL.md"}, {"path": "_ai/skills/b/SKILL.md"}, {"path": "_ai/skills/c/SKILL.md"}]}
EOF
printf '# Project memory index\n\nBudget: <= 400 Unicode chars.\n' > "$P/_ai/INDEX.md"
printf '# Fix registry\n\n| FIX-0001 | [Record](fixes/FIX-0001.md) |\n' > "$P/_ai/FIXES.md"
cat > "$P/_ai/fixes/FIX-0001.md" <<'EOF'
# FIX-0001

```json
{"id": "FIX-0001", "status": "fixed", "summary": "app crashed", "affected_paths": ["src/app.js"],
 "related_fixes": [], "protected_behavior": "app starts", "checks": []}
```
EOF
printf '# Updates\n' > "$P/_ai/UPDATES.md"; printf '# Workflow\n' > "$P/_ai/WORKFLOW.md"
printf '@_ai/INDEX.md\n\nRead `_ai/INDEX.md` first.\n' > "$P/CLAUDE.md"; cp "$P/CLAUDE.md" "$P/GEMINI.md"
printf '# Project instructions\n\nRead `_ai/INDEX.md` first.\n' > "$P/AGENTS.md"
for s in a b c; do printf 'skill %s\n' "$s" > "$P/_ai/skills/$s/SKILL.md"; done
printf 'print("no")\n' > "$P/_tools/check-fixes.py"      # never run by afc-rules: a run would print "no"
printf 'a\n' > "$P/src/app.js"; printf 'b\n' > "$P/src/other.js"
N="$T/plain"; mkdir -p "$N/.git"            # a folder with no TokenOps files

# ---- chat files ---------------------------------------------------------------------------------
ts() { printf '2026-11-16T10:%02d:00.000Z' "$1"; }
cl_user() { printf '{"type":"user","cwd":"%s","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$P" "$(ts "$1")" "$2"; }
cl_tool() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"m","content":[{"type":"tool_use","name":"%s","input":%s}]}}\n' "$(ts "$1")" "$2" "$3"; }
cl_text() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"%s"}]}}\n' "$(ts "$1")" "$2"; }
CL1="$T/claude-1.jsonl"      # edits a protected file, no fix check
{ cl_user 1 "fix the bug"; cl_tool 2 Edit "{\"file_path\":\"$P/src/app.js\",\"old_string\":\"a\",\"new_string\":\"c\"}"; cl_text 3 "done"; } > "$CL1"
CL2="$T/claude-2.jsonl"      # runs the fix check first
{ cl_user 1 "fix the bug"; cl_tool 2 Bash '{"command":"python3 _tools/check-fixes.py --path src/app.js"}'
  cl_tool 3 Edit "{\"file_path\":\"$P/src/app.js\",\"old_string\":\"a\",\"new_string\":\"c\"}"; cl_text 4 "done"; } > "$CL2"
CL3="$T/claude-3.jsonl"      # reads FIXES.md with sed: counts as checking
{ cl_user 1 "fix"; cl_tool 2 Bash "{\"command\":\"cd \\\"$P\\\" && sed -n '1,40p' _ai/FIXES.md\"}"
  cl_tool 3 Edit "{\"file_path\":\"$P/src/app.js\",\"old_string\":\"a\",\"new_string\":\"c\"}"; } > "$CL3"
CL4="$T/claude-4.jsonl"      # writes Claude's memory folder and edits a rule file: notes only
{ cl_user 1 "remember"; cl_tool 2 Write "{\"file_path\":\"$HOME/.claude/projects/x/memory/a.md\",\"content\":\"x\"}"
  cl_tool 3 Edit "{\"file_path\":\"$P/AGENTS.md\",\"old_string\":\"a\",\"new_string\":\"b\"}"
  cl_tool 4 Write "{\"file_path\":\"/tmp/scratch-ok.txt\",\"content\":\"x\"}"; } > "$CL4"
CL5="$T/claude-5.jsonl"      # pushes INDEX.md over its budget
{ cl_user 1 "update index"; cl_tool 2 Edit "{\"file_path\":\"$P/_ai/INDEX.md\",\"old_string\":\"a\",\"new_string\":\"b\"}"; } > "$CL5"
cx_head() { printf '{"type":"session_meta","timestamp":"%s","payload":{"cwd":"%s"}}\n' "$(ts 0)" "$P"; }
cx_user() { printf '{"type":"response_item","timestamp":"%s","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"%s"}]}}\n' "$(ts "$1")" "$2"; }
cx_exec() { python3 -c 'import json,sys; print(json.dumps({"type":"response_item","timestamp":sys.argv[1],"payload":{"type":"custom_tool_call","name":"exec","input":sys.argv[2]}}))' "$(ts "$1")" "$2"; }
CX1="$T/rollout-1.jsonl"     # a patch, and the index never read
{ cx_head; cx_user 1 "# AGENTS.md instructions for $P"; cx_user 2 "change other.js"
  cx_exec 3 'text(await tools.apply_patch("*** Begin Patch\n*** Update File: src/other.js\n@@\n-b\n+d\n*** End Patch"))'; } > "$CX1"
CX2="$T/rollout-2.jsonl"     # reads the index first
{ cx_head; cx_user 2 "change other.js"; cx_exec 3 'text(await tools.exec_command({cmd:"sed -n \"1,80p\" _ai/INDEX.md"}))'
  cx_exec 4 'text(await tools.apply_patch("*** Begin Patch\n*** Update File: src/other.js\n@@\n-b\n+d\n*** End Patch"))'; } > "$CX2"
mkdir -p "$T/gem"; GM="$T/gem/session-1.json"
python3 -c 'import json,sys; print(json.dumps({"sessionId":"g1","startTime":"2026-11-16T10:00:00Z","messages":[
 {"id":"1","type":"user","timestamp":"2026-11-16T10:01:00Z","content":[{"text":"fix app"}]},
 {"id":"2","type":"gemini","timestamp":"2026-11-16T10:02:00Z","content":[{"text":"ok"}],
  "toolCalls":[{"name":"replace","args":{"file_path":"src/app.js","old_string":"a","new_string":"e"}}]}]}))' > "$GM"

j() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d'"$1"')' "$2" 2>/dev/null; }

echo "Hooks, enforce"
setmode enforce
out=$(hook claude stop "{\"session_id\":\"c1\",\"transcript_path\":\"$CL1\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
if [[ "$(j '["systemMessage"]' "$out")" == "ACF rules ✗ sent back to fix:"*FIX-0001* && "$(j '["decision"]' "$out")" == block && "$out" == *FIX-0001* && "$out" == *"[ACF rule check]"* && "$out" == *check-fixes.py\ --path\ src/app.js* ]]; then ok "Claude: a protected file changed without a fix check is sent back, with what to run"
else bad "Claude: no block for the unchecked protected file" "$out $(cat "$T/err")"; fi
if [[ "$out" == *"$P/CLAUDE.md"* ]]; then ok "the message names the project's own rule file by its full path"; else bad "no local rule file path in the message" "$out"; fi
grep -q $'\thard\tfix-check\t' "$P/logs/acf/rules.log" 2>/dev/null && ok "the finding is a line in <project>/logs/acf/rules.log" || bad "no line in rules.log"
out=$(hook claude stop "{\"session_id\":\"c1\",\"transcript_path\":\"$CL1\",\"cwd\":\"$P\",\"stop_hook_active\":true}")
nodec "$out" && [[ "$out" == *"ACF rules ✗ still open"* ]] && ok "the turn's second stop (stop_hook_active) is let through, once per turn; the recap says it is still open" || bad "sent back twice in one turn" "$out"
[[ $(grep -c $'\tfix-check\t' "$P/logs/acf/rules.log") == 1 ]] && ok "a finding is logged once per turn, however often the turn stops" || bad "logged twice" "$(cat "$P/logs/acf/rules.log")"
out=$(hook claude stop "{\"session_id\":\"c2\",\"transcript_path\":\"$CL2\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
nodec "$out" && ok "Claude: check-fixes.py --path before the edit: let through" || bad "blocked although checked" "$out"
msg=$(j '["systemMessage"]' "$out")
[[ "$msg" == "ACF rules △ · 1 file changed · index loaded by CLAUDE.md · fix check done for src/app.js · note: work not yet in _ai/UPDATES.md" ]] && ok "the recap under the reply: the verdict, what changed, index, fix check, notes" || bad "recap wording" "$msg"
printf 'rules enforce\nrules-recap off\nstyle-ste off\ncode-do178c off\n' > "$AGENTS_SETTINGS"
out=$(hook claude stop "{\"session_id\":\"c2b\",\"transcript_path\":\"$CL2\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
[[ -z "$out" ]] && ok "rules-recap off: no recap line" || bad "recap shown although off" "$out"
setmode enforce
out=$(hook claude stop "{\"session_id\":\"c3\",\"transcript_path\":\"$CL3\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
nodec "$out" && ok "Claude: reading _ai/FIXES.md (sed, inside a cd \"...\" && command) counts as the check" || bad "blocked although FIXES.md was read" "$out"
out=$(hook claude stop "{\"session_id\":\"c4\",\"transcript_path\":\"$CL4\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
log=$(grep -E $'\t(outside|rule-files)\t' "$P/logs/acf/rules.log")
if nodec "$out" && [[ "$out" == *"ACF rules △"* && "$log" == *outside*memory* && "$log" == *rule-files*AGENTS.md* && "$log" != *scratch-ok* ]]; then ok "soft rules only note: Claude's memory folder, a generated rule file (temp files are fine)"
else bad "soft rules wrong" "out=$out log=$log"; fi
python3 -c 'print("x" * 500)' >> "$P/_ai/INDEX.md"
out=$(hook claude stop "{\"session_id\":\"c5\",\"transcript_path\":\"$CL5\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
[[ "$out" == *"over its budget of 400"* ]] && ok "INDEX.md over its own budget line (Budget: <= 400) is sent back" || bad "index budget not caught" "$out"
printf '# Project memory index\n\nBudget: <= 400 Unicode chars.\n' > "$P/_ai/INDEX.md"
out=$(hook codex stop "{\"session_id\":\"x1\",\"transcript_path\":\"$CX1\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
if [[ "$(j '["decision"]' "$out")" == block && "$out" == *"_ai/INDEX.md was never read"* ]]; then ok "Codex: a patch with the index never read is sent back (its AGENTS.md has no @import)"
else bad "Codex: index-first not caught" "$out $(cat "$T/err")"; fi
[[ "$out" != *"FIX-0001"* ]] && ok "Codex: src/other.js is not protected, so no fix-check finding" || bad "fix-check on an unprotected file" "$out"
out=$(hook codex stop "{\"session_id\":\"x2\",\"transcript_path\":\"$CX2\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
nodec "$out" && ok "Codex: sed of _ai/INDEX.md inside an exec cell counts as reading it" || bad "Codex blocked although the index was read" "$out"
out=$(hook gemini stop "{\"session_id\":\"g1\",\"transcript_path\":\"$GM\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
if [[ "$(j '["decision"]' "$out")" == deny && "$out" == *FIX-0001* ]]; then ok "Gemini: a relative path (src/app.js) is resolved from its folder; sent back with deny"
else bad "Gemini: no deny" "$out $(cat "$T/err")"; fi
[[ "$out" != *"never read"* ]] && ok "Gemini: GEMINI.md's @_ai/INDEX.md counts as reading the index" || bad "Gemini: index-first despite the import" "$out"
out=$(hook agy stop "{\"conversationId\":\"nope\",\"cwd\":\"$P\",\"continuationActive\":false}")
[[ "$out" == "{}" ]] && ok "Antigravity: no conversation file: an empty answer, the turn goes on" || bad "agy without chat" "$out"

echo "The reminder on every prompt"
out=$(hook claude prompt "{\"session_id\":\"c9\",\"cwd\":\"$P/src\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
if [[ "$(j '["hookSpecificOutput"]["hookEventName"]' "$out")" == UserPromptSubmit && "$ctx" == *"[ACF rules]"*"$P"*CLAUDE.md* ]]; then ok "Claude: from a subfolder, the reminder names the project's own CLAUDE.md and path"
else bad "Claude reminder" "$out $(cat "$T/err")"; fi
[[ "$ctx" != *"Read _ai/INDEX.md before"* && "$ctx" == *"1 fix records"* ]] && ok "Claude: no 'read the index' (CLAUDE.md imports it); the fix count is there" || bad "Claude reminder wording" "$ctx"
out=$(hook codex prompt "{\"session_id\":\"x1\",\"cwd\":\"$P\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *AGENTS.md* && "$ctx" == *"Read _ai/INDEX.md before changing anything"* && "$ctx" == *"Still open from the last turn"* ]] && ok "Codex: names AGENTS.md, asks to read the index, and lists what is still open" || bad "Codex reminder" "$ctx"
out=$(hook gemini prompt "{\"session_id\":\"g9\",\"cwd\":\"$P\",\"prompt\":\"hi\"}")
[[ "$(j '["hookSpecificOutput"]["hookEventName"]' "$out")" == BeforeAgent ]] && ok "Gemini: BeforeAgent additionalContext" || bad "Gemini reminder" "$out"
out=$(hook agy prompt "{\"conversationId\":\"a1\",\"cwd\":\"$P\",\"initialNumSteps\":4,\"invocationNum\":1}")
out2=$(hook agy prompt "{\"conversationId\":\"a1\",\"cwd\":\"$P\",\"initialNumSteps\":4,\"invocationNum\":2}")
out3=$(hook agy prompt "{\"conversationId\":\"a1\",\"cwd\":\"$P\",\"initialNumSteps\":9,\"invocationNum\":1}")
if [[ "$out" == *injectSteps*"[ACF rules]"* && "$out2" == "{}" && "$out3" == *injectSteps* ]]; then ok "Antigravity: one reminder per turn, not one per model call"
else bad "agy reminder" "1=$out 2=$out2 3=$out3"; fi

echo "Antigravity's tab signal (agy's chat file is written while idle too, so the hook marks the tab)"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho "$* $TMUX_PANE" >> "%s/marks"\n' "$T" > "$HOME/.local/bin/agents"; chmod +x "$HOME/.local/bin/agents"
mkdir -p "$T/fakebin"; printf '#!/bin/sh\ncase "$*" in *@agy_chat*) echo "tmux $*" >> "%s/marks" ;; esac\n' "$T" > "$T/fakebin/tmux"; chmod +x "$T/fakebin/tmux"
PATH="$T/fakebin:$PATH" TMUX="/tmp/x,1,0" TMUX_PANE=%7 hook agy prompt "{\"conversationId\":\"m1\",\"cwd\":\"$P\",\"initialNumSteps\":1,\"invocationNum\":1}" >/dev/null
PATH="$T/fakebin:$PATH" TMUX="/tmp/x,1,0" TMUX_PANE=%7 hook agy stop "{\"conversationId\":\"m1\",\"cwd\":\"$P\",\"continuationActive\":false}" >/dev/null
[[ "$(cat "$T/marks" 2>/dev/null)" == $'--mark busy %7\ntmux set -p -t %7 @agy_chat m1\n--mark done %7' ]] \
  && ok "agy: busy before a model call (and its chat noted on the pane), done at the end of the turn" || bad "agy marks" "$(cat "$T/marks" 2>/dev/null)"
rm -f "$T/marks"
PATH="$T/fakebin:$PATH" TMUX="/tmp/x,1,0" TMUX_PANE=%7 hook agy prompt '{"conversationId":"../x;rm","initialNumSteps":1}' >/dev/null
[[ "$(cat "$T/marks" 2>/dev/null)" == "--mark busy %7" ]] && ok "agy: a malformed chat id is not written to the pane" || bad "agy chat id check" "$(cat "$T/marks" 2>/dev/null)"
rm -f "$T/marks"
TMUX="/tmp/x,1,0" TMUX_PANE=%7 AFC_RULES_SKIP=1 hook agy prompt '{}' >/dev/null
[[ "$(cat "$T/marks" 2>/dev/null)" == "--mark busy %7" ]] && ok "agy: the tab is marked even with the rules hook turned off" || bad "agy mark when skipped" "$(cat "$T/marks" 2>/dev/null)"
rm -f "$T/marks"
hook agy prompt '{}' >/dev/null
TMUX="/tmp/x,1,0" TMUX_PANE=%7 hook claude prompt "{\"session_id\":\"m2\",\"cwd\":\"$P\",\"prompt\":\"hi\"}" >/dev/null
[[ ! -e "$T/marks" ]] && ok "no mark outside tmux, and none for Claude (its own hooks mark it)" || bad "stray mark" "$(cat "$T/marks")"
printf '#!/bin/sh\nsleep 9\n' > "$HOME/.local/bin/agents"
s=$EPOCHSECONDS; out=$(TMUX="/tmp/x,1,0" TMUX_PANE=%7 hook agy prompt "{\"conversationId\":\"m3\",\"cwd\":\"$P\",\"initialNumSteps\":1,\"invocationNum\":1}")
(( EPOCHSECONDS - s < 8 )) && [[ "$out" == *injectSteps* && "$(cat "$T/err")" == *"tab mark skipped"* ]] \
  && ok "a hung mark times out after 5 s, says so, and the reminder still goes" || bad "agy mark timeout" "$((EPOCHSECONDS - s))s $out $(cat "$T/err")"
rm -f "$HOME/.local/bin/agents"

echo "Where it does nothing"
out=$(hook claude prompt "{\"session_id\":\"n1\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
[[ -z "$out" ]] && ok "a folder with no _ai/TOKENOPS.json: nothing added to the prompt" || bad "reminder outside TokenOps" "$out"
out=$(hook gemini stop "{\"session_id\":\"n1\",\"transcript_path\":\"$GM\",\"cwd\":\"$N\"}")
[[ "$out" == "{}" ]] && ok "...and nothing checked" || bad "check outside TokenOps" "$out"
mkdir -p "$P/sub/.git" "$P/sub/x"
out=$(hook claude prompt "{\"session_id\":\"n2\",\"cwd\":\"$P/sub/x\",\"prompt\":\"hi\"}")
[[ -z "$out" ]] && ok "a git repo of its own inside a TokenOps project is not under that project's rules" || bad "rules crossed a git root" "$out"
printf 'garbage\n{"type":\n' > "$T/broken.jsonl"
out=$(hook claude stop "{\"session_id\":\"b1\",\"transcript_path\":\"$T/broken.jsonl\",\"cwd\":\"$P\"}"); rc=$?
[[ $rc == 0 && -z "$out" ]] && ok "a broken chat file: exit 0, nothing sent back, no recap" || bad "broken chat file" "rc=$rc $out"
out=$(printf 'not json' | python3 -I "$RULES" hook gemini stop 2>/dev/null); rc=$?
[[ $rc == 0 && "$out" == "{}" ]] && ok "hook input that is not JSON: exit 0, an empty answer" || bad "bad hook input" "rc=$rc $out"
setmode report
out=$(hook claude stop "{\"session_id\":\"r1\",\"transcript_path\":\"$CL1\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
nodec "$out" && ok "rules report: nothing is sent back" || bad "report mode blocked" "$out"
setmode off
out=$(hook claude prompt "{\"session_id\":\"o1\",\"cwd\":\"$P\",\"prompt\":\"hi\"}")
[[ -z "$out" ]] && ok "rules off: no reminder either" || bad "off mode reminded" "$out"
setmode enforce

echo "check, install"
out=$(rules check claude "$CL1" 2>&1)
[[ "$out" == *"1 would be sent back"*fix-check* ]] && ok "afc-rules check: judges a chat turn by turn" || bad "check" "$out"
mkdir -p "$HOME/.claude" "$HOME/.gemini/config" "$HOME/.codex"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.local/bin/agents --mark done"}]}]}}\n' > "$HOME/.claude/settings.json"
printf '{"security":{"x":1}}\n' > "$HOME/.gemini/settings.json"
printf 'model = "m"\nnotify = ["agents", "--mark", "done"]\n\n[projects."/x"]\ntrust_level = "trusted"\n' > "$HOME/.codex/config.toml"
before=$(cat "$HOME/.claude/settings.json" "$HOME/.gemini/settings.json" "$HOME/.codex/config.toml" | md5sum)
out=$(rules install --dry-run 2>&1)
after=$(cat "$HOME/.claude/settings.json" "$HOME/.gemini/settings.json" "$HOME/.codex/config.toml" | md5sum)
[[ "$before" == "$after" && "$out" == *"would add"* ]] && ok "install --dry-run says what it would add and changes nothing" || bad "dry run changed files" "$out"
rules install >/dev/null 2>&1
c=$(cat "$HOME/.claude/settings.json")
if jq -e '[.hooks.Stop[].hooks[].command] | (any(test("agents --mark")) and any(test("afc-rules hook claude stop")))' <<< "$c" >/dev/null \
   && jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | test("afc-rules hook claude prompt")' <<< "$c" >/dev/null; then ok "install: Claude gets both hooks, its own agents --mark hook stays"
else bad "Claude settings after install" "$c"; fi
jq -e '.security.x == 1 and (.hooks.AfterAgent[0].hooks[0].command | test("hook gemini stop")) and .hooks.AfterAgent[0].hooks[0].timeout == 30000' "$HOME/.gemini/settings.json" >/dev/null \
  && ok "install: Gemini gets BeforeAgent/AfterAgent (timeouts in ms); its other settings stay" || bad "Gemini settings" "$(cat "$HOME/.gemini/settings.json")"
jq -e '."acf-rules".Stop[0].command | test("hook agy stop")' "$HOME/.gemini/config/hooks.json" >/dev/null && ok "install: Antigravity gets a named hook in ~/.gemini/config/hooks.json" || bad "agy hooks.json" "$(cat "$HOME/.gemini/config/hooks.json" 2>&1)"
if python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); assert d["hooks"]["Stop"][0]["hooks"][0]["command"].endswith("hook codex stop"); assert d["projects"]["/x"]["trust_level"]=="trusted"; assert d["notify"][0]=="agents"' "$HOME/.codex/config.toml" 2>/dev/null
then ok "install: Codex's config.toml gets [[hooks.*]] tables and stays valid TOML with its other keys"; else bad "Codex config" "$(cat "$HOME/.codex/config.toml")"; fi
out=$(rules install 2>&1)
[[ "$out" == *"already has the hooks"* && $(grep -c 'afc-rules hook' "$HOME/.claude/settings.json") == 2 ]] && ok "install again: nothing doubled" || bad "second install" "$out"
rules install --remove >/dev/null 2>&1
if ! grep -q 'afc-rules' "$HOME/.claude/settings.json" "$HOME/.gemini/settings.json" "$HOME/.codex/config.toml" "$HOME/.gemini/config/hooks.json" \
   && grep -q 'agents --mark' "$HOME/.claude/settings.json" && python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$HOME/.codex/config.toml"; then ok "install --remove takes out exactly what install added"
else bad "remove left something" "$(grep -l afc-rules "$HOME"/.claude/settings.json "$HOME"/.gemini/settings.json "$HOME"/.codex/config.toml 2>&1)"; fi
ln -sf "$HOME/.claude/settings.json" "$T/linked-settings.json"
mkdir -p "$T/acct"; ln -s "$HOME/.claude/settings.json" "$T/acct/settings.json"
rules install >/dev/null 2>&1
[[ -L "$T/acct/settings.json" ]] && grep -q 'afc-rules' "$T/acct/settings.json" && ok "an account's settings.json that links to the main one stays a link and sees the hooks" || bad "link broken"

echo "memory"
enc=$(printf '%s' "$(readlink -f "$P")" | sed 's#[^A-Za-z0-9]#-#g'); OLD="$HOME/.claude/projects/$enc/memory"
mkdir -p "$OLD"; printf -- '- [a](a.md)\n' > "$OLD/MEMORY.md"; printf 'fact a\n' > "$OLD/a.md"
mkdir -p "$P/.claude"; printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$P/.claude/settings.local.json"
out=$(rules memory --dry-run "$P" 2>&1)
[[ "$out" == *"would copy 2 memory file(s)"* && -d "$OLD" && ! -L "$OLD" && ! -e "$P/_ai/memory" ]] && ok "memory --dry-run: says what it would do, changes nothing" || bad "memory dry run" "$out"
out=$(rules memory "$P" 2>&1)
if [[ -f "$P/_ai/memory/a.md" && -f "$P/_ai/memory/MEMORY.md" && -L "$OLD" && "$(readlink -f "$OLD")" == "$(readlink -f "$P/_ai/memory")" ]] && ls -d "$OLD".before-project-* >/dev/null 2>&1; then
  ok "memory: Claude's files copied into _ai/memory, the old folder kept as a backup and replaced by a link"; else bad "memory move" "$out"; fi
jq -e --arg d "$(readlink -f "$P")/_ai/memory" '.autoMemoryDirectory == $d and .permissions.allow[0] == "Bash(ls:*)"' "$P/.claude/settings.local.json" >/dev/null \
  && ok "memory: autoMemoryDirectory (absolute) set in .claude/settings.local.json; its other settings stay" || bad "settings.local.json" "$(cat "$P/.claude/settings.local.json")"
out=$(rules memory "$P" 2>&1)
[[ "$out" == *"already in the project"* ]] && ok "memory again: nothing to do" || bad "memory second run" "$out"

echo "modes (Doctrine, Mental Model, STE-Lite, DO-178C-Lite, Search Hygiene, Memory Summary, SITREP)"
rm -f "$AGENTS_SETTINGS"
out=$(rules mode --cwd "$N" 2>&1)
[[ "$out" == *"Doctrine:"*"off"* && "$out" == *"Mental model:"*"off"* && "$out" == *"STE-Lite:"*"on"* && "$out" == *"DO-178C-Lite:"*"on"* && "$out" == *"Search hygiene:"*"off"* && "$out" == *"Memory summary:"*"off"* && "$out" == *"SITREP footer:"*"off"* ]] \
  && ok "afc-rules mode defaults CLS (STE-Lite) and SAS (DO-178C-Lite) ON and the other 5 modes OFF" || bad "mode default status" "$out"

rules mode --global doctrine mdmp >/dev/null
rules mode --global model rca >/dev/null
rules mode ste on >/dev/null
rules mode do178c on >/dev/null
rules mode hygiene on >/dev/null
out=$(hook claude prompt "{\"session_id\":\"m1\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
if [[ "$ctx" == *"[ACF mode]"* && "$ctx" == *"Doctrine [MDMP]"* && "$ctx" == *"Root Cause Analysis"* && "$ctx" == *"ASD-STE100"* && "$ctx" == *"DO-178C-Lite"* && "$ctx" == *"Search Hygiene:"* ]]; then
  ok "prompt hook injects Doctrine, Mental Model, STE-Lite, DO-178C-Lite & Search Hygiene outside TokenOps"
else bad "guidance nudge missing parts" "$ctx"; fi

# Hybrid memory: SUMMARY.md injected once on turn 1 when memory-summary is on, skipped on turn 2+
mkdir -p "$N/logs/acf"
printf '# Project Memory Summary: plain\n- [11-25 14:00] `agy/others` `agy:abc123` — Fix login bug (3u/5t)\n' > "$N/logs/acf/SUMMARY.md"
rules mode summary on >/dev/null
out=$(hook claude prompt "{\"session_id\":\"mem1\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
out2=$(hook claude prompt "{\"session_id\":\"mem1\",\"cwd\":\"$N\",\"prompt\":\"next\"}")
ctx2=$(j '["hookSpecificOutput"]["additionalContext"]' "$out2")
[[ "$ctx" == *"[ACF memory]"* && "$ctx" == *"agy:abc123"* && "$ctx2" != *"[ACF memory]"* ]] \
  && ok "memory-summary injects SUMMARY.md once on turn 1 across providers and skips turn 2+" || bad "memory-summary turn-1/2" "$ctx || $ctx2"
rules mode summary off >/dev/null
rules mode hygiene off >/dev/null

# SITREP footer: dynamically includes active Doctrine (D), Mental Model (M), and doctrine phases in red/green diff fence
rules mode sitrep on >/dev/null
out=$(hook claude prompt "{\"session_id\":\"sit1\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"SITREP Footer:"* && "$ctx" == *"\`\`\`diff"* && "$ctx" != *"┌───"* && "$ctx" == *"- You:"* && "$ctx" == *"+ SITREP · D:MDMP · M:RCA · <phase>"* && "$ctx" == *"P5 ASSESS"* ]] \
  && ok "sitrep mode injects red/green diff You:/SITREP footer with blank line naming active D & M and MDMP phases" || bad "sitrep mdmp+rca" "$ctx"

rules mode --cwd "$N" --project doctrine f3ead >/dev/null
out=$(hook claude prompt "{\"session_id\":\"sit2\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"+ SITREP · D:F3EAD · M:RCA · <phase>"* && "$ctx" == *"EXPLOIT"* ]] \
  && ok "sitrep mode switches phases dynamically when project Doctrine changes to F3EAD" || bad "sitrep f3ead" "$ctx"

rules mode --cwd "$N" --project off doctrine >/dev/null
out=$(hook claude prompt "{\"session_id\":\"sit3\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"+ SITREP · D:off · M:RCA · Done:"* && "$ctx" != *"<phase>"* ]] \
  && ok "sitrep mode omits <phase> and shows D:off when Doctrine is off" || bad "sitrep d-off" "$ctx"
rules mode --cwd "$N" --project delete doctrine >/dev/null
rules mode sitrep off >/dev/null

rules mode --cwd "$N" --project doctrine ooda >/dev/null
out=$(hook claude prompt "{\"session_id\":\"m3\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"Doctrine [OODA]"* && "$ctx" != *"Doctrine [MDMP]"* ]] \
  && ok "project Doctrine overrides global Doctrine" || bad "project override" "$ctx"

rules mode --cwd "$N" --project off doctrine >/dev/null
out=$(hook claude prompt "{\"session_id\":\"m4\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" != *"Doctrine ["* && "$ctx" == *"Root Cause Analysis"* ]] \
  && ok "afc-rules mode off doctrine switches off Doctrine in project while keeping Mental Model" || bad "off doctrine" "$ctx"

rules mode --cwd "$N" --project delete doctrine >/dev/null
out=$(hook claude prompt "{\"session_id\":\"m5\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"Doctrine [MDMP]"* ]] \
  && ok "afc-rules mode delete doctrine removes project override and falls back to global" || bad "delete doctrine" "$ctx"

out=$(hook claude prompt "{\"session_id\":\"m6\",\"cwd\":\"$P\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"[ACF rules]"* && "$ctx" == *"[ACF mode]"* ]] \
  && ok "inside TokenOps project, [ACF rules] and [ACF mode] combine cleanly" || bad "combined nudge" "$ctx"

setmode off
rules mode --global doctrine mdmp >/dev/null
out=$(hook claude prompt "{\"session_id\":\"m2\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"Doctrine [MDMP]"* && "$ctx" != *"[ACF rules]"* ]] \
  && ok "rules off still injects active Doctrine/Model/style modes without TokenOps rules" || bad "modes with rules off" "$ctx"
setmode enforce

rules mode --cwd "$N" off --all >/dev/null
out=$(hook claude prompt "{\"session_id\":\"m7\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
[[ -z "$out" ]] && ok "afc-rules mode off --all silences all guidance modes cleanly" || bad "off --all left output" "$out"

echo "Copilot, and afc-rules verify (is each pane's agent really sent the modes?)"
rules mode --global doctrine mdmp >/dev/null; rules mode ste on >/dev/null
rules mode --cwd "$N" --project delete doctrine >/dev/null   # "off --all" above left the project's own "off"
out=$(hook copilot prompt "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"cp1\",\"cwd\":\"$N\",\"prompt\":\"hi\"}")
ctx=$(j '["additionalContext"]' "$out")
[[ "$ctx" == *"Doctrine [MDMP]"* && "$ctx" == *"ASD-STE100"* && "$out" != *hookSpecificOutput* ]] \
  && ok "copilot prompt hook: a top-level additionalContext (the form Copilot reads; it ignores hookSpecificOutput)" || bad "copilot prompt" "$out"
out=$(hook copilot stop "{\"session_id\":\"cp1\",\"cwd\":\"$P\"}")
[[ -z "$out" ]] && ok "copilot stop: prints nothing (Copilot has no turn-end check)" || bad "copilot stop" "$out"
mkdir -p "$HOME/.copilot"; rm -f "$HOME/.copilot/hooks/afc-rules.json"
rules install >/dev/null 2>&1
jq -e '.hooks.UserPromptSubmit[0].bash | test("afc-rules hook copilot prompt")' "$HOME/.copilot/hooks/afc-rules.json" >/dev/null \
  && [[ "$(rules install 2>&1)" == *"Copilot: "*"already has the hook"* ]] \
  && ok "install: Copilot gets ~/.copilot/hooks/afc-rules.json, once" || bad "copilot install" "$(cat "$HOME/.copilot/hooks/afc-rules.json" 2>&1)"
rules install --remove >/dev/null 2>&1
[[ ! -e "$HOME/.copilot/hooks/afc-rules.json" ]] && ok "install --remove: Copilot's hook file goes" || bad "copilot remove"
rules install >/dev/null 2>&1; rm -f "$HOME/.copilot/hooks/afc-rules.json"   # Claude hooked, Copilot not

if ! command -v tmux >/dev/null; then echo "  skip  verify: no tmux on the PATH"; else
  mkdir -p "$T/bin"
  for a in copilot claude; do printf '#!/bin/sh\nsleep 120\n' > "$T/bin/$a"; chmod +x "$T/bin/$a"; done
  tm() { tmux -L "$AGENTS_SOCK" -f /dev/null "$@"; }
  tm new-session -d -s v -n fleet -c "$N" "$T/bin/copilot"
  tm split-window -t v -c "$N" "$T/bin/claude"
  cp_pane=$(tm list-panes -t v -F '#{pane_id}' | head -1); sock=$(tm display -p '#{socket_path}')
  tm set -p -t "$cp_pane" @doctrine ooda
  out=$(rules verify 2>&1); rc=$?
  [[ $rc == 1 && "$out" == *"$cp_pane"*": copilot"*"should get: doctrine=ooda STE"*"✗ gets nothing: copilot has no afc-rules prompt hook"* \
     && "$out" == *": claude"*"should get: doctrine=mdmp STE"$'\n'*"? no prompt seen"* ]] \
    && ok "verify: finds each pane's agent, its own modes (pane doctrine wins), ✗ for an agent without the hook" || bad "verify before" "$out"
  rules install >/dev/null 2>&1
  printf '{"session_id":"cp2","cwd":"%s","prompt":"hi"}' "$N" | TMUX="$sock,1,0" TMUX_PANE="$cp_pane" python3 -I "$RULES" hook copilot prompt >/dev/null
  out=$(rules verify 2>&1); rc=$?
  [[ $rc == 0 && "$out" == *": copilot"*"✓ last prompt ("*") got: doctrine=ooda STE"* ]] \
    && ok "verify: ✓ once a prompt in that pane really carried those modes (the hook marks the pane)" || bad "verify after" "$out"
  rules mode ste off >/dev/null
  out=$(rules verify 2>&1)
  [[ "$out" == *": copilot"*"should get: doctrine=ooda"$'\n'*"△ last prompt ("*") got: doctrine=ooda STE;"* ]] \
    && ok "verify: △ when the settings changed after the last prompt" || bad "verify changed" "$out"
  tm kill-server 2>/dev/null
fi

echo "Core CLS & SAS Stop-hook enforcement (plain repo, no TokenOps)"
rm -f "$AGENTS_SETTINGS"    # empty settings -> core defaults: rules=enforce, style-ste=on, code-do178c=on
G="$T/plain-git"; mkdir -p "$G"
git -C "$G" init -q
git -C "$G" config user.email test@example.com
git -C "$G" config user.name test
printf 'def ok():\n    return 1\n' > "$G/app.py"
git -C "$G" add app.py && git -C "$G" commit -q -m init

mk_chat() {
  python3 - "$1" "$G" "$2" "$3" "$4" <<'PY'
import json, sys
path, cwd, reply, edit_file, verify_cmd = sys.argv[1:]
lines = [
    {"type": "user", "cwd": cwd, "timestamp": "2026-11-25T12:00:00.000Z", "message": {"role": "user", "content": "implement change"}},
]
if edit_file:
    lines.append({"type": "assistant", "timestamp": "2026-11-25T12:00:01.000Z", "message": {"role": "assistant", "model": "m", "content": [{"type": "tool_use", "name": "Edit", "input": {"file_path": edit_file, "old_string": "a", "new_string": "b"}}]}})
if verify_cmd:
    lines.append({"type": "assistant", "timestamp": "2026-11-25T12:00:02.000Z", "message": {"role": "assistant", "model": "m", "content": [{"type": "tool_use", "name": "Bash", "input": {"command": verify_cmd}}]}})
if reply:
    lines.append({"type": "assistant", "timestamp": "2026-11-25T12:00:03.000Z", "message": {"role": "assistant", "model": "m", "content": [{"type": "text", "text": reply}]}})
with open(path, "w") as f:
    for rec in lines:
        f.write(json.dumps(rec) + "\n")
PY
}

# 1. CLS filler preamble -> blocked
C_FILL="$T/cls-filler.jsonl"
mk_chat "$C_FILL" "Certainly! Here is what you asked for." "" ""
out=$(hook claude stop "{\"session_id\":\"cls1\",\"transcript_path\":\"$C_FILL\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
[[ "$(j '["decision"]' "$out")" == block && "$out" == *"CLS response opens with conversational filler"* ]] \
  && ok "CLS hard gate: filler preamble is sent back on plain repo" || bad "cls-filler" "$out"

# 2. CLS wide ASCII diagram (>70 chars) -> blocked once, let through on stop_hook_active=true
C_WIDE="$T/cls-wide.jsonl"
WIDE_DIAG=$(printf '```\n+--------------------------------------------------------------------------+\n| too wide                                                                 |\n+--------------------------------------------------------------------------+\n```\nDone.')
mk_chat "$C_WIDE" "$WIDE_DIAG" "" ""
out=$(hook claude stop "{\"session_id\":\"cls2\",\"transcript_path\":\"$C_WIDE\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
[[ "$(j '["decision"]' "$out")" == block && "$out" == *"limit <=70"* ]] \
  && ok "CLS hard gate: ASCII diagram >70 chars is sent back" || bad "cls-diagram-width" "$out"
out2=$(hook claude stop "{\"session_id\":\"cls2\",\"transcript_path\":\"$C_WIDE\",\"cwd\":\"$G\",\"stop_hook_active\":true}")
nodec "$out2" && [[ "$out2" == *"still open"* ]] \
  && ok "CLS hard gate: second stop (stop_hook_active) is let through once per turn" || bad "cls2 retry" "$out2"

# 3. CLS clean diagram (<=70 chars) + direct short sentences -> allowed with checkmark
C_OK="$T/cls-ok.jsonl"
OK_DIAG=$(printf '```\nClient --> Hook --> Check\n```\nHook validates edits. Check runs on stop.')
mk_chat "$C_OK" "$OK_DIAG" "" ""
out=$(hook claude stop "{\"session_id\":\"cls3\",\"transcript_path\":\"$C_OK\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"ACF rules ✓"* ]] \
  && ok "CLS clean reply with <=70-char diagram passes with ✓" || bad "cls-ok" "$out"

# 3b. CLS no false positives: ```python code block with box chars >70 cols & "Absolutely not" opening
C_NOFP="$T/cls-nofp.jsonl"
NOFP_TXT=$(printf 'Absolutely not — code blocks are not diagrams.\n```python\nDIAGRAM_RE = re.compile(r"[┌┐└┘├┤┬┴┼│─▼▲►◄═║╔╗╚╝]|├──|└──|some_very_long_identifier_past_seventy_cols")\n```')
mk_chat "$C_NOFP" "$NOFP_TXT" "" ""
out=$(hook claude stop "{\"session_id\":\"cls3b\",\"transcript_path\":\"$C_NOFP\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"ACF rules ✓"* ]] \
  && ok "CLS avoids false positives on \`\`\`python blocks >70 cols and 'Absolutely not'" || bad "cls-nofp" "$out"

# 3c. CLS ignores You:/SITREP footer lines (plain and fenced ```diff) when measuring prose sentence length
C_SIT="$T/cls-sitrep.jsonl"
SIT_TXT=$(printf 'Done here. All checks passed. Zero errors found. Ready now.\n\n```diff\n- You: verify that a very long user prompt echo and sitrep footer do not trigger the CLS sentence length warning\n+ SITREP · D:MDMP · M:OODA · P5 ASSESS · Done: sandbox main = 29be943 deployed nothing unpushed and every single test case passed cleanly · Open: reorder/live need cart+catalog migration · Next: your call\n```')
mk_chat "$C_SIT" "$SIT_TXT" "" ""
out=$(hook claude stop "{\"session_id\":\"cls3c\",\"transcript_path\":\"$C_SIT\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"ACF rules ✓"* ]] \
  && ok "CLS ignores You:/SITREP diff footer during prose sentence-length & diagram checks" || bad "cls-sitrep" "$out"

# 4. CLS soft note: long prose sentences -> allowed with △ note
C_LONG="$T/cls-long.jsonl"
LONG_PROSE="This particular sentence deliberately contains far more than twenty four separate words in order to verify that the soft sentence length detector notices overly verbose technical prose cleanly. Another very long sentence also stretches well beyond twenty four words to ensure that the ratio crosses thirty five percent across the whole sample reply cleanly. Here is a third overly long sentence with plenty of extra words added so that more than half of the sentences in this paragraph exceed the threshold. Short end here."
mk_chat "$C_LONG" "$LONG_PROSE" "" ""
out=$(hook claude stop "{\"session_id\":\"cls4\",\"transcript_path\":\"$C_LONG\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"ACF rules △"* && "$out" == *"CLS sentence length"* ]] \
  && ok "CLS soft gate: verbose prose emits △ note without blocking" || bad "cls-sentence-len" "$out"

# 5. SAS hard gate: edited app.py without running any verification command -> blocked
C_UNVER="$T/sas-unverified.jsonl"
mk_chat "$C_UNVER" "Updated app.py." "$G/app.py" ""
out=$(hook claude stop "{\"session_id\":\"sas1\",\"transcript_path\":\"$C_UNVER\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
[[ "$(j '["decision"]' "$out")" == block && "$out" == *"SAS unverified code edit"* ]] \
  && ok "SAS hard gate: code edit without post-edit test/syntax check is sent back" || bad "sas-verify" "$out"

# 6. SAS hard gate: added bare except: and subprocess.run without timeout= -> blocked even with test cmd
cat > "$G/app.py" <<'EOF'
import subprocess
def ok():
    try:
        subprocess.run(["echo", "hi"])
    except:
        pass
    return 1
EOF
C_BADDIFF="$T/sas-baddiff.jsonl"
mk_chat "$C_BADDIFF" "Updated and tested app.py." "$G/app.py" "python3 -m py_compile app.py"
out=$(hook claude stop "{\"session_id\":\"sas2\",\"transcript_path\":\"$C_BADDIFF\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
[[ "$(j '["decision"]' "$out")" == block && "$out" == *"SAS silent error handling"* && "$out" == *"missing timeout="* ]] \
  && ok "SAS hard gate: diff catches bare except: and subprocess.run missing timeout=" || bad "sas-diff" "$out"

# 7. SAS clean diff + explicit verification command -> passes with ✓ and verified
cat > "$G/app.py" <<'EOF'
import subprocess
def ok():
    try:
        subprocess.run(["echo", "hi"], timeout=5, check=True)
    except (OSError, subprocess.SubprocessError) as e:
        raise RuntimeError(str(e))
    return 1
EOF
C_GOODSAS="$T/sas-good.jsonl"
mk_chat "$C_GOODSAS" "Updated app.py with timeout and explicit error handling." "$G/app.py" "python3 -m py_compile app.py"
out=$(hook claude stop "{\"session_id\":\"sas3\",\"transcript_path\":\"$C_GOODSAS\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"ACF rules ✓"* && "$out" == *"verified"* ]] \
  && ok "SAS clean diff + py_compile verification passes with ✓" || bad "sas-good" "$out"

# 7b. Multi-line subprocess.run where only line 1 changes and timeout=5 is on an unchanged next line -> no false positive
cat > "$G/multi.py" <<'EOF'
import subprocess
def run():
    return subprocess.run(["echo", "a"],
                          capture_output=True, timeout=5)
EOF
git -C "$G" add multi.py && git -C "$G" commit -q -m multi
sed -i 's/"a"/"b"/' "$G/multi.py"
C_MULTI="$T/sas-multi.jsonl"
mk_chat "$C_MULTI" "Updated multi.py arg." "$G/multi.py" "python3 -m py_compile multi.py"
out=$(hook claude stop "{\"session_id\":\"sas3b\",\"transcript_path\":\"$C_MULTI\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"ACF rules ✓"* ]] \
  && ok "SAS multi-line diff reads unchanged continuation lines for timeout= (no false positive)" || bad "sas-multi" "$out"

# 8. Cross-provider (Gemini) deny on plain repo + offline afc-rules check
GM_PLAIN="$T/gem-plain.json"
python3 - "$GM_PLAIN" "$G/app.py" <<'PY'
import json, sys
out_path, target = sys.argv[1:]
doc = {"sessionId": "gp1", "startTime": "2026-11-25T12:00:00Z", "messages": [
    {"id": "1", "type": "user", "timestamp": "2026-11-25T12:01:00Z", "content": [{"text": "edit app"}]},
    {"id": "2", "type": "gemini", "timestamp": "2026-11-25T12:01:05Z", "content": [{"text": "Certainly! Done."}],
     "toolCalls": [{"name": "replace", "args": {"file_path": target, "old_string": "1", "new_string": "2"}}]},
]}
open(out_path, "w").write(json.dumps(doc))
PY
out=$(hook gemini stop "{\"session_id\":\"gp1\",\"transcript_path\":\"$GM_PLAIN\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
[[ "$(j '["decision"]' "$out")" == deny && "$out" == *"SAS unverified code edit"* && "$out" == *"CLS response opens with conversational filler"* ]] \
  && ok "Gemini Stop hook enforces both CLS and SAS with decision=deny on plain repo" || bad "gemini-plain" "$out"

chk_out=$(rules check claude "$C_UNVER" --cwd "$G" 2>&1)
[[ "$chk_out" == *"1 would be sent back"* && "$chk_out" == *"sas-verify"* ]] \
  && ok "afc-rules check audits CLS/SAS on plain non-TokenOps repos too" || bad "check-plain" "$chk_out"

# 9. Decoupled from TokenOps `rules off`: active CLS/SAS still enforce when `rules off`, non-blocking under `rules report`
printf 'rules off\nstyle-ste on\ncode-do178c on\n' > "$AGENTS_SETTINGS"
out=$(hook claude stop "{\"session_id\":\"dec1\",\"transcript_path\":\"$C_UNVER\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
[[ "$(j '["decision"]' "$out")" == block && "$out" == *"SAS unverified code edit"* ]] \
  && ok "rules off (TokenOps off) still enforces active CLS/SAS on Stop" || bad "decoupled rules off" "$out"
printf 'rules report\nstyle-ste on\ncode-do178c on\n' > "$AGENTS_SETTINGS"
out=$(hook claude stop "{\"session_id\":\"dec2\",\"transcript_path\":\"$C_UNVER\",\"cwd\":\"$G\",\"stop_hook_active\":false}")
nodec "$out" && [[ "$out" == *"still open"* ]] \
  && ok "rules report makes CLS/SAS non-blocking (report-only)" || bad "decoupled rules report" "$out"

echo
echo "$pass passed, $fail failed"
(( KEEP )) && echo "kept: $T"
(( fail == 0 ))
