#!/usr/bin/env bash
# test-collab.sh: tests for agent names, @name context and /collab (lib/afc/collab.py, bin/afc-collab,
# and the prompt hook in bin/afc-rules). Touches nothing of yours: a tmux server of its own on its
# own socket, made-up agents (small scripts named claude, codex, gemini that only write down what is
# typed into them), a stand-in home folder and settings, all under one temp folder removed afterwards.
#
#   bash _tools/test-collab.sh           test this folder's bin/ and lib/
#   bash _tools/test-collab.sh --keep    leave the temp folder for a look
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0
[[ "${1:-}" == --keep ]] && KEEP=1
T=$(mktemp -d /tmp/acf-collab-test.XXXXXX)
SOCK="acfcollab-$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null; (( KEEP )) || rm -rf "$T"; }
trap cleanup EXIT
export HOME="$T/home" XDG_RUNTIME_DIR="$T/rt" AFC_RULES_STATE="$T/state" AGENTS_SETTINGS="$T/settings" \
       AGENTS_PROJECT_MODES="$T/modes.json" AGENTS_SOCK="$SOCK" AGENTS_ACCOUNTS="$T/accounts" \
       AGENTS_ACCOUNTS_GEMINI="$T/accounts-gemini" AGENTS_ACCOUNTS_COPILOT="$T/accounts-copilot"
unset TMUX TMUX_PANE CLAUDECODE CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CLI_HOME
for _v in $(compgen -e | grep -E '^(ANTIGRAVITY_|CODEX_|OPENCODE_|COPILOT_)' || true); do unset "$_v"; done
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$AFC_RULES_STATE" "$T/fake" "$T/projA" "$T/projB"
printf 'rules off\nstyle-ste off\ncode-do178c off\n' > "$AGENTS_SETTINGS"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | head -c 700; }
tm() { tmux -L "$SOCK" "$@"; }

# made-up agents: print a marker, then write down every line typed into them
for t in claude codex gemini; do
  cat > "$T/fake/$t" <<EOF
#!/usr/bin/env bash
echo "SCREEN-\$1 \$(printf 'x%.0s' {1..10})"
while IFS= read -r l; do printf '%s\n' "\$l" >> "$T/in-\$1"; done
EOF
  chmod +x "$T/fake/$t"
done
tm -f /dev/null new-session -d -s agents -n A -x 200 -y 50 -c "$T/projA" "$T/fake/claude A"
A=$(tm display -p -t agents:A '#{pane_id}')
B=$(tm split-window -P -F '#{pane_id}' -t "$A" -c "$T/projA" "$T/fake/codex B")
C=$(tm new-window -P -F '#{pane_id}' -n B -c "$T/projB" "$T/fake/gemini C")
tm set -w -t agents:A @project ProjA; tm set -w -t agents:B @project ProjB
SP=$(tm display -p '#{socket_path}')
inpane() { local p=$1; shift; TMUX="$SP,1,0" TMUX_PANE="$p" "$@"; }
collab() { python3 -I "$HERE/bin/afc-collab" "$@"; }
hook() { local tool=$1 pane=$2 prompt=$3
  python3 -I -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "cwd": sys.argv[2], "session_id": "s1"}))' \
    "$prompt" "$T/projA" | inpane "$pane" python3 -I "$HERE/bin/afc-rules" hook "$tool" prompt 2>"$T/err"; }
j() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[2] or "{}"); print(eval("d"+sys.argv[1]) if sys.argv[1] else d)' "$1" "$2" 2>/dev/null; }
name_of() { tm display -p -t "$1" '#{@agent}'; }
sleep 0.5

echo "Names"
inpane "$A" collab name --all >/dev/null
na=$(name_of "$A"); nb=$(name_of "$B"); nc=$(name_of "$C")
[[ "$na" =~ ^[a-z][a-z0-9]{1,11}$ && "$nb" =~ ^[a-z][a-z0-9]{1,11}$ && "$nc" =~ ^[a-z][a-z0-9]{1,11}$ ]] \
  && ok "every pane gets a short name ($na $nb $nc)" || bad "names" "$na|$nb|$nc"
[[ "$na" != "$nb" && "$nb" != "$nc" && "$na" != "$nc" ]] && ok "names are unique" || bad "unique" "$na $nb $nc"
inpane "$A" collab name --all >/dev/null
[[ "$(name_of "$A")$(name_of "$B")" == "$na$nb" ]] && ok "naming again keeps the names" || bad "stable"
D=$(tm split-window -P -F '#{pane_id}' -t "$C" -c "$T/projB" "sleep 60")
out=$(collab name "$D"); [[ -n "$out" && "$out" == "$(name_of "$D")" ]] && ok "name PANE names one pane and prints it" || bad "name one" "$out"
python3 -I - "$HERE/lib/afc" <<'PY' && ok "past the word list, names get a number and stay unique" || bad "name fallback"
import random, sys
sys.path.insert(0, sys.argv[1])
import collab
used = set(collab.NAMES) | collab.RESERVED
n = collab.pick_name(used, random.Random(1))
assert n not in used and collab.NAME_RE.match(n), n
PY
out=$(collab list); [[ "$out" == *"@$na"*"Claude"*"ProjA"* && "$out" == *"@$nb"*"Codex"* && "$out" == *"@$nc"*"Gemini"* ]] \
  && ok "list shows each agent's name, tool and tab" || bad "list" "$out"

