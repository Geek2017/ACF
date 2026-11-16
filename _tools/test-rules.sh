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
export HOME="$T/home" AFC_RULES_STATE="$T/state" AGENTS_SETTINGS="$T/settings" AGENTS_SOCK="acfrules-none-$$"
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CLI_HOME
mkdir -p "$HOME" "$AFC_RULES_STATE"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | head -c 600; }
setmode() { printf 'rules %s\n' "$1" > "$AGENTS_SETTINGS"; }
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
if [[ "$(j '["decision"]' "$out")" == block && "$out" == *FIX-0001* && "$out" == *"[ACF rule check]"* && "$out" == *check-fixes.py\ --path\ src/app.js* ]]; then ok "Claude: a protected file changed without a fix check is sent back, with what to run"
else bad "Claude: no block for the unchecked protected file" "$out $(cat "$T/err")"; fi
if [[ "$out" == *"$P/CLAUDE.md"* ]]; then ok "the message names the project's own rule file by its full path"; else bad "no local rule file path in the message" "$out"; fi
grep -q $'\thard\tfix-check\t' "$P/logs/acf/rules.log" 2>/dev/null && ok "the finding is a line in <project>/logs/acf/rules.log" || bad "no line in rules.log"
out=$(hook claude stop "{\"session_id\":\"c1\",\"transcript_path\":\"$CL1\",\"cwd\":\"$P\",\"stop_hook_active\":true}")
[[ -z "$out" ]] && ok "the turn's second stop (stop_hook_active) is let through: once per turn" || bad "sent back twice in one turn" "$out"
[[ $(grep -c $'\tfix-check\t' "$P/logs/acf/rules.log") == 1 ]] && ok "a finding is logged once per turn, however often the turn stops" || bad "logged twice" "$(cat "$P/logs/acf/rules.log")"
out=$(hook claude stop "{\"session_id\":\"c2\",\"transcript_path\":\"$CL2\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
[[ -z "$out" ]] && ok "Claude: check-fixes.py --path before the edit: let through" || bad "blocked although checked" "$out"
out=$(hook claude stop "{\"session_id\":\"c3\",\"transcript_path\":\"$CL3\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
[[ -z "$out" ]] && ok "Claude: reading _ai/FIXES.md (sed, inside a cd \"...\" && command) counts as the check" || bad "blocked although FIXES.md was read" "$out"
out=$(hook claude stop "{\"session_id\":\"c4\",\"transcript_path\":\"$CL4\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
log=$(grep -E $'\t(outside|rule-files)\t' "$P/logs/acf/rules.log")
if [[ -z "$out" && "$log" == *outside*memory* && "$log" == *rule-files*AGENTS.md* && "$log" != *scratch-ok* ]]; then ok "soft rules only note: Claude's memory folder, a generated rule file (temp files are fine)"
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
[[ -z "$out" ]] && ok "Codex: sed of _ai/INDEX.md inside an exec cell counts as reading it" || bad "Codex blocked although the index was read" "$out"
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
[[ $rc == 0 && -z "$out" ]] && ok "a broken chat file: exit 0, nothing sent back" || bad "broken chat file" "rc=$rc $out"
out=$(printf 'not json' | python3 -I "$RULES" hook gemini stop 2>/dev/null); rc=$?
[[ $rc == 0 && "$out" == "{}" ]] && ok "hook input that is not JSON: exit 0, an empty answer" || bad "bad hook input" "rc=$rc $out"
setmode report
out=$(hook claude stop "{\"session_id\":\"r1\",\"transcript_path\":\"$CL1\",\"cwd\":\"$P\",\"stop_hook_active\":false}")
[[ -z "$out" ]] && ok "rules report: nothing is sent back" || bad "report mode blocked" "$out"
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

echo
echo "$pass passed, $fail failed"
(( KEEP )) && echo "kept: $T"
(( fail == 0 ))