echo "@name context"
out=$(hook claude "$A" "what is @$nb doing? and mail me@$nc.com")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"SCREEN-B"* && "$ctx" == *"@$nb"*"Codex"* ]] && ok "@name hands that agent's screen to this one" || bad "mention" "$out $(cat "$T/err")"
[[ "$ctx" != *"SCREEN-C"* ]] && ok "an e-mail address is not an @name" || bad "email" "$ctx"
out=$(hook claude "$A" "look at @$nc please"); ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" != *"SCREEN-C"* && "$ctx" == *"agent of another project"* ]] \
  && ok "@name of another project's agent shares no screen and says why" || bad "other project mention" "$out"
out=$(hook claude "$A" "ask @nobody and @$na"); [[ -z "$out" ]] && ok "an unknown name or its own name adds nothing" || bad "no-op mention" "$out"
out=$(hook claude "$A" "plain prompt"); [[ -z "$out" ]] && ok "a plain prompt with collab off adds nothing" || bad "plain" "$out"

echo "/collab"
out=$(inpane "$A" collab send "@$nb" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"collab mode is off"* ]] && ok "send is refused while collab is off" || bad "send off" "rc=$rc $out"
out=$(hook claude "$A" "/collab")
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"Collab on in tab ProjA"*"@$nb"* ]] \
  && ok "/collab is answered by the hook (no model turn) and names the tab's agents" || bad "/collab on" "$out $(cat "$T/err")"
[[ "$(tm display -p -t "$A" '#{@collab}')" == on && -z "$(tm display -p -t "$C" '#{@collab}')" ]] \
  && ok "collab turns on for that tab only" || bad "collab scope"
out=$(hook claude "$A" "plain prompt"); ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"Collab mode is on"*"You are @$na"*"@$nb (Codex"*"afc-collab send"* ]] \
  && ok "while on, every prompt carries the roster and how to message" || bad "roster" "$out"
out=$(inpane "$A" collab send "@$nb" $'line one\nline two'); sleep 0.6
[[ "$out" == "sent to @$nb" && "$(cat "$T/in-B" 2>/dev/null)" == "[collab from @$na] line one ⏎ line two" ]] \
  && ok "send types the message into the peer's pane as one prompt" || bad "send" "$out | $(cat "$T/in-B" 2>/dev/null)"
[[ "$(tm display -p -t "$A" '#{@collab_n}')" == 1 ]] && ok "each message is counted" || bad "count"
out=$(inpane "$B" collab send @all "back to you"); sleep 0.6
[[ "$out" == "sent to @$na" && "$(cat "$T/in-A" 2>/dev/null)" == "[collab from @$nb] back to you" ]] \
  && ok "@all reaches every other agent of the tab" || bad "send all" "$out"
out=$(inpane "$A" collab send "@$nc" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"belongs to another project"* && ! -s "$T/in-C" ]] && ok "send to another project's agent is refused" || bad "send other project" "rc=$rc $out"
out=$(inpane "$A" collab send @ghost hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"no agent @ghost"* ]] && ok "send to an unknown name is refused" || bad "send unknown" "rc=$rc $out"
out=$(inpane "$A" collab send "@$na" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"that is you"* ]] && ok "send to itself is refused" || bad "send self" "rc=$rc $out"
tm set -w -t agents:A @collab_n 40
out=$(inpane "$A" collab send "@$nb" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"message limit"* ]] && ok "the message limit stops a chat loop" || bad "limit" "rc=$rc $out"
out=$(hook claude "$A" "/collab status"); [[ "$(j '["reason"]' "$out")" == *"Collab is on, 0 messages left"* ]] \
  && ok "/collab status" || bad "status" "$out"
out=$(hook codex "$B" "collab stop")
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"Collab stopped"* ]] \
  && ok "Codex: plain 'collab stop' works (Codex allows no custom slash command)" || bad "codex stop" "$out"
[[ -z "$(tm display -p -t "$A" '#{@collab}')$(tm display -p -t "$A" '#{@collab_n}')" ]] && ok "stop clears the mode and the count" || bad "stop state"
out=$(hook claude "$A" "plain prompt"); [[ -z "$out" ]] && ok "after stop, prompts carry no roster" || bad "after stop" "$out"
out=$(hook gemini "$C" "/collab on")
[[ "$(j '["decision"]' "$out")" == deny && "$(j '["reason"]' "$out")" == *"Collab on in tab ProjB"* ]] \
  && ok "Gemini: /collab is answered with a deny (no model turn)" || bad "gemini" "$out"
out=$(hook copilot "$C" "/collab stop")
[[ "$(j '["additionalContext"]' "$out")" == *"Collab stopped"* ]] && ok "Copilot: the answer goes in as context" || bad "copilot" "$out"
SKILL_TXT=$(printf 'The user explicitly invoked the "/collab" skill. Follow its instructions now.\n\n<skill-context name="collab">\nBase directory for this skill: /x\n\nReply.\n\n\nARGUMENTS: %s\n</skill-context>' "status")
out=$(hook copilot "$C" "$SKILL_TXT")
[[ "$(j '["additionalContext"]' "$out")" == *"Collab is off in tab ProjB"* ]] && ok "Copilot: /collab run as a skill is recognised (ARGUMENTS line)" || bad "copilot skill" "$out"
out=$(hook copilot "$C" "${SKILL_TXT/status/}")
[[ "$(j '["additionalContext"]' "$out")" == *"Collab on in tab ProjB"* ]] && ok "Copilot: /collab skill with no words turns collab on" || bad "copilot skill on" "$out"
out=$(hook copilot "$C" "${SKILL_TXT/status/bogus}")
[[ "$(j '["additionalContext"]' "$out")" == *"unknown word 'bogus'"* ]] && ok "Copilot: an unknown word is refused" || bad "copilot skill bogus" "$out"
hook copilot "$C" "${SKILL_TXT/status/stop}" >/dev/null
out=$(hook claude "$A" "/collab please explain"); [[ -z "$out" ]] && ok "/collab with other words is left to the model" || bad "not a command" "$out"
out=$(printf '{"prompt":"/collab"}' | python3 -I "$HERE/bin/afc-rules" hook claude prompt 2>&1)
[[ -z "$out" ]] && ok "outside a fleet pane the hook adds nothing" || bad "no pane" "$out"

echo "Install"
mkdir -p "$T/c1" "$T/c2/commands" "$T/g1" "$HOME/.gemini-homes/g2/.gemini"
printf 'c1 %s\nc2 %s\n' "$T/c1" "$T/c2" > "$AGENTS_ACCOUNTS"; printf 'main %s\n' "$T/g1" > "$AGENTS_ACCOUNTS_GEMINI"
printf 'main %s\n' "$T/cp1" > "$AGENTS_ACCOUNTS_COPILOT"
echo "my own" > "$T/c2/commands/collab.md"
out=$(collab install --dry-run); [[ "$out" == *"would write"* && ! -e "$T/c1/commands/collab.md" ]] && ok "install --dry-run writes nothing" || bad "dry" "$out"
out=$(collab install)
[[ -f "$T/c1/commands/collab.md" && -f "$T/g1/.gemini/commands/collab.toml" ]] && ok "install writes /collab for each Claude account and Gemini home" || bad "install" "$out"
[[ -f "$HOME/.gemini-homes/g2/.gemini/commands/collab.toml" ]] && ok "install also covers Gemini homes in ~/.gemini-homes" || bad "gemini-homes" "$out"
grep -q '^name: collab$' "$T/cp1/skills/collab/SKILL.md" 2>/dev/null && ok "install writes the /collab skill for each Copilot home" || bad "copilot install" "$out"
[[ "$(cat "$T/c2/commands/collab.md")" == "my own" && "$out" == *"skipped"* ]] && ok "install leaves a /collab of your own alone" || bad "foreign" "$out"
grep -q 'prompt = "/collab {{args}}"' "$T/g1/.gemini/commands/collab.toml" && ok "Gemini's /collab passes its words on to the hook" || bad "toml" "$(cat "$T/g1/.gemini/commands/collab.toml")"
out=$(collab install); [[ "$out" != *wrote* ]] && ok "install twice changes nothing" || bad "idempotent" "$out"

echo "Hardening (agy @name+/collab, send lock, single-account install, safe fences)"
# 1. Antigravity reads latest <USER_REQUEST> from transcript.jsonl, injects @name once per turn, and handles /collab
AGY_CID="agy-test-1"
AGY_LOG="$HOME/.gemini/antigravity-cli/brain/$AGY_CID/.system_generated/logs"
mkdir -p "$AGY_LOG"
printf '{"step_index":1,"type":"USER_INPUT","content":"<USER_REQUEST>\\ncheck @%s please\\n</USER_REQUEST>"}\n' "$nb" > "$AGY_LOG/transcript.jsonl"
out=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":1}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
[[ "$out" == *"SCREEN-B"* && "$out" == *"~~~~"* ]] \
  && ok "agy PreInvocation extracts @name from transcript.jsonl and wraps screen in ~~~~ fence" || bad "agy @name" "$out $(cat "$T/err")"
out2=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":1}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
[[ "$out2" == "{}" ]] && ok "agy PreInvocation skips duplicate collab/mode work on step 2 of same turn" || bad "agy dedup" "$out2"
out2b=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":5}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
[[ "$out2b" != *"SCREEN-B"* ]] && ok "agy PreInvocation skips duplicate @name collab send when initialNumSteps grows on same USER_INPUT" || bad "agy growing-steps dedup" "$out2b"
out=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":7,"lastUserInput":"plain words"}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
[[ "$out" != *"SCREEN-B"* ]] && ok "agy: lastUserInput wins over an older line in the transcript" || bad "agy lastUserInput" "$out"
printf '{"step_index":2,"type":"USER_INPUT","content":"<USER_REQUEST>\\n/collab on\\n</USER_REQUEST>"}\n' >> "$AGY_LOG/transcript.jsonl"
out3=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":2}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
[[ "$out3" == *"Collab on in tab ProjA"* && "$(tm display -p -t "$A" '#{@collab}')" == on ]] \
  && ok "agy PreInvocation executes /collab on from transcript.jsonl" || bad "agy /collab" "$out3"
printf '{"step_index":3,"type":"USER_INPUT","content":"<USER_REQUEST>\\n/collab status\\n</USER_REQUEST>"}\n' >> "$AGY_LOG/transcript.jsonl"
out3a=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":10,"lastUserInput":"/collab status"}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
out3b=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":14,"lastUserInput":"/collab status"}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
printf '{"step_index":4,"type":"USER_INPUT","content":"<USER_REQUEST>\\n/collab status\\n</USER_REQUEST>"}\n' >> "$AGY_LOG/transcript.jsonl"
out3c=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":18,"lastUserInput":"/collab status"}' "$AGY_CID" "$T/projA" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err")
[[ "$out3a" == *"Collab is on"* && "$out3b" != *"already handled"* && "$out3c" == *"Collab is on"* ]] \
  && ok "agy lastUserInput dedupes same turn (step 3) yet allows identical prompt on new turn (step 4)" || bad "agy same-text new-turn" "a=$out3a b=$out3b c=$out3c"

# 2. Concurrent sends are serialised by send.lock and count accurately without interleaving
rm -f "$T/in-B"
inpane "$A" collab send "@$nb" "msg-one" >/dev/null &
p1=$!
inpane "$A" collab send "@$nb" "msg-two" >/dev/null &
p2=$!
wait "$p1" "$p2"; sleep 0.6
cnt=$(tm display -p -t "$A" '#{@collab_n}')
lines=$(wc -l < "$T/in-B" 2>/dev/null | tr -d ' ' || echo 0)
[[ "$cnt" == 2 && "$lines" == 2 ]] && grep -q "msg-one" "$T/in-B" && grep -q "msg-two" "$T/in-B" \
  && ok "concurrent sends are serialised (count=2, zero interleaved lines)" || bad "concurrent send" "cnt=$cnt lines=$lines $(cat "$T/in-B" 2>/dev/null)"
inpane "$A" collab stop >/dev/null

# 3. Single-account fallback: without accounts files, install falls back to ~/.claude and ~/.gemini
rm -f "$AGENTS_ACCOUNTS" "$AGENTS_ACCOUNTS_GEMINI"
rm -rf "$HOME/.gemini-homes"
mkdir -p "$HOME/.claude" "$HOME/.gemini"
out=$(collab install)
[[ -f "$HOME/.claude/commands/collab.md" && -f "$HOME/.gemini/commands/collab.toml" ]] \
  && ok "single-account fallback installs /collab into ~/.claude and ~/.gemini" || bad "single-account install" "$out"

# 4. Safe fence bumps past embedded ~~~~ and triple-backtick blocks
python3 -I - "$HERE/lib/afc" <<'PY' && ok "safe fence never breaks on embedded triple-backtick or tilde blocks" || bad "safe fence"
import sys
sys.path.insert(0, sys.argv[1])
import collab
assert collab._safe_fence("```diff\n- You: hi\n+ SITREP\n```") == "~~~~"
assert collab._safe_fence("~~~~\ninside\n~~~~") == "~~~~~"
PY

echo "Direct @peer conversation & master control consent"
inpane "$A" collab stop >/dev/null
rm -f "$T/in-B" "$T/in-A"
out=$(hook claude "$A" "@$nb is this correct?"); sleep 0.6
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"Sent to @$nb"*"one-shot; collab stays off"* && -z "$(tm display -p -t "$A" '#{@collab}')" && "$(cat "$T/in-B" 2>/dev/null)" == "[collab from @$na] is this correct?" ]] \
  && ok "direct '@peer msg' delivers one-shot to peer while keeping collab OFF (master control)" || bad "direct @peer" "$out | collab=$(tm display -p -t "$A" '#{@collab}') | inB=$(cat "$T/in-B" 2>/dev/null)"

# Without /collab on, receiver cannot send unsolicited messages OR peek on its own
out=$(inpane "$B" collab send "@$na" "unsolicited reply" 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"collab mode is off"* ]] \
  && ok "after one-shot @peer msg, peer cannot message back without master control /collab on" || bad "one-shot no unsolicited" "rc=$rc $out"
out=$(inpane "$B" collab peek "@$na" 20 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"collab mode is off"* ]] \
  && ok "peer cannot peek another pane while collab is off" || bad "peek off" "rc=$rc $out"

# One-shot @peer msg to a BUSY peer still drains cleanly via Stop hook even with collab OFF
tm set -p -t "$B" @busy 1; rm -f "$T/in-B"
out=$(hook claude "$A" "@$nb one-shot while busy"); sleep 0.3
sout=$(printf '{"session_id":"s-one","cwd":"%s","stop_hook_active":false}' "$T/projA" | inpane "$B" python3 -I "$HERE/bin/afc-rules" hook claude stop 2>"$T/err")
tm set -p -t "$B" @busy 0
[[ "$(j '["decision"]' "$out")" == block && -z "$(tm display -p -t "$A" '#{@collab}')" && ! -s "$T/in-B" \
   && "$(j '["decision"]' "$sout")" == block && "$(j '["reason"]' "$sout")" == *"one-shot while busy"* ]] \
  && ok "one-shot @peer msg to busy peer queues in collab.db and delivers on Stop hook while collab stays OFF" || bad "one-shot busy" "$out | $sout"

# Agents cannot self-enable collab via CLI (even with env vars stripped inside an agent pane!)
for ev in "CLAUDECODE=1" "ANTIGRAVITY_AGENT=1" "CODEX_MANAGED_BY_NPM=1" "GEMINI_CLI_HOME=/tmp"; do
  out=$(env "$ev" TMUX="$SP,1,0" TMUX_PANE="$A" python3 -I "$HERE/bin/afc-collab" on 2>&1); rc=$?
  (( rc == 1 )) && [[ "$out" == *"master control"* ]] \
    && ok "agent shell ($ev) cannot self-enable collab via afc-collab on" || bad "self-enable $ev" "rc=$rc $out"
done
out=$(inpane "$A" collab on 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"master control"* ]] \
  && ok "env-stripped afc-collab on inside an agent pane is still blocked (pane PID check)" || bad "self-enable stripped" "rc=$rc $out"

# When user explicitly runs /collab on via prompt hook, receiver gets sender screen + master-control rule + reply cue
hook claude "$A" "/collab on" >/dev/null
out=$(hook codex "$B" "[collab from @$na] is this correct?")
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"SCREEN-A"* && "$ctx" == *"live collab message from @$na"* && "$ctx" == *"afc-collab send @$na"* && "$ctx" == *"Master control rule: NEVER initiate peer messages"* ]] \
  && ok "incoming [collab from @sender] gives sender screen, master control rule, and reply-back cue" || bad "incoming collab reply cue" "$ctx"

# @all direct send is explicit multi-agent consent -> enables collab and sends to all peers
inpane "$A" collab stop >/dev/null; rm -f "$T/in-A"
out=$(hook codex "$B" "@all sync up now"); sleep 0.6
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"Sent to @$na"* && "$(tm display -p -t "$B" '#{@collab}')" == on && "$(cat "$T/in-A" 2>/dev/null)" == "[collab from @$nb] sync up now" ]] \
  && ok "direct '@all msg' enables collab (explicit multi-agent consent) and sends to all peers" || bad "direct @all" "$out | $(cat "$T/in-A" 2>/dev/null)"

# Direct @peer from Antigravity (lastUserInput) delivers one-shot into peer pane while keeping collab off
inpane "$A" collab stop >/dev/null; rm -f "$T/in-B"
out=$(printf '{"conversationId":"%s","cwd":"%s","initialNumSteps":9,"lastUserInput":"@%s ping from agy"}' "$AGY_CID" "$T/projA" "$nb" | inpane "$A" python3 -I "$HERE/bin/afc-rules" hook agy prompt 2>"$T/err"); sleep 0.6
[[ "$out" == *"Sent to @$nb"* && -z "$(tm display -p -t "$A" '#{@collab}')" && "$(cat "$T/in-B" 2>/dev/null)" == "[collab from @$na] ping from agy" ]] \
  && ok "agy direct '@peer msg' delivers one-shot to peer pane while keeping collab off" || bad "agy direct @peer" "$out | $(cat "$T/in-B" 2>/dev/null)"

# Cross-project '@other_project_agent msg' is refused: nothing sent, no screen shared, collab stays off
inpane "$A" collab stop >/dev/null; rm -f "$T/in-C"
out=$(hook claude "$A" "@$nc what is happening over there?"); sleep 0.3
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"belongs to another project"*"Nothing was sent"* \
   && "$out" != *"SCREEN-C"* && -z "$(tm display -p -t "$A" '#{@collab}')" && ! -s "$T/in-C" ]] \
  && ok "leading '@other_project_agent msg' is refused with the reason; nothing sent" || bad "cross-project direct" "$out"

# Multi-tag '@peer @self msg' delivers clean msg to peer AND lets this pane respond too
inpane "$A" collab stop >/dev/null; rm -f "$T/in-B"
out=$(hook claude "$A" "@$nb @$na fix this together"); sleep 0.6
ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$(j '["decision"]' "$out")" != block && "$ctx" == *"Also delivered this prompt to @$nb"* && "$(cat "$T/in-B" 2>/dev/null)" == "[collab from @$na] fix this together" ]] \
  && ok "multi-tag '@peer @self msg' sends clean body to peer AND lets this pane answer" || bad "multi-tag" "$out | $(cat "$T/in-B" 2>/dev/null)"

# Codex daemon with stale/dead TMUX_PANE=%9999 resolves real live Codex pane ($B) via cwd
inpane "$A" collab stop >/dev/null; rm -f "$T/in-A"
out=$(python3 -I -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "cwd": sys.argv[2], "session_id": "cx-stale"}))' \
  "@$na check from daemon" "$T/projA" | TMUX="$SP,1,0" TMUX_PANE="%9999" python3 -I "$HERE/bin/afc-rules" hook codex prompt 2>"$T/err"); sleep 0.6
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"Sent to @$na"* && "$(cat "$T/in-A" 2>/dev/null)" == "[collab from @$nb] check from daemon" ]] \
  && ok "Codex hook with stale daemon TMUX_PANE resolves live Codex pane by cwd and delivers @peer" || bad "codex stale pane" "$out | $(cat "$T/in-A" 2>/dev/null) | $(cat "$T/err")"

# Codex shell tool running `afc-collab send` with stale TMUX_PANE=%9999 + CODEX_MANAGED_BY_NPM=1 resolves $B via cwd
hook claude "$A" "/collab on" >/dev/null; rm -f "$T/in-A"
out=$(cd "$T/projA" && CODEX_MANAGED_BY_NPM=1 TMUX="$SP,1,0" TMUX_PANE="%9999" collab send "@$na" "from codex shell" 2>&1); sleep 0.6
[[ "$out" == "sent to @$na" && "$(cat "$T/in-A" 2>/dev/null)" == "[collab from @$nb] from codex shell" ]] \
  && ok "afc-collab send inside Codex shell with stale TMUX_PANE resolves live Codex pane via cwd" || bad "codex shell send" "$out | $(cat "$T/in-A" 2>/dev/null)"

echo "Project isolation (validation layers)"
inpane "$A" collab stop >/dev/null; rm -f "$T/in-A" "$T/in-B" "$T/in-C" "$T/in-E" "$T/in-W"
# a pane in tab ProjA whose folder is another project, and a git worktree of projA in the same tab
mkdir -p "$T/projX"
git -C "$T/projA" init -q && git -C "$T/projA" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git -C "$T/projA" worktree add -q "$T/wtA" 2>/dev/null
E=$(tm split-window -P -F '#{pane_id}' -t "$A" -c "$T/projX" "$T/fake/claude E")
W=$(tm split-window -P -F '#{pane_id}' -t "$A" -c "$T/wtA" "$T/fake/claude W")
inpane "$A" collab name --all >/dev/null; ne=$(name_of "$E"); nw=$(name_of "$W"); nd=$(name_of "$D"); sleep 0.4
hook claude "$A" "/collab on" >/dev/null
out=$(inpane "$A" collab send "@$ne" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"works in another folder"* && ! -s "$T/in-E" ]] \
  && ok "same tab but another project folder: refused" || bad "other folder" "rc=$rc $out"
out=$(inpane "$A" collab send "@$nw" "hello worktree"); sleep 0.5
[[ "$out" == "sent to @$nw" && "$(cat "$T/in-W" 2>/dev/null)" == "[collab from @$na] hello worktree" ]] \
  && ok "a git worktree of the project counts as the same project" || bad "worktree" "$out"
out=$(hook claude "$A" "plain prompt"); ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"@$nw"* && "$ctx" != *"@$ne"* && "$ctx" != *"@$nc"* ]] && ok "the roster lists only this project's agents" || bad "roster scope" "$ctx"
rm -f "$T/in-B"
out=$(inpane "$A" collab send @all "to everyone"); sleep 0.5
[[ "$out" == *"@$nb"* && "$out" == *"@$nw"* && "$out" != *"@$ne"* && ! -s "$T/in-E" && ! -s "$T/in-C" ]] \
  && ok "@all reaches only this project's agents" || bad "all scope" "$out"
out=$(hook claude "$A" "@$nb @$nc both of you check"); sleep 0.3
[[ "$(j '["decision"]' "$out")" == block && "$(j '["reason"]' "$out")" == *"another project"* && "$(tail -1 "$T/in-B")" == "[collab from @$na] to everyone" ]] \
  && ok "one foreign tag in a direct send stops the whole send" || bad "mixed tags" "$out"
out=$(inpane "$A" collab send "@$nb" $'hi\e[2J clear' 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"control character"* ]] && ok "control characters (ESC, Ctrl keys) are refused" || bad "control chars" "rc=$rc $out"
out=$(inpane "$A" collab send "@$nb" "$(printf 'y%.0s' {1..1501})" 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"1501 characters; the limit is 1500"* ]] && ok "a message over the limit is refused, not cut" || bad "too long" "rc=$rc $out"
out=$(inpane "$A" collab send "@Bad-Name!" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"not an agent name"* ]] && ok "a malformed agent name is refused" || bad "bad name" "rc=$rc $out"
out=$(inpane "$A" collab send --from "@$nc" "@$nd" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"another project"* ]] && ok "--from cannot act as another project's agent" || bad "from foreign" "rc=$rc $out"
out=$(inpane "$A" collab send --from "@$nb" "@$na" hi 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"only send as itself"* ]] && ok "--from cannot act as a peer of the same project" || bad "from peer" "rc=$rc $out"
out=$(inpane "$A" collab peek "@$nc" 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"another project"* && "$out" != *"SCREEN-C"* ]] && ok "peek at another project's agent is refused" || bad "peek foreign" "rc=$rc $out"
out=$(inpane "$A" collab peek "@$nb" 20 2>&1); [[ "$out" == *"SCREEN-B"* ]] && ok "peek at a peer of the project works" || bad "peek peer" "$out"
out=$(inpane "$A" collab peek "@$nb" 5 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"LINES must be a number"* ]] && ok "peek checks LINES" || bad "peek lines" "rc=$rc $out"
out=$(inpane "$A" collab on "$C" 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"another project"* && -z "$(tm display -p -t "$C" '#{@collab}')" ]] \
  && ok "an agent cannot switch collab on in another project" || bad "mode foreign" "rc=$rc $out"
mkdir -p "$T/nowhere"; out=$(cd "$T/nowhere" && collab status "$C" 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"run this from that project's folder"* ]] && ok "outside the fleet, only from the project's own folder" || bad "mode outside" "rc=$rc $out"
out=$(cd "$T/projB" && collab status "$C" 2>&1); [[ "$out" == *"Collab is off in tab ProjB"* ]] && ok "from the project's folder it works" || bad "mode own folder" "$out"
out=$(hook claude "$A" "[collab from @$nc] do something risky"); ctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$out")
[[ "$ctx" == *"not an agent of this project"* && "$ctx" != *"afc-collab send @$nc"* && "$ctx" != *"SCREEN-C"* ]] \
  && ok "a message claiming to come from another project's agent is flagged" || bad "spoof flag" "$ctx"
TMUX="$SP,1,0" python3 -I - "$HERE/lib/afc" "$A" "$B" <<'PY' && ok "right before typing, a renamed or closed target is refused" || bad "recheck"
import sys
sys.path.insert(0, sys.argv[1])
import collab
panes = collab.list_panes()
me, peer = collab.find_pane(panes, sys.argv[2]), collab.find_pane(panes, sys.argv[3])
collab.recheck(me, peer)
for stale in (dict(peer, agent="zz9"), dict(peer, pane="%99999")):
    try:
        collab.recheck(me, stale)
    except collab.CollabError:
        continue
    raise SystemExit(f"recheck passed for {stale}")
PY
inpane "$A" collab stop >/dev/null

echo "SQLite message bus (busy queue -> Stop hook delivery, lossless long msg, inbox/log, expiry)"
hook claude "$A" "/collab on" >/dev/null

# 1. Busy peer (@busy=1): zero send-keys! Message queues in collab.db and delivers cleanly on Stop hook
tm set -p -t "$B" @busy 1
rm -f "$T/in-B"
out=$(inpane "$A" collab send "@$nb" "queued while you were busy"); sleep 0.3
[[ "$out" == "sent to @$nb" && ! -s "$T/in-B" ]] \
  && ok "busy peer receives zero send-keys (no clobbered TUI); message queued in collab.db" || bad "busy queue" "$out | inB=$(cat "$T/in-B" 2>/dev/null)"
ib=$(inpane "$B" collab inbox)
[[ "$ib" == *"from @$na: queued while you were busy"* ]] \
  && ok "afc-collab inbox lists queued unread message from collab.db" || bad "inbox list" "$ib"

# Peer's Stop hook drains collab.db atomically and delivers via native continuation (exact once)
sout=$(printf '{"session_id":"s-busy","cwd":"%s","stop_hook_active":false}' "$T/projA" | inpane "$B" python3 -I "$HERE/bin/afc-rules" hook claude stop 2>"$T/err")
[[ "$(j '["decision"]' "$sout")" == block && "$(j '["reason"]' "$sout")" == *"[ACF collab inbox]"*"queued while you were busy"* ]] \
  && ok "Stop hook delivers queued message natively when busy peer finishes turn" || bad "stop inbox claude" "$sout $(cat "$T/err")"
sout2=$(printf '{"session_id":"s-busy","cwd":"%s","stop_hook_active":false}' "$T/projA" | inpane "$B" python3 -I "$HERE/bin/afc-rules" hook claude stop 2>"$T/err")
[[ -z "$sout2" && "$(inpane "$B" collab inbox)" == *"inbox empty"* ]] \
  && ok "Stop hook drains inbox atomically (second stop is clean, zero duplicate delivery)" || bad "stop drain once" "$sout2"

# Antigravity Stop hook uses decision=continue for queued inbox delivery
inpane "$A" collab send "@$nb" "queued for agy stop" >/dev/null
aout=$(printf '{"conversationId":"agy-stop-1","cwd":"%s","terminationReason":"NO_TOOL_CALL"}' "$T/projA" | inpane "$B" python3 -I "$HERE/bin/afc-rules" hook agy stop 2>"$T/err")
[[ "$(j '["decision"]' "$aout")" == continue && "$(j '["reason"]' "$aout")" == *"queued for agy stop"* ]] \
  && ok "Antigravity Stop hook delivers queued inbox via decision=continue" || bad "stop inbox agy" "$aout"

# 2. Idle peer + long message (>160 chars): compact #id wake-up via send-keys + full lossless body from collab.db
tm set -pu -t "$B" @busy
rm -f "$T/in-B"
LONG_MSG="BEGIN_LONG_$(printf 'A%.0s' {1..180})_END_LOSSLESS_MARKER"
inpane "$A" collab send "@$nb" "$LONG_MSG" >/dev/null; sleep 0.5
wake_line=$(cat "$T/in-B" 2>/dev/null)
[[ "$wake_line" == "[collab #"* && "$wake_line" == *"from @$na]"* && ${#wake_line} -lt 170 ]] \
  && ok "long message (>160 chars) wakes idle peer with compact #id pointer instead of raw text dump" || bad "long wake" "len=${#wake_line} $wake_line"
pout=$(hook codex "$B" "$wake_line")
pctx=$(j '["hookSpecificOutput"]["additionalContext"]' "$pout")
[[ "$pctx" == *"[ACF collab inbox]"*"BEGIN_LONG_"*"_END_LOSSLESS_MARKER"* ]] \
  && ok "receiver prompt hook injects full lossless long body from collab.db" || bad "long lossless" "$pctx"

# 3. afc-collab log prints structured transcript and /collab stop expires pending unread messages
log_out=$(inpane "$A" collab log 10)
[[ "$log_out" == *"[delivered] @$na -> @$nb: queued while you were busy"* && "$log_out" == *"_END_LOSSLESS_MARKER"* ]] \
  && ok "afc-collab log shows structured SQLite transcript with status" || bad "collab log" "$log_out"

tm set -p -t "$B" @busy 1
inpane "$A" collab send "@$nb" "pending before stop" >/dev/null
inpane "$A" collab stop >/dev/null
tm set -pu -t "$B" @busy
sout3=$(printf '{"session_id":"s-exp","cwd":"%s","stop_hook_active":false}' "$T/projA" | inpane "$B" python3 -I "$HERE/bin/afc-rules" hook claude stop 2>"$T/err")
[[ -z "$sout3" && "$(inpane "$B" collab inbox)" == *"inbox empty"* ]] \
  && ok "/collab stop expires pending unread inbox messages immediately" || bad "stop expire" "$sout3 | $(inpane "$B" collab inbox)"

# 4. Cross-project inbox isolation: $A cannot inspect $C's inbox
out=$(inpane "$A" collab inbox "@$nc" 2>&1); rc=$?
(( rc == 1 )) && [[ "$out" == *"another project"* ]] \
  && ok "afc-collab inbox refuses cross-project access" || bad "cross-project inbox" "rc=$rc $out"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
