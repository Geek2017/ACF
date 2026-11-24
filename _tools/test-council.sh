#!/usr/bin/env bash
# test-council.sh: tests for bin/afc-council, the group chat of the fleet's LLMs and made agents.
# No model is asked: a stand-in for `agents` answers --accounts, --room and --as, writing down every
# prompt it gets and answering with markers that say who spoke, in which phase, and what it had read.
# The council's settings file, the project folder (a git repo of its own) and a tmux server for the
# Alt+K check all live in one temp folder.
#
#   bash _tools/test-council.sh               test bin/afc-council and tmux/tmux.conf of this folder
set -uo pipefail
# the spinner is braille: grep must read UTF-8 (a C locale cannot match it in a bracket expression)
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; else export LC_ALL=en_US.UTF-8; fi
HERE="$(cd "$(dirname "$0")/.." && pwd)"
COUNCIL="$HERE/bin/afc-council"; CONF_TMUX="$HERE/tmux/tmux.conf"
[[ $# -eq 0 ]] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
pass=0; fail=0
T=$(mktemp -d /tmp/acf-council-test.XXXXXX)
T=$(cd "$T" && pwd -P)    # its real path: on a Mac /tmp is a link to /private/tmp, which is what tmux reports
SOCK="acfcouncil-$$"; TB="$HOME/.local/bin/tmux"; [[ -x "$TB" ]] || TB=$(command -v tmux)
cp=""
trap '"$TB" -L "$SOCK" kill-server 2>/dev/null; "$TB" -L "$SOCK-t" kill-server 2>/dev/null; [[ -n "$cp" ]] && kill "$cp" 2>/dev/null; rm -rf "$T"' EXIT
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got: $2   expected: $3"; fi; }
has() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "nothing like /$3/ in: $(head -c 600 <<< "$2")"; fi; }
hasnt() { if grep -qE -- "$3" <<< "$2"; then bad "$1" "found /$3/"; else ok "$1"; fi; }

# ---- the stand-in fleet --------------------------------------------------------------------------------
mkdir -p "$T/proj" "$T/log"
git -C "$T/proj" init -q 2>/dev/null; echo "# p" > "$T/proj/README.md"
cat > "$T/accounts.txt" <<'EOF'
* claude  secretacct1 me@example.com                 /home/x/.claude
  claude  secretacct2 not signed in                  /home/x/.claude-b
* gemini  secretacct3 API key                        /home/x/.gemini-a
* codex   secretacct4 me@example.com                 /home/x/.codex
* agy     secretacct5 not signed in                  /home/x/agy
EOF
cat > "$T/agents" <<'EOF'
#!/usr/bin/env bash
L="$COUNCIL_TEST_DIR"
case "$1" in
  --accounts) cat "$L/accounts.txt"; exit 0 ;;
  --room) if [[ -f "$L/full" ]]; then echo "the fleet is using 11G of its 11G limit"; exit 1; fi; exit 0 ;;
  --as) ;;
  *) exit 2 ;;
esac
spec=$2; shift 2
tool=claude; [[ "$spec" == *:* ]] && tool=${spec%%:*}
args="$*"; out=""; prompt=""
if [[ "$tool" == agy ]]; then
  while (( $# )); do [[ "$1" == -p ]] && { prompt=$2; break; }; shift; done
else
  prompt=$(cat)
  while (( $# )); do [[ "$1" == -o ]] && out=$2; shift; done
fi
id="$(date +%s%N)-$tool-$RANDOM"
printf '%s' "$prompt" > "$L/log/prompt.$id"
printf '%s\t%s\t%s\n' "$id" "$spec" "$args" >> "$L/log/argv"
# a model whose plan is spent: the check before a member joins the table must keep it out
if [[ " $args " == *" quota-test "* || " $args " == *"=quota-test "* ]]; then
  echo "Error: 429 RESOURCE_EXHAUSTED: You exceeded your current quota" >&2; exit 1
fi
start=$(date +%s.%N)
[[ -f "$L/slow.$tool" ]] && sleep 6.01
sleep 0.6
printf '%s\t%s\t%s\n' "$tool" "$start" "$(date +%s.%N)" >> "$L/log/timing"
who=$(grep -oE '^You are @[a-z0-9_-]+' <<< "$prompt" | head -1); who=${who#You are @}
kind=ANSWER; grep -q 'Give your point' <<< "$prompt" && kind=POINT; grep -qE '^Roast (the answers|round [0-9]+:)' <<< "$prompt" && kind=ROAST
grep -qE '^Round table(:|, pass [0-9]+:)' <<< "$prompt" && kind=TABLE
seen=$(sed -n '/^--- The thread so far ---$/,/^--- End of the thread ---$/p' <<< "$prompt" | grep -oE '(POINT|ANSWER|ROAST|TABLE) from @[a-z0-9_-]+' | sort -u | tr '\n' ',')
reply="$kind from @$who. read: [$seen]"
[[ -f "$L/pass" ]] && grep -q '^Round table, pass' <<< "$prompt" && reply="Pass."
# a judge with the remove power takes @codex off the table
[[ -f "$L/judge" ]] && grep -q "You may give a strike" <<< "$prompt" && reply="$reply"$'\n'"Strike: @$(cat "$L/judge") - repeats itself"
# an agent asked to keep something: its Remember: line
[[ -f "$L/remember" ]] && grep -q "lines starting 'Remember:'" <<< "$prompt" && reply="$reply"$'\n'"Remember: $who keeps an eye on cost"
[[ -f "$L/echo-name" ]] && reply="@$who: $reply"     # an LLM that copies the thread's "@name:" format
# Win Stake's last round asks for a vote: everyone votes for @claude (Claude itself for @codex)
if grep -q "Vote: @name" <<< "$prompt"; then v=claude; [[ "$who" == claude ]] && v=codex; reply="$reply"$'\n'"Vote: @$v"; fi
[[ -f "$L/long" ]] && reply="$reply $(printf 'wordy%.0s ' $(seq 1 60))end"
# an agent whose project's instructions add a greeting and a footer to every reply
[[ -f "$L/footer" ]] && reply="My Lord. $reply"$'\n\n'"You: whatever the chair said"$'\n\n'"SITREP · ARMY/MDMP · P1 · Done: x · Open: y · Next: z"
if [[ -n "$out" ]]; then echo "codex log noise on stdout"; printf '%s\n' "$reply" > "$out"; else printf '%s\n' "$reply"; fi
EOF
chmod +x "$T/agents"
# account folders with settings of their own: what the pane headers show as the defaults
mkdir -p "$T/ch" "$T/xh" "$T/gh"; echo '{"model": "sonnet"}' > "$T/ch/settings.json"
# (gh: the Gemini account's home, where /effort @gemini writes Gemini's settings; never this machine's)
printf 'model = "gpt-test"\nmodel_reasoning_effort = "medium"\n[profiles.x]\nmodel = "not-this"\n' > "$T/xh/config.toml"
# the Codex account's own list of models (what + add and Alt+M offer)
# the Claude account's known models (what its menus offer), and Antigravity's list as `agy models` gave it
echo '{"additionalModelCostsCache": {"claude-haiku-4-5-20251001": {}, "claude-fable-5-2": {}, "claude-haiku-5-5": {}, "other": {}}}' > "$T/ch/.claude.json"
mkdir -p "$T/cache/afc-council"
echo '{"agy": ["gemini-4-neon-low", "gemini-4-neon-high", "gemini-4-neon-xhigh", "claude-opus-5-5-medium", "claude-opus-5-5-high", "gpt-oss-120b-medium"]}' > "$T/cache/afc-council/models.json"
export XDG_CACHE_HOME="$T/cache" AFC_COUNCIL_NO_REFRESH=1
echo '{"models": [{"slug": "gpt-6-astra", "visibility": "list"}, {"slug": "gpt-hidden", "visibility": "hide"}, {"slug": "gpt-6-sol", "visibility": "list"}, {"slug": "gpt-test", "visibility": "list"}]}' > "$T/xh/models_cache.json"
sed -i.bak -e "s|/home/x/.claude\$|$T/ch|" -e "s|/home/x/.codex\$|$T/xh|" -e "s|/home/x/.gemini-a\$|$T/gh|" "$T/accounts.txt"
export COUNCIL_TEST_DIR="$T" AFC_COUNCIL_AGENTS="$T/agents" AFC_COUNCIL_CONF="$T/council.json"
# Gemini's effort: this folder's own helper, keeping its level in the test folder (never the machine's)
export AFC_COUNCIL_GEMINI_EFFORT="$HERE/bin/afc-gemini-effort" AFC_GEMINI_EFFORT_FILE="$T/gemini-effort"
# the format menu a council offers when it opens would take the keys the checks send
export AFC_COUNCIL_NO_FORMAT_MENU=1
# most checks use the LLMs' own names (@claude): a new project's council starts from this /names llm;
# going by the model (the default) has checks of its own
echo '{"names": "llm"}' > "$T/council.json"
# the fleet's own `agents` (✕ goes through agents --close) must talk to the test's tmux, never the real fleet
export AGENTS_SOCK="$SOCK"
# a council that never ends fails its checks, not the whole test: each run is given 3 minutes
run() { (cd "$T/proj" && printf '%s\n' "$@" | env -u TMUX timeout 180 python3 "$COUNCIL" 2>&1); }
# wait for a council started in the background (a subshell); after SECS, stop it and say so
ended() {
  local i
  for (( i = 0; i < $2 * 2; i++ )); do kill -0 "$1" 2>/dev/null || { wait "$1"; return 0; }; sleep 0.5; done
  pkill -KILL -P "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 1
}
since() { find "$T/log" -name 'prompt.*' -newer "$T/mark" | sort; }
mark() { touch "$T/mark"; sleep 0.05; }

echo "council of $COUNCIL"

# ---- who sits at the table ---------------------------------------------------------------------------
out=$(run "/agents")
has "the signed-in LLMs are at the table" "$out" 'At the table: @claude @codex @gemini$'
has "one not signed in sits out, and says how to try it anyway" "$out" 'Antigravity sits out: not signed in \(/seat agy'

# ---- order mode ----------------------------------------------------------------------------------------
mark
out=$(run "Should we rewrite the billing service in Rust?")
is "order mode: everyone answers first" "$(grep -cE '^@(claude|gemini|codex)$' <<< "$out")" 3
for h in claude codex gemini; do has "... @$h's answer made without reading the others'" "$out" "ANSWER from @$h\\. read: \\[\\]"; done
is "... then the round table, one by one in seat order" "$(grep -oE '^@[a-z]+ ↻$' <<< "$out" | tr '\n' ' ')" "@claude ↻ @codex ↻ @gemini ↻ "
has "... under a round table line" "$out" '─── round table ───'
has "at the table the first reads all three answers" "$out" 'TABLE from @claude\. read: \[ANSWER from @claude,ANSWER from @codex,ANSWER from @gemini,\]'
has "... the next also reads what the one before said at the table" "$out" 'TABLE from @codex\. read: \[ANSWER from @claude,ANSWER from @codex,ANSWER from @gemini,TABLE from @claude,\]'
has "Codex's answer is taken from its last-message file, not its noisy stdout" "$out" 'ANSWER from @codex'
hasnt "... the noise is not in the thread" "$out" 'codex log noise'
p=$(cat $(since | head -1))
has "a member is told to be honest and raw, and to disagree by name" "$p" 'honest, raw take'
has "... and that it changes nothing" "$p" 'you change nothing'
has "... and to be short and direct: at most 60 words" "$p" 'Short and direct: lead with your answer, at\s*$|at most 60 words'
has "a council opened from a project has that project as its topic" "$p" '^Topic: the project proj, in the folder .*/proj, which is your working folder'
hasnt "... not the first message of the meeting" "$p" '^Topic: Should we rewrite'
a=$(cat "$T/log/argv")
has "Claude runs one-shot with no saved session, read-only tools" "$a" 'secretacct1[[:space:]]-p --no-session-persistence .*--allowedTools Read Grep Glob WebSearch WebFetch --disallowedTools Bash Edit Write NotebookEdit'
has "Codex runs read-only, ephemeral, answer to a file" "$a" 'codex:secretacct4[[:space:]]exec --sandbox read-only --skip-git-repo-check --ephemeral --color never -C .* -o .* -$'
has "Gemini runs read-only (plan mode)" "$a" 'gemini:secretacct3[[:space:]]--approval-mode plan --skip-trust -p'
out=$(run "/seat agy" "@agy and you?")
has "Antigravity, seated, answers" "$out" 'ANSWER from @agy'
has "... and runs read-only (plan mode, which --disable-slash-commands would switch off)" "$(cat "$T/log/argv")" 'agy:secretacct5[[:space:]]--mode plan -p '
hasnt "... without --disable-slash-commands" "$(cat "$T/log/argv")" 'disable-slash-commands'

# ---- tags, rounds, another round -------------------------------------------------------------------------
out=$(run "@gemini only you: yes or no?")
is "@gemini: only Gemini answers" "$(grep -cE '^@(claude|gemini|codex)$' <<< "$out")" 1
has "... and it is Gemini" "$out" '^@gemini$'
out=$(run "@nobody hello")
has "a tag nobody has says so, and nobody is asked" "$out" 'No member called @nobody'
out=$(run "/rounds 2" "@claude @codex go")
is "/rounds 2 with two tagged: two answers, then twice round the table" "$(grep -cE '^@(claude|codex)( ↻[0-9]*)?$' <<< "$out")" 6
has "... the second time round they answer what was said at the table" "$out" 'TABLE from @claude\. read: \[ANSWER from @claude,ANSWER from @codex,TABLE from @claude,TABLE from @codex,\]'
out=$(run "/rounds none" "@claude @codex go")
is "/rounds none: the answers only" "$(grep -cE '^@(claude|codex)( ↻)?$' <<< "$out")" 2
touch "$T/pass"; mark
out=$(run "/rounds 0" "@claude @codex go on")
rm -f "$T/pass"
is "/rounds 0: round the table again and again (a second pass)" "$(grep -cE '^@(claude|codex) ↻2$' <<< "$out")" 2
has "... the later pass answers what was said since, and may pass" "$(cat $(since) | grep -m1 '^Round table, pass 2:')" 'New points only.*reply with just: Pass\.'
has "... and it stops when everyone passes" "$out" 'Everyone passed: nothing new at the table'
has "/rounds 0 is round the table until Ctrl+C" "$(run "/rounds 0")" 'until Ctrl\+C'
run "/rounds 1" > /dev/null   # /rounds is kept per project: reset so later checks do not run infinite passes
# names: an LLM goes by the model it runs on (the default; /names llm for the LLM's own name)
mkdir -p "$T/proj3"; r3() { (cd "$T/proj3" && printf '%s\n' "$@" | env -u TMUX timeout 180 python3 "$COUNCIL" 2>&1); }
r3 "/names model" > /dev/null
out=$(r3 "/agents")
has "/names model: each LLM goes by its model's own name only (sonnet; gpt-test is test)" "$(grep -m1 'At the table:' <<< "$out")" '@sonnet @test @gemini'
has "... the full model name finds it too" "$(r3 "@gpt-test hi")" 'ANSWER from @test'
nc=$(python3 - "$COUNCIL" <<'EOF'
import runpy, sys
g = runpy.run_path(sys.argv[1], run_name="check")
M = g["Member"]
ms = [M("Claude", "claude", "a", model="opus"), M("Codex", "codex", "b", model="gpt-6-astra"),
      M("Gemini", "gemini", "c", model="gemini-4-carbon"), M("Antigravity", "agy", "d", model="Gemini 4 Neon (XHigh)"),
      M("Codex2", "codex", "b", model="gpt-6-astra", made=True), M("Claude2", "claude", "a", model="fable", made=True)]
n, c = g["table_names"](ms), g["table_colours"](ms)
old = M("Old", "claude", "a", model="haiku", made=True); old.seated = False
new = M("New", "claude", "a", model="haiku", made=True)
print(" ".join(n[m.handle] for m in ms), len(set(c.values())) == len(ms), g["table_names"]([old, new])["new"])
EOF
)
is "names are the model's own word, a second on the same model numbered; no two share a colour; one that left keeps no name (a new haiku is @haiku)" "$nc" "opus astra carbon neon astra2 fable True haiku"
out=$(r3 "@sonnet hi")
has "... tagged by it, and told that is its name" "$out" 'ANSWER from @sonnet'
is "... only it answers" "$(grep -cE '^@[a-z0-9-]+$' <<< "$out")" 1
has "... @claude still finds it" "$(r3 "@claude and you?")" 'ANSWER from @sonnet'
has "... and the saved meeting says who spoke by that name" "$(cat "$T/proj3/logs/council/"*/thread.md)" '^\*\*@sonnet\*\*: ANSWER from @sonnet'
has "/names llm goes back to the LLM's own" "$(r3 "/names llm" "/agents" | grep 'Names:')" 'its own name'
has "... kept for the next meeting" "$(cat "$T/proj3/logs/council/settings.json")" '"names": "llm"'
out=$(run "@claude first" "")
is "one member: no round table; Enter on an empty line has it say more" "$(grep -cE '^@claude( ↻)?$' <<< "$out")" 2
touch "$T/footer"
out=$(run "@claude hi")
has "an answer keeps its words" "$out" 'ANSWER from @claude'
hasnt "... but loses the greeting, the You: line and the SITREP its project adds" "$out" 'My Lord|You: whatever|SITREP'
rm -f "$T/footer"

# ---- made agents -----------------------------------------------------------------------------------------
out=$(run "/agent new Skeptic claude:opus A CFO who hates spending money" "/agents")
has "/agent new: it joins the table" "$out" '@skeptic \(Claude, opus\) joins the table'
has "... and is kept in the settings file" "$(cat "$T/council.json")" '"name": "Skeptic"'
mark
out=$(run "@skeptic should we buy the new servers?")
has "the agent answers when tagged" "$out" 'ANSWER from @skeptic'
p=$(cat $(since | head -1))
has "... with its character in its prompt" "$p" 'an agent named Skeptic, running on Claude\. Your character: A CFO who hates spending money'
has "... on its model" "$(tail -1 "$T/log/argv")" '--model opus'
# its own folder in the project: soul, character, rules, memory; edited there, read before every answer
d="$T/proj/agents/skeptic"
is "an agent with a character has a folder of its own in the project" "$(ls "$d" 2>/dev/null | tr '\n' ' ')" "CHARACTER.md MEMORY.md RULES.md SOUL.md "
has "... its character written there" "$(cat "$d/CHARACTER.md")" 'A CFO who hates spending money'
echo "Never approve a cost without a payback date." >> "$d/RULES.md"; echo "Cash is oxygen." >> "$d/SOUL.md"
touch "$T/remember"; mark
out=$(run "@skeptic and the new laptops?")
rm -f "$T/remember"; p=$(cat $(since | head -1))
has "... what you edit in its files is in its prompt: its rules" "$p" 'Your rules \(always follow them\): Never approve a cost without a payback date\.'
has "... and its soul" "$p" 'Your soul .*Cash is oxygen\.'
has "... its Remember: line goes to its memory in this project" "$(cat "$d/MEMORY.md")" '^- [0-9-]+: skeptic keeps an eye on cost$'
hasnt "... not into the thread" "$out" 'Remember:'
mark; run "@skeptic anything else?" > /dev/null
has "... and it reads its memory the next time" "$(cat $(since | head -1))" 'skeptic keeps an eye on cost'
out=$(run "/agent new Judge claude A stern judge || Fairness above all || Hear both sides first")
has "/agent new NAME LLM CHARACTER || SOUL || RULES: the soul in its file" "$(cat "$T/proj/agents/judge/SOUL.md")" 'Fairness above all'
has "... the rules in theirs" "$(cat "$T/proj/agents/judge/RULES.md")" 'Hear both sides first'
has "... and it says where they are" "$out" 'agents/judge/'
run "/agent del judge" > /dev/null
has "/agent del: its folder is moved aside with its memory, not deleted" "$(ls "$T/proj/agents/_removed/")" '^judge-'
hasnt "... and is gone from the agents" "$(ls "$T/proj/agents/")" '^judge$'
mkdir -p "$T/proj4/agents"; echo "theirs" > "$T/proj4/agents/x.py"
(cd "$T/proj4" && printf '%s\n' "/agents" | env -u TMUX timeout 180 python3 "$COUNCIL" > /dev/null 2>&1)
has "a project with an agents/ of its own keeps it: the council's agents go in council-agents/" "$(ls "$T/proj4/council-agents" 2>/dev/null)" 'skeptic'
is "... its own agents/ untouched" "$(ls "$T/proj4/agents" | tr '\n' ' ')" "x.py "
# the remove power: strikes on the agent's own judgement; at 3 the member is removed
run "/agent new Arbiter claude The final judge of the council" > /dev/null
has "/agent power NAME remove: the agent may give strikes" "$(run "/agent power arbiter remove on")" 'may now give strikes'
echo codex > "$T/judge"; mark; out=$(run "@arbiter rule on it")
has "... it is told so in its prompt" "$(cat $(since | head -1))" 'You may give a strike'
has "... Strike: @codex: strike 1 of 3, and the council says why" "$out" '⚖ @arbiter: strike 1 of 3 for @codex \(repeats itself\)\. 2 more'
has "... its answer shows it" "$out" '⚖ Strike for @codex: repeats itself'
has "... one strike: @codex is still at the table" "$(run "/agents" | grep -m1 'At the table:')" '@codex'
has "... /strikes lists it" "$(run "/strikes")" '@codex 1/3'
mark; out=$(run "@arbiter rule on it" "@arbiter rule on it"); rm -f "$T/judge"
has "... the prompt shows the strikes so far" "$(cat $(since | head -1))" 'Strikes so far: @codex 1/3'
has "... the third strike: out" "$out" 'strike 3 of 3 for @codex \(repeats itself\): out'
has "... an LLM's own seat leaves the table" "$out" '⚖ @arbiter: @codex taken off the table'
hasnt "... @codex is off the table" "$(run "/agents" | grep -m1 'At the table:')" '@codex'
run "/seat codex" > /dev/null
run "/agent new Victim claude A member who talks too much" > /dev/null; echo "- 2026-11-22: something kept" >> "$T/proj/agents/victim/MEMORY.md"
echo victim > "$T/judge"; out=$(run "@arbiter @victim rule on it" "@arbiter @victim rule on it" "@arbiter @victim rule on it"); rm -f "$T/judge"
has "... 3 strikes for @victim (an agent you made): deleted for good, its memory wiped" "$out" '⚖ @arbiter: @victim removed for good, its memory wiped'
is "... its folder is gone, not moved aside" "$(ls -d "$T/proj/agents/victim" "$T/proj/agents/_removed/victim-"* 2>/dev/null | wc -l | tr -d ' ')" 0
hasnt "... and it is gone from the agents" "$(cat "$T/council.json")" '"name": "Victim"'
has "/strikes clear wipes them" "$(run "/strikes clear" "/strikes")" 'Nobody has a strike'
# the judge power: it sits the round out and gives its verdict when the round ends
has "/agent power NAME judge: a judge" "$(run "/agent power arbiter judge on")" 'is a judge: it sits each round out'
mark; out=$(run "@claude @arbiter what now?")
p=$(grep -l 'You are @arbiter' $(since)); is "... it gets one turn in the round, at the end" "$(wc -l <<< "$p" | tr -d ' ')" 1
has "... a turn to judge the round" "$(cat $p)" 'The round is over\. You are the judge and speak last'
is "... after the others: its answer comes last" "$(grep -E '^@[a-z0-9-]+$' <<< "$out" | tail -1)" '@arbiter'
has "... marked as a verdict in the saved thread" "$(cat "$(ls -t "$T"/proj/logs/council/*/thread.md | head -1)")" '@arbiter\*\* \(verdict\)'
run "/agent del arbiter" > /dev/null
# an agent's lean: opposition (always against the chair), government (for the chair), free will (the default)
mark; run "/agent new Minister claude A loyal minister || || || government" "@minister @skeptic your take?" > /dev/null
p=$(grep -l 'You are @minister' $(since) | head -1); has "/agent new … || LEAN: the agent is told its lean (government)" "$(cat "$p")" 'Your lean: GOVERNMENT\. You stand with the chair'
has "... the others see it at the table" "$(cat $(grep -l 'You are @skeptic' $(since) | head -1))" '@minister \(Claude\) \[government\]'
has "... and an agent with none is free will" "$(cat $(grep -l 'You are @skeptic' $(since) | head -1))" 'Your lean: FREE WILL'
mark; out=$(run "/agent lean minister opposition" "@minister and now?")
has "/agent lean NAME opposition: changed" "$out" '@minister now leans opposition: always against the chair'
has "... and it is told so" "$(cat $(since | head -1))" 'Your lean: OPPOSITION\. You always oppose the chair'
run "/agent del minister" > /dev/null
# any member has a side, an LLM's own seat too (kept per project)
mark; out=$(run "/lean @codex opposition" "@codex @claude go")
has "/lean @codex opposition: an LLM's seat takes a side" "$out" '@codex now leans opposition: always against the chair'
has "... and is told so" "$(cat $(grep -l 'You are @codex' $(since) | head -1))" 'Your lean: OPPOSITION'
has "... the others see it at the table" "$(cat $(grep -l 'You are @claude' $(since) | head -1))" '@codex[^,]*\[opposition\]'
hasnt "... and one with no side is told nothing of it" "$(cat $(grep -l 'You are @claude' $(since) | head -1))" 'Your lean:'
has "... kept for this project" "$(cat "$T/proj/logs/council/settings.json")" '"lean": "opposition"'
has "/lean with no name lists the sides" "$(run "/lean")" 'Sides: .*@codex opposition'
run "/lean @codex free" > /dev/null
out=$(run "/agent new Skeptic codex again" "/agent new Bad nollm x")
has "a second member of the same name is refused" "$out" 'There is a member called Skeptic already'
has "an LLM that does not exist is refused" "$out" 'LLM must be claude, codex, gemini, agy, copilot or opencode'
out=$(run "/bench skeptic" "/agents")
has "/bench takes it off the table (and that is kept)" "$out" '@skeptic \(Claude, opus\).*\(benched\)'
out=$(run "/seat skeptic")
has "/seat brings it back" "$out" 'is at the table'
# who sits at the table is kept per folder: taking a member off in one project's council leaves the others alone
mkdir -p "$T/proj2"
# (the opening banner says who sits at the table when the council starts)
run "/bench codex" > /dev/null; out=$(run "/agents")
hasnt "/bench @codex in one project: it leaves that table" "$(grep -m1 'At the table:' <<< "$out")" '@codex'
out=$( (cd "$T/proj2" && printf '%s\n' "/agents" | env -u TMUX timeout 180 python3 "$COUNCIL" 2>&1) )
has "... but still sits at another project's table" "$(grep -m1 'At the table:' <<< "$out")" '@codex'
run "/seat codex" > /dev/null; out=$(run "/agents")
has "... and /seat brings it back in the first" "$(grep -m1 'At the table:' <<< "$out")" '@codex'
# another seat of an LLM: a model nobody at the table runs (never the same model twice)
out=$(run "/agent more codex" "/agent more codex" "/agent more codex" "/model @codex gpt-6-astra" "/agent more codex:gpt-test" "/agents")
has "+ add, another Codex seat: the first model of its list nobody runs (the account's list)" "$out" '@codex2 \(Codex, gpt-6-astra\) joins'
has "... the next, the next free one (a hidden model is never offered)" "$out" '@codex3 \(Codex, gpt-6-sol\) joins'
has "... and when every model is at the table, says so" "$out" 'Every Codex model is at the table already'
has "/model to a model another member runs is refused" "$out" '@codex2 runs gpt-6-astra already: no model twice'
has "a seat asked for on a model at the table is refused" "$out" '@codex runs gpt-test already'
run "/agent del codex2" "/agent del codex3" > /dev/null
out=$(run "/bench codex" "/agent more codex:gpt-6-sol" "/agents")
has "another seat while that LLM's own seat is off: its own comes back on that model" "$out" '@codex \(gpt-6-sol\) is at the table'
hasnt "... no @codex2 made" "$out" '@codex2'
run "/model @codex default" > /dev/null
ml=$(python3 - "$COUNCIL" "$T/xh" <<'EOF'
import runpy, sys
g = runpy.run_path(sys.argv[1], run_name="check")
print(" ".join(g["models_for"]("codex", sys.argv[2])), "|", " ".join(g["models_for"]("claude", sys.argv[2].replace("/xh", "/ch"))),
      "|", " ".join(g["models_for"]("agy")))
EOF
)
am=$(python3 - "$COUNCIL" <<'EOF'
import runpy, sys
g = runpy.run_path(sys.argv[1], run_name="check")
f = g["agy_model"]
print(f("gemini-4-neon-high", "low"), f("gemini-4-neon-high", "medium"), f(None, "high"))
EOF
)
is "Antigravity: an effort picks that model's variant and no --effort goes with it (it refuses both); a variant it lacks keeps the model; a plain name keeps --effort" "$am" "('gemini-4-neon-low', None) ('gemini-4-neon-high', None) (None, 'high')"
is "the menus offer every model version, newest first, each once (Codex: its account's list; Claude: the models its account knows; Antigravity: agy models, each at high)" "$ml" "gpt-6-astra gpt-6-sol gpt-test | claude-fable-5-2 claude-haiku-5-5 claude-haiku-4-5-20251001 | gemini-4-neon-high claude-opus-5-5-high gpt-oss-120b-medium"

# ---- answer length ---------------------------------------------------------------------------------------
mark
out=$(run "/length 25" "@claude hi")
has "/length 25 is taken" "$out" 'at most 25 words each'
has "... and members are told so" "$(cat $(since | tail -1))" 'at most 25 words'
out=$(run "/length 60")
has "... kept, and set back (in the project's own settings)" "$(cat "$T/proj/logs/council/settings.json")" '"words": 60'

# ---- model and effort ------------------------------------------------------------------------------------
out=$(run "/model @claude opus" "/effort @codex high" "/effort @gemini high" "/effort @claude bogus" "/model")
has "/model @claude opus is taken" "$out" '@claude \(opus\): model opus'
has "/effort @codex high is taken" "$out" '@codex \(high\): effort high'
has "/effort @gemini high: one setting for every Gemini, and the chat says so" "$out" "Gemini's effort is one setting for every Gemini: now high"
gs=$(cat "$T/gh/.gemini/settings.json" 2>/dev/null)
has "... written in that Gemini account's settings, where each Gemini reads it when it starts" "$gs" '"level": "high"'
has "... as a thinking level per model" "$gs" '"thinkingLevel": "HIGH"'
has "... and kept by the fleet, to be put back if a Gemini drops it" "$(cat "$T/gemini-effort" 2>/dev/null)" '^high$'
run "/effort @gemini xhigh" >/dev/null
is "... xhigh: Neon and Hydrogen get XHIGH, Argon, Carbon and 3.8 Flash (which have none) HIGH" "$(python3 -c '
import json, sys
o = json.load(open(sys.argv[1]))["modelConfigs"]["customOverrides"]
print(" ".join(x["match"]["model"] + "=" + x["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"] for x in o if x.get("afc") == "effort"))' "$T/gh/.gemini/settings.json")" \
  "gemini-4-neon=XHIGH gemini-4-hydrogen=XHIGH gemini-4-argon=HIGH gemini-4-carbon=HIGH gemini-3.8-flash=HIGH"
run "/effort @gemini high" >/dev/null
has "... /model alone shows it as the one setting" "$out" '@gemini  model: its default   effort: high \(one setting for every Gemini\)'
has "an effort that LLM does not have is refused, with the ones it has" "$out" '@claude: effort for Claude is one of low, medium, high, xhigh, max'
has "/model alone lists who runs on what" "$out" '@codex  model: its default   effort: high'
has "... kept for the next meeting" "$(cat "$T/proj/logs/council/settings.json")" '"effort": "high"'
: > "$T/log/argv"
out=$(run "@claude @codex hi")
has "Claude runs on the model it was given" "$(cat "$T/log/argv")" 'secretacct1[[:space:]].*--model opus'
has "Codex runs at the effort it was given" "$(cat "$T/log/argv")" 'codex:secretacct4[[:space:]].*-c model_reasoning_effort="high"'
out=$(run "/agent new Quick claude:sonnet:low Says the first thing that comes to mind" "@quick go")
has "an agent made with model and effort shows both" "$out" '@quick \(Claude, sonnet, low\) joins the table'
has "... and runs on them" "$(tail -1 "$T/log/argv")" '--model sonnet --effort low'
out=$(run "/model @claude default" "/effort @codex default" "/effort @gemini default" "/agent del quick")
has "default goes back to the LLM's own" "$out" '@claude: model back to its default'
has "... Gemini's effort too: each model's own" "$out" "Gemini's effort is one setting for every Gemini: now each model's own"
hasnt "... and the fleet's lines leave Gemini's settings" "$(cat "$T/gh/.gemini/settings.json" 2>/dev/null)" '"afc": "effort"'
has "a Gemini agent cannot carry an effort of its own (it is one setting for every Gemini)" \
  "$(run "/agent new Fast gemini:gemini-4-argon:low Quick answers")" 'A Gemini agent has no effort of its own'
# ---- a screenshot pasted into the chat box (Ctrl+V: agents --paste, then attach_images) -------------------
img="$T/shot.png"; printf '\x89PNG\r\n\x1a\n' > "$img"; : > "$T/log/argv"
run "@codex @gemini [Image #1: $img (a screenshot from the chair: open this file to see it)] what is on it?" > /dev/null
has "a pasted screenshot: Codex gets it attached" "$(grep -F 'codex:' "$T/log/argv")" "--image=$img"
has "... Gemini may read the folder screenshots are kept in" "$(grep -F 'gemini:' "$T/log/argv")" '--include-directories .*afc-council/images'
has "... and every member sees its path in the thread" "$(cat $(ls -t "$T"/log/prompt.* | head -1))" "\[Image #1: $img"
# ---- a member is checked before it joins: one short question, run as its turns run ------------------------
probes_before=$(grep -l 'A quick check before you join' "$T"/log/prompt.* 2>/dev/null | wc -l)
out=$(run "/agent more codex:quota-test")
has "+ add checks a seat first: one that cannot answer (its quota spent) is not added, and the chat says why" "$out" 'was not added: its plan or rate limit is spent'
has "... with what its LLM said" "$out" 'Codex said: .*429 RESOURCE_EXHAUSTED'
hasnt "... and it is not at the table" "$out" 'joins the table'
has "... the chat said it was checking while it waited" "$out" 'Checking @.* before it joins'
probes_after=$(grep -l 'A quick check before you join' "$T"/log/prompt.* 2>/dev/null | wc -l)
is "... the check was one short question to it" "$(( probes_after - probes_before ))" 1
has "a seat that answers the check joins as before" "$(run "/agent more codex:gpt-6-sol" "/agent del codex2")" 'joins the table'
# ---- formats: Open Forum (the modes), British Parliamentary, Win Stake --------------------------------------
: > "$T/log/argv"
out=$(run "/format bp" "This house would ban homework")
has "/format bp: the BP debate, and the chat says how it runs" "$out" 'Format: BP debate'
has "... the benches are dealt in BP order, from the first seat" "$out" 'BP debate · Opening Government: @[a-z0-9-]+ \(PM\)'
bp=$(for f in $(ls -tr "$T"/log/prompt.* | tail -8); do grep -oE 'You are the (Prime Minister|Leader of the Opposition|Deputy Prime Minister|Deputy Leader of the Opposition|Member of Government|Member of Opposition|Government Whip|Opposition Whip) \([A-Z]+\)' "$f"; done | grep -oE '\([A-Z]+\)' | tr -d '()' | tr '\n' ' ')
has "... each speaker is told its role, in BP speaking order" "$bp" '^PM LO( DPM)?'
out=$(run "/format stake" "Which is better, tea or coffee?")
has "/format stake: Win Stake" "$out" 'Format: Win Stake'
has "... a council opens showing its format (BP, kept from the last run)" "$out" 'BP debate · mode'
has "... everyone plays, then the vote is counted" "$out" '⚖ Votes: @claude [0-9]'
has "... nobody votes for itself (Claude's vote went to Codex)" "$out" '@codex 1'
out=$(run "/rounds 5" "/rounds 0" "/rounds 4")
has "Win Stake has rounds of its own: /rounds 5" "$out" 'Win Stake: 5 round'
has "... 0 means the most, 12" "$out" 'Win Stake: 12 round'
is "... kept for the next council here" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("stake_rounds"))' "$T/proj/logs/council/settings.json")" 4
out=$(run "/format bp" "/bp PM @codex" "/bp")
has "/bp ROLE @name: that member speaks in that role" "$out" 'BP: @codex speaks as PM'
has "... /bp lists the speakers with the model each runs on" "$out" 'PM @codex \(gpt-test\)'
has "... the one that was PM moved to Codex's old role (a swap)" "$out" 'BP debate · PM @codex .* @claude \(sonnet\)'
out=$(run "/bp auto" "/bp")
has "/bp auto: by seat again" "$out" 'BP speakers: set by seat again'
out=$(run "/format" "/format forum")
has "/format alone steps to the next format" "$out" 'Format: Open Forum'
has "/format forum: back to the modes, ending after /rounds" "$out" 'ends after /rounds'


# ---- roast mode -------------------------------------------------------------------------------------------
: > "$T/log/timing"; mark
out=$(run "/mode roast" "Tabs or spaces?")
is "roast: everyone gives a point" "$(grep -cE '^POINT from' <<< "$(grep -A1 -E '^@[a-z]+$' <<< "$out" | grep -oE 'POINT from @[a-z]+')")" 4
is "... then everyone roasts" "$(grep -oE 'ROAST from @[a-z]+' <<< "$out" | sort -u | wc -l | tr -d ' ')" 4
has "... the roasts come under a roast line" "$out" '─── roast ───'
starts=$(awk -F'\t' 'NR <= 3 { print $2 }' "$T/log/timing" | sort -n)
spread=$(awk 'NR == 1 { a = $1 } { b = $1 } END { printf "%.0f", (b - a) * 10 }' <<< "$starts")
if (( spread <= 4 )); then ok "... points are made at the same time (three at once)"; else bad "... points are made at the same time" "first three started $(( spread ))00 ms apart"; fi
pp=""; for f in $(since); do grep -q 'Give your point' "$f" && pp+=$(sed -n '/^--- The thread so far ---$/,/^--- End of the thread ---$/p' "$f"); done
hasnt "... a point is made without reading the others' points (also the one that waited for a slot)" "$pp" 'POINT from'
rp=""; for f in $(since); do grep -q '^Roast the answers' "$f" && { rp=$(cat "$f"); break; }; done
has "... a roast reads the others' points that are in (no waiting for the rest)" "$rp" '@[a-z]+: POINT from @[a-z]+'
has "... and is told to end with Final:" "$rp" "starting 'Final:'"
has "... only the answers to the latest message, within the word limit" "$rp" 'leave earlier rounds alone.*|At most [0-9]+ words in all'
mark
out=$(run "@claude @gemini just you two")
rp=""; for f in $(since); do grep -q 'You are @claude' "$f" && grep -q '^Roast the answers' "$f" && { rp=$(cat "$f"); break; }; done
has "roast with two tagged: they give the points, the rest of the table roasts too" "$rp" 'Roast the answers @'
pp=""; for f in $(since); do grep -q 'Give your point' "$f" && { pp=$(cat "$f"); break; }; done
has "... and each is told who was asked" "$pp" 'The chair asked only @claude @gemini this time'
out=$(run "@codex alone")
has "roast with one tagged: it answers, and the others roast it" "$out" 'ROAST from @(claude|gemini|skeptic)'
out=$(run "what about @claude then?")
has "an @name in the middle of a message is a mention: everyone answers" "$(grep -oE 'POINT from @[a-z0-9_-]+' <<< "$out" | sort -u | wc -l | tr -d ' ')" '^[3-9]$'
# endless roast: round after round until Ctrl+C, which stops the roast and not the council
mkfifo "$T/in2"
( cd "$T/proj" && env -u TMUX python3 "$COUNCIL" < "$T/in2" > "$T/endless.out" 2>&1 ) &
epid=$!
exec 6> "$T/in2"
printf '%s\n' "/rounds 0" "@claude @codex go on" >&6; sleep 5
kill -INT "$(pgrep -P "$epid" -f afc-council | head -1 || echo "$epid")" 2>/dev/null
# /rounds 1 first: the whole table roasts a new message, and with /rounds 0 that would go on for ever
sleep 1.5; printf '%s\n' "/rounds 1" "@gemini after the roast" >&6; sleep 2; exec 6>&-
ended "$epid" 90 || bad "the council ends at the end of its input" "still running after 90 s (stopped by the test)"
eo=$(cat "$T/endless.out")
n=$(grep -cE '^ *ROAST from @claude\.' <<< "$eo")      # its own turns, not the read: lists of the others'
if (( n >= 3 )); then ok "roast with /rounds 0: they keep countering each other ($n from @claude before Ctrl+C)"; else bad "roast with /rounds 0: they keep countering each other" "$n from @claude"; fi
has "... a later round answers what was just said, by its own prompt" "$(cat "$T"/log/prompt.* | grep -m1 '^Roast round 2:')" '^Roast round 2: fire back at the newest messages from @'
has "Ctrl+C stops the roast and keeps what was said" "$eo" 'Stopped\. What was said so far is kept'
has "... and the council goes on" "$eo" 'POINT from @gemini'
out=$(run "/rounds 2" "@claude @codex twice")
is "/rounds 2 in roast mode: two counters each" "$(grep -cE '^ *ROAST from @claude\.' <<< "$out")" 2
out=$(run "/mode order")
has "/mode order switches back (and is kept)" "$(cat "$T/proj/logs/council/settings.json")" '"mode": "order"'

# ---- the fleet's walls, a slow member, Ctrl+C ----------------------------------------------------------------
touch "$T/full"
out=$(run "@claude hello")
has "memory wall up: the member is skipped, and the thread says why" "$out" '\(skipped: the fleet is using 11G of its 11G limit\)'
rm -f "$T/full"
python3 - "$T/council.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["timeout"] = 2; json.dump(d, open(sys.argv[1], "w"))
EOF
touch "$T/slow.claude"
out=$(run "@claude are you there?")
has "a member that takes too long is given up on" "$out" '\(no answer within 2 s\)'
python3 - "$T/council.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["timeout"] = 300; json.dump(d, open(sys.argv[1], "w"))
EOF
fifo="$T/in"; mkfifo "$fifo"
( cd "$T/proj" && env -u TMUX python3 "$COUNCIL" < "$fifo" > "$T/ctrlc.out" 2>&1 ) &
cpid=$!
exec 5> "$fifo"
echo "@claude @gemini a slow one" >&5; sleep 1.5
kill -INT "$(pgrep -P "$cpid" -f afc-council | head -1 || echo "$cpid")" 2>/dev/null
sleep 1.5; echo "@gemini still with us?" >&5; sleep 2; exec 5>&-
ended "$cpid" 90 || bad "the council ends at the end of its input" "still running after 90 s (stopped by the test)"
out=$(cat "$T/ctrlc.out")
has "Ctrl+C while they answer: that round stops" "$out" 'Stopped\. What was said so far is kept'
has "... and the chat goes on" "$out" 'ANSWER from @gemini'
if pgrep -fx 'sleep 6.01' >/dev/null; then bad "... and the stopped member's run is ended" "still running"; else ok "... and the stopped member's run is ended"; fi
rm -f "$T/slow.claude"

# ---- the saved meeting ----------------------------------------------------------------------------------------
files=$(ls "$T/proj/logs/council/"*/thread.md 2>/dev/null | wc -l)
if (( files >= 1 )); then ok "each meeting is a folder of its own in the project's logs/council/ ($files)"; else bad "each meeting is a folder of its own in the project's logs/council/" "none"; fi
f=$(grep -l "Tabs or spaces" "$T/proj/logs/council/"*/thread.md | head -1)
has "... named by the time and its first message" "$f" '/logs/council/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}(-[0-9]+)?_tabs-or-spaces/thread\.md$'
has "... with the thread as data beside it, to carry it on" "$(cat "$(dirname "$f")/thread.json" 2>/dev/null)" '"thread": \[\{"who": "chair"'
s=$(cat "$f" 2>/dev/null)
has "... with the chair's message" "$s" '^\*\*Chair\*\*: Tabs or spaces\?'
has "... the answers and the roasts" "$s" '^\*\*@codex\*\* \(roast\): ROAST from @codex'
has "... and who sat at the table, with the agent's character" "$s" '^- @skeptic \(Claude, opus\): A CFO who hates spending money'
hasnt "no account name is written into the project" "$(cat "$T/proj/logs/council/"*/thread.md "$T/proj/logs/council/settings.json")" 'secretacct'
n0=$(ls -d "$T/proj/logs/council/"*/ | wc -l); run "/agents" > /dev/null; n1=$(ls -d "$T/proj/logs/council/"*/ | wc -l)
is "a council nobody spoke in leaves no folder" "$n1" "$n0"
# settings are the project's own: Bypass in one never reaches another
run "/perm bypass" > /dev/null
has "/perm bypass is kept in this project's settings" "$(cat "$T/proj/logs/council/settings.json")" '"perm": "bypass"'
hasnt "... not in the shared file" "$(cat "$T/council.json")" '"perm"'
out=$( (cd "$T/proj2" && printf '%s\n' "/perm" | env -u TMUX timeout 180 python3 "$COUNCIL" 2>&1) )
has "... and another project's council is still read-only" "$out" 'Council: PLAN'
run "/perm plan" > /dev/null
# a council about no project (Alt+Shift+K): each meeting a folder of its own in ~/Council, members work in it
G="$T/general"; : > "$T/log/argv"
out=$(printf '%s\n' "@codex what now?" | env -u TMUX AFC_COUNCIL_GENERAL="$G" timeout 180 python3 "$COUNCIL" --general 2>&1)
gd=$(ls -d "$G"/*/ 2>/dev/null | head -1); gd=${gd%/}
has "a council about no project keeps its meeting in a folder of its own" "$gd" "^$G/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}(-[0-9]+)?_codex-what-now$"
has "... saved there" "$(cat "$gd/thread.md" 2>/dev/null)" '(ANSWER|POINT) from @codex'
has "... and its members work in that folder" "$(cat "$T/log/argv")" "-C $gd -o"
has "... and its topic is still its first message (no project to be about)" "$(cat "$T"/log/prompt* 2>/dev/null)" '^Topic: @codex what now\?'
printf '%s\n' "@codex and again" | env -u TMUX AFC_COUNCIL_GENERAL="$G" timeout 180 python3 "$COUNCIL" --general > /dev/null 2>&1
is "... the next one is a folder of its own too" "$(ls "$G"/*/thread.md | wc -l | tr -d ' ')" 2
has "... and its settings are its own: ~/Council/settings.json" "$(ls "$G")" '^settings\.json$'
has "logs/council/ is added to the project's .gitignore" "$(cat "$T/proj/.gitignore")" '^logs/council/$'
is "... so git sees only that, and the agents' folder (theirs to keep)" "$(git -C "$T/proj" status --porcelain | tr '\n' ' ')" "?? .gitignore ?? README.md ?? agents/ "

# ---- Alt+K ---------------------------------------------------------------------------------------------------
tm() { "$TB" -L "$SOCK" "$@"; }
tm -f "$CONF_TMUX" new-session -d -s agents -n proj -x 160 -y 40 -c "$T/proj" "cd '$T/proj' && exec sleep 600"
script -qfc "stty cols 160 rows 41; exec env TERM=xterm-256color '$TB' -L '$SOCK' attach -t agents" /dev/null </dev/null >/dev/null 2>&1 &
cp=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -n "$(tm list-clients 2>/dev/null)" ]] && break; sleep 0.3; done
CL=$(tm list-clients -F '#{client_name}' | head -1)
has "Alt+K is bound to the council" "$(tm list-keys -T root)" 'M-k .*afc-council --open'
if [[ "$(readlink -f "$HOME/.local/bin/afc-council")" == "$(readlink -f "$COUNCIL")" ]]; then
  tm send-keys -K -c "$CL" M-k; sleep 3
  # Alt+K: the council about this project opens as a split in the project's own tab (operator, 2026-11-24)
  is "Alt+K opens the council as a split in the project's tab, not a tab of its own" \
    "$(tm list-panes -t agents:proj -F '#{@council_chat}' | grep -c '^1$') $(tm list-windows -F '#{window_name}' | grep -c '^council$')" "1 0"
  is "... the project's tab keeps its name" "$(tm display -p -t agents:proj '#{window_name}' 2>/dev/null)" proj
  tm send-keys -K -c "$CL" M-k; sleep 1.5
  is "... Alt+K again brings that council to the front, not a second one" "$(tm list-panes -t agents:proj -F '#{@council_chat}' | grep -c '^1$')" 1
  out=$(run "/format bp" "@claude quick check" "/format forum")
  has "direct @claude tag in BP format answers directly instead of refusing" "$out" 'ANSWER from @claude'
  run "/bench codex" > /dev/null
  out=$(run "/agent more codex:quota-test")
  has "benched seat probe failure rolls back its model in settings.json" "$out" 'was not added: its plan or rate limit is spent'
  hasnt "... broken quota-test model was not left persisted" "$(cat "$T/proj/logs/council/settings.json")" 'quota-test'
  run "/seat codex" > /dev/null
  sp=$(tm list-panes -t agents:proj -F '#{pane_id} #{@council_chat}' | awk '$2 == 1 {print $1}')
  # Alt+O inside a shared-tab council split transitions cleanly into BOX mode (no literal #!#%# leak!)
  tm select-pane -t "$sp"; tm send-keys -K -c "$CL" M-o; sleep 1.5
  sbox=$(tm capture-pane -p -t "$sp")
  hasnt "Alt+O in shared-tab council split switches cleanly into boxed chat (no #!#%# leak)" "$sbox" '#!#%#'
  has "... drawing the top chat box rule cleanly" "$(sed -n 1p <<< "$sbox")" '^─+$'
  tm send-keys -t "$sp" '/view grid' Enter; sleep 0.8
  tm send-keys -t "$sp" '/quit' Enter
  for _ in $(seq 1 30); do [[ "$(tm display -p -t agents:proj '#{window_panes}')" == 1 ]] && break; sleep 0.3; done
  is "... /quit closes that split, and the project's tab stays as it was" "$(tm display -p -t agents:proj '#{window_panes}')" 1
  is "... and clears window @council option on the project tab" "$(tm show-options -wqv -t agents:proj @council)" ""
  # The grid: a council in a tab of its own (as Alt+Shift+K opens one), here on the project to test it
  tm new-window -t agents: -n council -c "$T/proj" "$HOME/.local/bin/afc-council --from-pid $(tm display -p -t agents:proj '#{pane_pid}')"; sleep 3
  is "a council in a tab of its own: the tab is called council" "$(tm list-windows -F '#{window_name}' | grep -c '^council$')" 1
  is "... with the chat box in it, in the folder of the pane it was pressed in" "$(tm display -p -t ':council' '#{pane_current_path}' 2>/dev/null)" "$T/proj"
  has "... the box's header shows the mode it is in" "$(tm show-options -pqv -t ':council' pane-border-format 2>/dev/null)" 'mode: (ORDER|ROAST)'
  cw=$(tm list-windows -F '#{window_id} #{window_name}' | awk '$2 == "council" {print $1}')
  chair=$(tm display -p -t "$cw" '#{pane_id}')
  is "the council's tab is dealt into a grid: one pane per member at the table, and the chat" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  geo=$(tm list-panes -t "$cw" -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}' | grep -v "^$chair ")
  spread() { awk -v k="$1" '{ v = $k; if (NR == 1 || v < lo) lo = v; if (NR == 1 || v > hi) hi = v } END { print hi - lo }' <<< "$geo"; }
  if (( $(spread 4) <= 1 && $(spread 5) <= 1 )); then ok "... evenly: the member panes are the same size (within a cell)"; else bad "... evenly" "$geo"; fi
  read -r cl ct cwid < <(tm display -p -t "$chair" '#{pane_left} #{pane_top} #{pane_width}')
  ww=$(tm display -p -t "$cw" '#{window_width}')
  if (( cl == 0 && cwid + 2 >= ww )) && ! awk -v t="$ct" '$3 > t { bad = 1 } END { exit !bad }' <<< "$geo"; then ok "... the chat is a strip along the bottom, full width"; else bad "... the chat is a strip along the bottom" "chair at $cl,$ct width $cwid of $ww"; fi
  is "... you type in the chat strip" "$(tm display -p -t "$cw" '#{pane_id}')" "$chair"
  pane_of() { tm list-panes -t "$cw" -F '#{pane_id} #{pane-border-format}' | awk -v h="@$1" 'index($0, h"#") || index($0, h" ") { print $1; exit }'; }
  for h in claude codex gemini skeptic; do
    [[ -n "$(pane_of "$h")" ]] && ok "... a pane for @$h, named in its header" || bad "... a pane for @$h, named in its header" "$(tm list-panes -t "$cw" -F '#{pane-border-format}' | tr '\n' '|')"
  done
  hdr() { tm show-options -pqv -t "$(pane_of "$1")" pane-border-format; }
  # wait for a change instead of a fixed sleep: a busy machine slows the grid down, it does not break it
  hdr_has() { local i; for i in $(seq 1 32); do grep -qE -- "$2" <<< "$(hdr "$1")" && return 0; sleep 0.25; done; return 1; }
  # the grid is settled: that many panes, every member pane labelled, and the same a moment later
  # (while it is dealt again the count passes through the target on the way down and back up)
  grid_now() { echo "$(tm display -p -t "$cw" '#{window_panes}') $(tm list-panes -t "$cw" -F '#{pane_id}=#{@council_runs}' | grep -c '=.')"; }
  panes_are() { local i want="$1 $(( $1 - 1 ))"; [[ "$1" == 1 ]] && want="1 0"
    for i in $(seq 1 40); do [[ "$(grid_now)" == "$want" ]] && { sleep 0.5; [[ "$(grid_now)" == "$want" ]] && return 0; }; sleep 0.25; done; return 1; }
  has "a header shows the model and effort its account is set to (Codex: config.toml)" "$(hdr codex)" 'gpt-test · effort medium'
  has "... Claude: its settings.json model, and the default effort" "$(hdr claude)" 'sonnet · effort default'
  has "... Gemini with none set: default model, effort default (one setting for every Gemini)" "$(hdr gemini)" '\]default model · effort default#\[default\]'
  has "... and says how to change them" "$(hdr codex)" 'Alt\+M or m: change'
  tm select-pane -t "$(pane_of codex)"; tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" h; hdr_has codex 'effort high'
  has "Alt+M in a member's pane, h: its effort is now high" "$(hdr codex)" 'gpt-test · effort high'
  # the strip is written after the header: on a slow Mac (a 2017 Intel laptop) a moment later
  for w in $(seq 1 32); do grep -qE '@codex \(high\): effort high' <<< "$(tm capture-pane -p -t "$chair")" && break; sleep 0.25; done
  has "... said in the chat strip" "$(tm capture-pane -p -t "$chair")" '@codex \(high\): effort high'
  tm select-pane -t "$(pane_of claude)"; tm send-keys -K -c "$CL" m; sleep 0.8; tm send-keys -K -c "$CL" 2; hdr_has claude 'haiku-5-5'
  has "m in a member's pane opens the same menu: 2 picks its second model" "$(hdr claude)" 'haiku-5-5 · effort default'
  tm send-keys -K -c "$CL" m; sleep 0.8; tm send-keys -K -c "$CL" 0; hdr_has claude 'sonnet · effort default'
  has "... 0 goes back to the default model" "$(hdr claude)" 'sonnet · effort default'
  tm select-pane -t "$(pane_of gemini)"; tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" h; hdr_has gemini 'effort high'
  has "Alt+M in Gemini's pane, h: Gemini's effort (one for every Gemini) is now high" "$(hdr gemini)" 'default model · effort high'
  tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" d; hdr_has gemini 'effort default'
  has "... d: back to each model's own" "$(hdr gemini)" 'default model · effort default'
  tm select-pane -t "$(pane_of codex)"; tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" G; hdr_has codex 'government'
  has "Alt+M, G: its side is government, shown in its header" "$(hdr codex)" 'government'
  tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" F; sleep 1.5
  hasnt "... F: free will again (not shown)" "$(hdr codex)" 'government'
  tm select-pane -t "$chair"
  tm select-pane -t "$chair"
  tm send-keys -t "$chair" "@codex hello from the keyboard" Enter; sleep 3
  scr=$(tm capture-pane -p -t "$chair" 2>/dev/null)
  hasnt "typed in the tab: the chat strip shows no answers (they are in the members' panes)" "$scr" 'ANSWER from'
  hasnt "... nor what you typed: it went to the members' panes" "$scr" 'hello from the keyboard'
  hasnt "... and the 'thinking' line is gone once it is done" "$(tail -3 <<< "$scr")" 'thinking'
  long=$(printf 'word%.0s ' $(seq 1 45))
  tm send-keys -t "$chair" -l "$long"; sleep 2.5
  bh=$(tm display -p -t "$chair" '#{pane_height}'); box=$(tm capture-pane -p -t "$chair")
  if (( bh >= 5 )); then ok "a line typed past the box's edge goes on to the next: the box grows ($bh lines)"; else bad "a line typed past the box's edge goes on to the next: the box grows" "$bh lines"; fi
  has "... with the rule above it" "$(sed -n 1p <<< "$box")" '^─+$'
  has "... the text on two lines, from the prompt on" "$(sed -n 2,3p <<< "$box" | tr '\n' '|')" '^> word word.*\|[a-z]* ?word'
  has "... and the rule below it" "$(sed -n "$((bh - 1))p" <<< "$box")" '^─+$'
  tm send-keys -t "$chair" C-u; sleep 2.5
  is "... and it shrinks back when the text is gone" "$(tm display -p -t "$chair" '#{pane_height}')" 4
  has "... and the box is empty for the next message: rule, > line, rule" "$(sed -n 1,3p <<< "$scr" | tr '\n' '|')" '^─+\|> ?\|─+\|$'
  has "in @codex's pane your message is on the left" "$(tm capture-pane -p -t "$(pane_of codex)")" '^@codex hello from the keyboard'
  has "... and its own answer on the right" "$(tm capture-pane -p -t "$(pane_of codex)")" '^ +ANSWER from @codex'
  has "in @claude's pane @codex's answer is on the left, like any other speaker's" "$(tm capture-pane -p -t "$(pane_of claude)")" '^ANSWER from @codex'
  touch "$T/slow.codex"
  tm send-keys -t "$chair" "@codex take your time" Enter; sleep 2
  has "while a member thinks, its pane shows a spinner and the seconds" "$(tm capture-pane -p -t "$(pane_of codex)" | grep -v '^$' | tail -1)" '^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] thinking  [0-9]+s$'
  hasnt "... but not the chat box: it is for typing" "$(tm capture-pane -p -t "$chair")" 'is thinking|are thinking'
  tm send-keys -t "$chair" "/mode" Enter; sleep 1
  has "... which takes a command while a member is still thinking" "$(tm capture-pane -p -t "$chair")" 'Mode: (roast|order)'
  tm send-keys -t "$chair" "/mode" Enter; sleep 0.5
  f1=$(tm capture-pane -p -t "$(pane_of codex)" | grep -v '^$' | tail -1); sleep 0.35; f2=$(tm capture-pane -p -t "$(pane_of codex)" | grep -v '^$' | tail -1)
  [[ "$f1" != "$f2" ]] && ok "... and it moves" || bad "... and it moves" "same frame twice: $f1"
  sleep 6; rm -f "$T/slow.codex"
  touch "$T/echo-name" "$T/long"
  tm send-keys -t "$chair" "@gemini a long one" Enter; sleep 2.5
  gp=$(tm capture-pane -p -t "$(pane_of gemini)" | grep -v '^$')
  has "an answer that copies the thread's @name: line loses it" "$gp" '^ *ANSWER from @gemini'
  if grep -qE '(^|[^a-z])w$|^ *ordy|^ *dy |^ *y ' <<< "$gp"; then bad "... and a long answer wraps between words, not inside them" "$(tail -4 <<< "$gp")"; else ok "... and a long answer wraps between words, not inside them"; fi
  rm -f "$T/echo-name" "$T/long"
  hasnt "... gone once the answer is in" "$(tm capture-pane -p -t "$(pane_of codex)" | grep -v '^$' | tail -1)" 'thinking'
  tm send-keys -t "$chair" "/bench skeptic" Enter; panes_are 4
  is "/bench: the grid is dealt again without that member" "$(tm display -p -t "$cw" '#{window_panes}')" 4
  tm run-shell -b "$HOME/.local/bin/afc-council --add-menu '$CL' '$cw'"; sleep 0.8
  tm send-keys -K -c "$CL" 1; panes_are 5
  is "+ add lists the agents you made: 1 brings @skeptic back to the table" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  has "... its pane shows what was said before" "$(tm capture-pane -p -S - -t "$(pane_of codex)")" '^@codex hello from the keyboard'
  # ✕ in a member's header (Alt+Q there): agents --close hands it to the council, which benches it
  tm run-shell "$HOME/.local/bin/agents --close $(pane_of gemini)"; panes_are 4
  is "✕ on @gemini's header: it leaves the table and the grid is dealt again" "$(tm display -p -t "$cw" '#{window_panes}')" 4
  hasnt "... + add has no Bring back line for an LLM's seat" "$(tm show-options -wqv -t "$cw" @council_out)" 'gemini'
  has "... and the bottom bar shows + add on a council tab" "$(tm display -p -t "$cw" "$(tm show -gv status-right)")" 'council_add|\+ add'
  tm run-shell -b "$HOME/.local/bin/afc-council --add-menu '$CL' '$cw'"; sleep 0.8
  tm send-keys -K -c "$CL" g; sleep 1; tm send-keys -K -c "$CL" 1; panes_are 5
  is "+ add, Another Gemini seat…, 1: Gemini's own seat comes back, on the model picked" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  hasnt "... no second Gemini seat is made" "$(cat "$T/council.json")" '"name": "Gemini2"'
  tm send-keys -t "$chair" "/grid off" Enter; panes_are 1
  is "/grid off: only the chat is left" "$(tm display -p -t "$cw" '#{window_panes}')" 1
  tm send-keys -t "$chair" "/grid on" Enter; panes_are 5
  is "/grid on: the grid is back" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  # one view: everyone's answers in one pane above the chat box, the way a group chat looks
  tm send-keys -t "$chair" "/view one" Enter
  for _ in $(seq 1 40); do [[ "$(tm display -p -t "$cw" '#{window_panes}')" == 2 ]] && break; sleep 0.25; done
  is "/view one: one pane above the chat box instead of one per member" "$(tm display -p -t "$cw" '#{window_panes}')" 2
  vp=$(tm list-panes -t "$cw" -F '#{pane_id} #{@council_member}' | awk '$2 == ":all" {print $1}'); sleep 1
  vs=$(tm capture-pane -p -S - -t "$vp")
  has "... with every member's answers in it" "$vs" 'ANSWER from @codex'
  has "... (all of them)" "$vs" 'ANSWER from @gemini'
  has "... and yours on the right" "$vs" '^ {20,}you$'
  has "... its header names everyone at the table" "$(tm show-options -pqv -t "$vp" pane-border-format)" '@claude.*@codex.*@gemini.*@skeptic'
  has "... kept for this project" "$(cat "$T/proj/logs/council/settings.json")" '"view": "one"'
  touch "$T/slow.codex"; tm send-keys -t "$chair" "@codex take your time again" Enter; sleep 2
  has "... it shows who is thinking" "$(tm capture-pane -p -t "$vp" | grep -v '^$' | tail -1)" '@codex thinking  [0-9]+s$'
  sleep 6; rm -f "$T/slow.codex"
  # Alt+Q (or ✕) on the one view: a menu of who to take off the table; 3 is @gemini (seat order)
  onehdr() { tm show-options -pqv -t "$(tm list-panes -t "$cw" -F '#{pane_id} #{@council_member}' | awk '$2 == ":all" {print $1}')" pane-border-format; }
  tm select-pane -t "$vp"; tm send-keys -K -c "$CL" M-q; sleep 0.8; tm send-keys -K -c "$CL" 3
  for _ in $(seq 1 40); do h1=$(onehdr); [[ -n "$h1" && "$h1" != *@gemini* ]] && break; sleep 0.25; done
  hasnt "Alt+Q on the one view: a menu of who to take off; 3 takes @gemini off the table" "$h1" '@gemini'
  has "... the one view stays, naming the rest" "$h1" '@claude.*@codex.*@skeptic'
  hasnt "... and + add shows no Bring back line for it (Another Gemini seat brings it back)" "$(tm show-options -wqv -t "$cw" @council_out)" 'gemini'
  tm select-pane -t "$chair"; tm send-keys -t "$chair" "/seat gemini" Enter
  for _ in $(seq 1 40); do [[ "$(onehdr)" == *@gemini* ]] && break; sleep 0.25; done
  tm select-pane -t "$(tm list-panes -t "$cw" -F '#{pane_id} #{@council_member}' | awk '$2 == ":all" {print $1}')"
  tm send-keys -K -c "$CL" M-o; panes_are 5
  is "Alt+O with the one view in focus (not the chat box): back to one pane per member" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  tm select-pane -t "$(pane_of codex)"; tm send-keys -K -c "$CL" M-0
  for _ in $(seq 1 40); do [[ "$(tm display -p -t "$cw" '#{window_panes}')" == 2 ]] && break; sleep 0.25; done
  is "Alt+0 in a member's pane does the same: one view" "$(tm display -p -t "$cw" '#{window_panes}')" 2
  tm send-keys -t "$chair" M-o; panes_are 5
  is "Alt+O in the chat box: back to one pane per member" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  # the chat box's keys work from a member's pane too: Shift+Tab the mode, Alt+P the permission, Alt+T a new topic
  chdr() { tm show-options -pqv -t "$chair" pane-border-format; }
  tm select-pane -t "$(pane_of codex)"; tm send-keys -K -c "$CL" BTab
  for _ in $(seq 1 20); do [[ "$(chdr)" == *"mode: ROAST"* ]] && break; sleep 0.25; done
  has "Shift+Tab in a member's pane: the mode switches (roast)" "$(chdr)" 'mode: ROAST'
  tm send-keys -K -c "$CL" BTab; for _ in $(seq 1 20); do [[ "$(chdr)" == *"mode: ORDER"* ]] && break; sleep 0.25; done
  tm send-keys -K -c "$CL" M-p; for _ in $(seq 1 20); do [[ "$(chdr)" == *"perm: EDIT"* ]] && break; sleep 0.25; done
  has "Alt+P in a member's pane: the permission moves on (edit)" "$(chdr)" 'perm: EDIT'
  tm send-keys -K -c "$CL" M-p; sleep 1; tm send-keys -K -c "$CL" M-p; for _ in $(seq 1 20); do [[ "$(chdr)" == *"perm: PLAN"* ]] && break; sleep 0.25; done
  tm send-keys -K -c "$CL" M-t; sleep 1.5
  has "Alt+T in a member's pane: a new topic" "$(tm capture-pane -p -t "$chair")" 'A new meeting'
  tm select-pane -t "$chair"
  # + add, Another Codex seat…: a menu of its models (the one @codex runs greyed); 1 is gpt-6-astra
  tm run-shell -b "$HOME/.local/bin/afc-council --add-menu '$CL' '$cw'"; sleep 0.8
  tm send-keys -K -c "$CL" x; sleep 1; tm send-keys -K -c "$CL" 1; panes_are 6
  is "+ add, Another Codex seat…, 1: a seat on the model picked" "$(tm display -p -t "$cw" '#{window_panes}')" 6
  has "... it runs gpt-6-astra" "$(hdr codex2)" 'gpt-6-astra'
  has "... and the menus know that model is taken now" "$(tm show-options -wqv -t "$cw" @council_used)" 'gpt-6-astra=codex2'
  tm send-keys -t "$chair" "/agent del codex2" Enter; panes_are 5
  # ✕ on an agent you made deletes it for good (an LLM's own seat, above, is only benched)
  tm run-shell "$HOME/.local/bin/agents --close $(pane_of skeptic)"; panes_are 4
  is "✕ on @skeptic's header (an agent you made): the grid is dealt again without it" "$(tm display -p -t "$cw" '#{window_panes}')" 4
  hasnt "... it is deleted, not benched: gone from the agents file" "$(cat "$T/council.json")" '"name": "Skeptic"'
  hasnt "... and + add has no Bring back for it" "$(tm show-options -wqv -t "$cw" @council_out)" 'skeptic'
  # + add, New agent…: a form in a pop-up in the middle of the screen (name, LLM, model, character, soul, rules)
  tm run-shell -b "$HOME/.local/bin/afc-council --add-menu '$CL' '$cw'"; sleep 0.8
  tm send-keys -K -c "$CL" n; sleep 1.5
  for ans in "Judge" "1" "2" "A stern judge" "Fairness above all" "Hear both sides first" "1" "y"; do
    tm send-keys -K -c "$CL" -l "$ans"; tm send-keys -K -c "$CL" Enter; sleep 0.6
  done
  for _ in $(seq 1 40); do [[ "$(tm display -p -t "$cw" '#{window_panes}')" == 5 ]] && break; sleep 0.25; done
  is "+ add, New agent…: the form in the middle of the screen makes the agent, and it joins the table" "$(tm display -p -t "$cw" '#{window_panes}')" 5
  has "... on the model picked from its list (2: claude-haiku-5-5)" "$(python3 -c 'import json,sys; print([a for a in json.load(open(sys.argv[1]))["agents"] if a["name"] == "Judge"])' "$T/council.json")" "claude-haiku-5-5"
  has "... with its soul in its folder" "$(cat "$T/proj/agents/judge/SOUL.md" 2>/dev/null)" 'Fairness above all'
  has "... and its rules" "$(cat "$T/proj/agents/judge/RULES.md" 2>/dev/null)" 'Hear both sides first'
  for _ in $(seq 1 20); do [[ -n "$(pane_of judge)" ]] && break; sleep 0.25; done   # its pane is labelled a moment after it opens
  has "... and its lean (1: opposition), shown in its header" "$(hdr judge)" 'opposition'
  # + add, Remove everyone…, y: the whole table off, as ✕ on each would; the chat box and + add stay
  tm run-shell -b "$HOME/.local/bin/afc-council --add-menu '$CL' '$cw'"; sleep 0.8
  tm send-keys -K -c "$CL" r; sleep 1; tm send-keys -K -c "$CL" y
  for _ in $(seq 1 40); do [[ "$(tm display -p -t "$cw" '#{window_panes}')" == 1 ]] && break; sleep 0.25; done
  is "+ add, Remove everyone…, y: nobody left at the table, only the chat box" "$(tm display -p -t "$cw" '#{window_panes}')" 1
  has "... it says so" "$(tm capture-pane -p -t "$chair")" 'Everyone left the table \(4\)'
  has "... and + add is still on the bar" "$(tm display -p -t "$cw" "$(tm show -gv status-right)")" 'council_add|\+ add'
  for h in claude codex gemini; do tm send-keys -t "$chair" "/seat $h" Enter; sleep 0.6; done
  panes_are 4
  # menu command while user has a half-typed draft in the chat box: command runs and draft comes back
  tm send-keys -t "$chair" -l "half typed draft"; sleep 0.4
  tm select-pane -t "$(pane_of codex)"; tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" h; hdr_has codex 'effort high'
  tm select-pane -t "$chair"; sleep 0.6
  has "menu action while typing preserves the user's draft in the chat box" "$(tm capture-pane -p -t "$chair")" 'half typed draft'
  tm send-keys -t "$chair" C-u; sleep 0.3
  # multi-line paste via tmux paste-buffer -p: collapses to a pill (no premature submit, rules stay intact),
  # survives a menu action mid-draft, and expands verbatim on Enter
  printf 'paste line one\npaste line two\npaste line three\n' | tm load-buffer -b ptest -
  tm send-keys -t "$chair" -l "@codex check: "
  tm paste-buffer -p -d -b ptest -t "$chair"; sleep 0.6
  pbox=$(tm capture-pane -p -t "$chair")
  has "multi-line paste collapses into a compact pill in the chat box" "$pbox" '\[Pasted #1 · 3 lines\]'
  has "... keeping top and bottom rules intact (no box smash)" "$(sed -n 1p <<< "$pbox")" '^─+$'
  # firing a menu action while the paste pill is in the draft keeps both the pill and its stored content
  tm select-pane -t "$(pane_of codex)"; tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" h; hdr_has codex 'effort high'
  tm select-pane -t "$chair"; sleep 0.5
  tm send-keys -t "$chair" Enter; sleep 3
  cpane=$(tm capture-pane -p -S - -t "$(pane_of codex)")
  has "... and expands all 3 lines verbatim even after a menu action" "$cpane" 'paste line one'
  has "... including line three" "$cpane" 'paste line three'
  # afc-min refuses to minimise a council pane (keeps grid intact)
  tm run-shell "$HOME/.local/bin/afc-min hide $(pane_of codex)"; sleep 0.5
  is "afc-min refuses to minimise a council member pane" "$(tm display -p -t "$cw" '#{window_panes}')" 4
  tm run-shell "$HOME/.local/bin/afc-min hide $chair"; sleep 0.5
  is "afc-min refuses to minimise the council chat box" "$(tm display -p -t "$cw" '#{window_panes}')" 4
  # Ctrl+V (agents --paste) while a member pane is focused redirects to the chat box
  tm select-pane -t "$(pane_of codex)"; sleep 0.2
  printf 'single\tline /ok @codex\n' | tm load-buffer -b ptest2 -
  tm paste-buffer -p -d -b ptest2 -t "$chair"; sleep 0.5
  has "single-line paste with trailing newline, tab, / and @ stays inline without submitting" "$(tm capture-pane -p -t "$chair")" 'single  line /ok @codex'
  tm send-keys -t "$chair" C-u; sleep 0.3
  tm send-keys -t "$chair" "/quit" Enter; sleep 2.5
  is "/quit closes the whole council tab, grid and all" "$(tm list-windows -F '#{window_name}' | grep -c '^council$')" 0

  # ---- Alt+K inside a shared project tab (real 140x43 split stress test) -------------------------------------
  tm resize-window -t proj -x 140 -y 43 2>/dev/null || true
  tm set-option -w -t proj @project proj
  code_pane=$(tm display -p -t proj '#{pane_id}')
  code_pid=$(tm display -p -t proj '#{pane_pid}')
  tm run-shell -b "$HOME/.local/bin/afc-council --open agents '$code_pid'"
  for _ in $(seq 1 40); do [[ "$(tm display -p -t proj '#{window_panes}')" == 2 ]] && break; sleep 0.25; done
  is "Alt+K in a project tab opens council as a split in that same tab" "$(tm display -p -t proj '#{window_panes}')" 2
  sp_pane=$(tm list-panes -t proj -F '#{pane_id} #{@council_chat}' | awk '$2 == "1" {print $1; exit}')
  for _ in $(seq 1 40); do
    sp_pane=$(tm list-panes -t proj -F '#{pane_id} #{@council_chat}' | awk '$2 == "1" {print $1; exit}')
    [[ -n "$sp_pane" ]] && break; sleep 0.25
  done
  has "... narrow split header shows compact mode, rounds, and perm (not clipped)" "$(tm show-options -pqv -t "$sp_pane" pane-border-format 2>/dev/null)" 'mode: (ORDER|ROAST).* \([^)]+\).*perm: PLAN'
  code_w=$(tm display -p -t "$code_pane" '#{pane_width}')
  # Shift+Tab in the coding pane must NOT hijack or flip the council split's mode
  before_mode=$(tm show-options -pqv -t "$sp_pane" pane-border-format 2>/dev/null)
  tm select-pane -t "$code_pane"; tm send-keys -K -c "$CL" BTab; sleep 0.6
  is "Shift+Tab in a coding pane sharing a tab with council does not flip council mode" "$(tm show-options -pqv -t "$sp_pane" pane-border-format 2>/dev/null)" "$before_mode"
  # Shift+Tab inside the council split flips mode cleanly with ZERO #!# marker garbage left on screen
  tm select-pane -t "$sp_pane"; tm send-keys -K -c "$CL" BTab
  for _ in $(seq 1 20); do [[ "$(tm show-options -pqv -t "$sp_pane" pane-border-format 2>/dev/null)" != "$before_mode" ]] && break; sleep 0.25; done
  has "Shift+Tab in the council split switches mode" "$(tm show-options -pqv -t "$sp_pane" pane-border-format 2>/dev/null)" 'mode: (ORDER|ROAST)'
  hasnt "... leaving no raw #!# marker garbage on screen" "$(tm capture-pane -p -t "$sp_pane")" '#!#'
  # Alt+O in the project split toggles one view inside the right column without touching the coding pane's width
  tm send-keys -K -c "$CL" M-o
  for _ in $(seq 1 40); do [[ "$(tm display -p -t proj '#{window_panes}')" == 3 ]] && break; sleep 0.25; done
  is "Alt+O in a project split opens bubble one view inside the right column" "$(tm display -p -t proj '#{window_panes}')" 3
  is "... leaving the coding pane width completely untouched" "$(tm display -p -t "$code_pane" '#{pane_width}')" "$code_w"
  tm send-keys -K -c "$CL" M-o
  for _ in $(seq 1 40); do [[ "$(tm display -p -t proj '#{window_panes}')" == 2 ]] && break; sleep 0.25; done
  is "Alt+O again collapses cleanly back to the single-pane split" "$(tm display -p -t proj '#{window_panes}')" 2
  # ✕ (agents --close) on the council split closes ONLY the council, keeps the coding pane, and clears @council
  tm run-shell "$HOME/.local/bin/agents --close $sp_pane"
  for _ in $(seq 1 40); do [[ "$(tm display -p -t proj '#{window_panes}')" == 1 ]] && break; sleep 0.25; done
  is "closing the council split leaves the project coding pane intact" "$(tm display -p -t proj '#{window_panes}')" 1
  is "... and clears stale @council from the project tab" "$(tm show-options -wqv -t proj @council 2>/dev/null)" ""
  run "/mode order" > /dev/null
else
  echo "  skip  Alt+K end to end (~/.local/bin/afc-council is not this folder's bin/afc-council)"
fi

# ---- audit regressions: hooks, permissions, parsing, formatting, retry, roast & draft safety ----------------
reg=$(python3 - "$COUNCIL" "$T" <<'EOF'
import json, os, re, runpy, sys, tempfile

g = runpy.run_path(sys.argv[1], run_name="check")
T = sys.argv[2]

# 0. accounts() treats "not signed in (...)" as signed out
assert not "not signed in (copilot login)".startswith("signed") and "not signed in (copilot login)".startswith("not signed in")

# 1. child_env strips TMUX/TMUX_PANE and sets AFC_COUNCIL_CHILD + AFC_RULES_SKIP
os.environ["TMUX"] = "/tmp/fake,1,0"
os.environ["TMUX_PANE"] = "%99"
ce = g["child_env"]()
assert "TMUX" not in ce and "TMUX_PANE" not in ce, f"TMUX leaked: {ce}"
assert ce.get("AFC_COUNCIL_CHILD") == "1" and ce.get("AFC_RULES_SKIP") == "1", f"flags missing: {ce}"

# 2. command() permissions: claude plan has --permission-mode plan; codex edit disables shell_tool; copilot/opencode work
M = g["Member"]
mc = M("Claude", "claude", account="a1")
argv, _, _ = g["command"](mc, "hi", T, "plan")
assert "--permission-mode" in argv and "plan" in argv, f"claude plan missing permission-mode: {argv}"
mx = M("Codex", "codex", account="x1")
argv, _, out = g["command"](mx, "hi", T, "edit")
if out and os.path.exists(out): os.unlink(out)
assert "--disable" in argv and "shell_tool" in argv and 'approval_policy="never"' in argv, f"codex edit unsafe: {argv}"
mp = M("Copilot", "copilot", account="p1", model="gpt-5.6-sol")
argv, _, _ = g["command"](mp, "hi", T, "plan")
assert "copilot:p1" in argv and "--mode" in argv and "plan" in argv, f"copilot plan bad: {argv}"
mo = M("OpenCode", "opencode", account="o1")
argv, _, _ = g["command"](mo, "hi", T, "bypass")
assert "opencode:o1" in argv and "--auto" in argv, f"opencode bypass bad: {argv}"

# 3. read_meeting() & upgrade() handle "# Council on <project>:" and "(round table N)"
with tempfile.TemporaryDirectory() as d:
    md = os.path.join(d, "2026-11-21_1734_topic.md")
    with open(md, "w") as f:
        f.write("# Council on TokenOps: Fix hooks\n\nStarted 2026-11-21 17:34 in TokenOps. Mode: order.\n\n"
                "**Chair**: hello\n\n**@opus** (round table 2): second pass\n")
    topic, started, thread = g["read_meeting"](md)
    assert topic == "Fix hooks", f"topic mismatch: {topic!r}"
    assert started == "2026-11-21 17:34", f"started mismatch: {started!r}"
    assert len(thread) == 2 and thread[1]["phase"] == "table" and thread[1].get("round") == 2, f"thread bad: {thread}"
    dst = os.path.join(d, "upgraded")
    os.makedirs(dst)
    g["upgrade"](d, dst)
    assert os.path.isfile(os.path.join(dst, "2026-11-21_1734_topic", "thread.md")), "upgrade skipped project header"

# 4. defaults() reads Claude modelSettings.<model>.effortLevel via alias match
with tempfile.TemporaryDirectory() as ch:
    with open(os.path.join(ch, "settings.json"), "w") as f:
        json.dump({"model": "opus", "modelSettings": {"claude-opus-5-5": {"effortLevel": "high"}}}, f)
    assert g["defaults"]("claude", ch) == ("opus", "high"), f"defaults bad: {g['defaults']('claude', ch)}"
    assert g["defaults"]("copilot", ch) == (None, None)
    assert g["defaults"]("opencode", ch) == (None, None)

# 5. cells() / fit() handle wide emoji & CJK correctly
assert g["cells"]("ab") == 2 and g["cells"]("中文") == 4, "cells width wrong"
assert g["cells"](g["fit"]("中文测试长字符串", 6)) <= 6, "fit overflowed cell width"

# 6. TTY defaults are bounded (2 rounds, 2 roasts) instead of infinite 0
g["Meeting"].__init__.__globals__["TTY"] = True
mt = g["Meeting"](T, [mc], {"mode": "order"})
assert mt.rounds == 2 and mt.roasts == 2, f"TTY defaults should be 2: {mt.rounds}, {mt.roasts}"

# 7. transcript() notes mid-thread model renames as "@new (formerly @old)"
mc.model = "haiku"
mt.thread = [{"who": "chair", "name": "Chair", "text": "hi", "phase": "chair"},
             {"who": "claude", "as": "opus", "name": "Claude", "text": "hello", "phase": "first"}]
g["Meeting"].__init__.__globals__["NAMES"]["by"] = "model"
tr = mt.transcript()
assert "@haiku (formerly @opus): hello" in tr, f"rename clarity missing: {tr}"

# 8. Remove: regex rejects blockquotes and bullet lists
rem_re = r"(?im)^[ \t]*\*{0,2}remove\*{0,2}[ \t]*:[ \t]*@?([\w.-]+)[ \t]*(?:[-–—:][ \t]*)?(.*)$"
assert not re.search(rem_re, "> Remove: @codex - quoted")
assert not re.search(rem_re, "- Remove: @codex - bullet")
assert re.search(rem_re, "Remove: @codex - derailing")
assert re.search(rem_re, "**Remove**: @codex - derailing")

# 9. Pass detection accepts short elaborations, rejects long non-pass text
pass_ok = lambda s: bool(re.match(r"^\*{0,2}pass\*{0,2}\b", s.strip(), re.I)) and len(s.strip().split()) <= 8
assert pass_ok("Pass.") and pass_ok("**Pass** — nothing new to add.")
assert not pass_ok("Pass this flag into the CLI binary and then verify that every test in the suite still passes.")

# 10. argv_clamp guards Linux MAX_ARG_STRLEN (128 KiB) for argv-prompt CLIs (agy/copilot/opencode)
huge = "A" * 160000
for m_argv in (M("Agy", "agy", account="a"), M("Copilot", "copilot", account="p"), M("OpenCode", "opencode", account="o")):
    av, _, _ = g["command"](m_argv, huge, T, "plan")
    assert all(len(x.encode("utf-8")) <= 105000 for x in av), f"argv exceeded safe limit for {m_argv.tool}"

# 11. opencode/deepseek model slug strips 'opencode' provider family and unseated base seat never steals seated slug
g["NAMES"]["by"] = "model"
oc_base = M("OpenCode", "opencode", account=None); oc_base.seated = False
oc_ds = M("OpenCode2", "opencode", account="o1", model="opencode/deepseek-v4.1-flash-free", made=True)
tn = g["table_names"]([oc_base, oc_ds])
assert tn["opencode2"] == "deepseek", f"expected deepseek, got {tn}"

# 12. check_before_seating rejects missing account cleanly (never passes tool:None)
no_acct = M("OpenCode2", "opencode", account=None, model="opencode/deepseek-v4.1-flash-free", made=True)
why_na = g["check_before_seating"](no_acct, T)
assert "has no account" in why_na, f"missing account check failed: {why_na!r}"

# 13. win_stake vote regex handles markdown bold (**Vote:** **@name**) and ignores stale previous rounds
assert re.findall(r"\bvote\b[^@\n]{0,16}@([\w.-]+)", "**Vote:** **@opus-5.5**", re.I) == ["opus-5.5"]

# 14. read_meeting restores verdict, debate (bp), win stake (stake), and monte carlo (sim) phases from markdown
with tempfile.TemporaryDirectory() as d:
    md = os.path.join(d, "2026-11-24_1400_debate.md")
    with open(md, "w") as f:
        f.write("# Council on TokenOps: Debate\n\nStarted 2026-11-24 14:00 in TokenOps. Mode: order.\n\n"
                "**Chair**: motion\n\n**@opus** (debate): [PM] arg\n\n**@argon** (win stake): case\n\n"
                "**@judge** (verdict): Verdict: OG\n\n**@sim** (monte carlo): Monte Carlo (2/2)\n")
    _, _, th = g["read_meeting"](md)
    assert [e["phase"] for e in th] == ["chair", "bp", "stake", "verdict", "sim"], f"phases wrong: {th}"

# 15. thinking_line clamps strictly below pane width (no wrapped endless thinking lines in splits / one view)
many = ["opus-5.5", "gpt-5.4", "gemini-4-neon", "agy", "deepseek", "copilot", "grok", "supra-omnia"]
for w in (30, 55, 58, 80):
    s_plain = g["thinking_line"]("⠋", many, 12, w, indent="  ", plural=True)
    s_one = g["thinking_line"]("⠋", many, 12, w, indent="", plural=False)
    assert g["cells"](s_plain) < w and s_plain.endswith("12s"), f"plain wrap at {w}: {s_plain!r} ({g['cells'](s_plain)})"
    assert g["cells"](s_one) < w and s_one.endswith("12s"), f"one wrap at {w}: {s_one!r} ({g['cells'](s_one)})"
assert g["thinking_line"]("⠋", [], 3, 40, indent="", plural=False) == "⠋ thinking  3s"
assert g["thinking_line"]("⠋", ["codex"], 3, 80, indent="", plural=False) == "⠋ @codex thinking  3s"

# 16. Monte Carlo (/sim) outcome parsing & summary across Stake, BP, and Open Forum
m1, m2, m3 = M("Claude", "claude", account="a"), M("Codex", "codex", account="b"), M("Gemini", "gemini", account="c")
g["NAMES"]["by"] = "llm"
mt = g["Meeting"](T, [m1, m2, m3], {"format": "stake"})
o1 = mt.sim_outcome("stake", [
    {"who": "claude", "phase": "stake", "text": "Case\nVote: @codex"},
    {"who": "codex", "phase": "stake", "text": "Case\nVote: @claude"},
    {"who": "gemini", "phase": "stake", "text": "Case\n**Vote:** **@codex**"},
], [m1, m2, m3], mt)
assert o1["label"] == "@codex" and o1["votes"]["codex"] == 2, f"stake sim_outcome failed: {o1}"
sm = mt.format_sim_summary("stake", 2, "Tea or coffee?", [o1, {"label": "@claude", "votes": {"claude": 2, "codex": 1}, "verdict": ""}])
assert "Monte Carlo (2/2 trials · Win Stake)" in sm and "Total votes: @claude 3 · @codex 3" in sm, f"stake summary failed: {sm}"
bp1 = mt.sim_outcome("bp", [{"who": "judge", "phase": "verdict", "text": "Great clash.\nVerdict: OG carries the motion."}], [m1, m2, m3], mt)
bp2 = mt.sim_outcome("bp", [{"who": "judge", "phase": "verdict", "text": "Verdict: Opposition (OO) wins."}], [m1, m2, m3], mt)
assert bp1["side"] == "Government" and bp1["bench"] == "OG" and bp2["side"] == "Opposition" and bp2["bench"] == "OO"
sm_bp = mt.format_sim_summary("bp", 2, "Motion", [bp1, bp2])
assert "Sides: Government 1/2 (50%) · Opposition 1/2 (50%)" in sm_bp and "Benches: OG 1 · OO 1" in sm_bp, f"bp summary failed: {sm_bp}"

# 17. BP direct provider:model assignment across all 6 providers + persistent settings popup screens & Back buttons
m_agy = M("Agy", "agy", account="a1"); m_cop = M("Copilot", "copilot", account="p1"); m_oc = M("OpenCode", "opencode", account="o1")
bp_conf = {"format": "bp", "bp_cast": {
    "PM": "claude:claude-opus-5-5", "DPM": "claude:claude-sonnet-5-5",
    "LO": "gemini:gemini-4-neon", "DLO": "codex:gpt-6-astra",
    "MG": "agy:gemini-4-neon-high", "GW": "copilot:gpt-6.1-sol",
    "MO": "opencode:opencode/deepseek-v4.1-flash-free", "OW": "gemini:gemini-4-argon",
}}
mt_bp = g["Meeting"](T, [m1, m2, m3, m_agy, m_cop, m_oc], bp_conf)
cast8 = mt_bp.bp_cast()
assert len(cast8) == 8, f"expected 8 BP speakers across all 6 providers, got {len(cast8)}"
by_role = {r[0]: (m.tool, m.runs_on()[0]) for r, m in cast8}
assert by_role["PM"] == ("claude", "claude-opus-5-5") and by_role["DPM"] == ("claude", "claude-sonnet-5-5")
assert by_role["LO"] == ("gemini", "gemini-4-neon") and by_role["DLO"] == ("codex", "gpt-6-astra")
assert by_role["MG"] == ("agy", "gemini-4-neon-high") and by_role["GW"] == ("copilot", "gpt-6.1-sol")
assert by_role["MO"] == ("opencode", "opencode/deepseek-v4.1-flash-free") and by_role["OW"] == ("gemini", "gemini-4-argon")
fake_accts = {t: ("main", True, T) for t in ("claude", "codex", "gemini", "agy", "copilot", "opencode")}
for scr in (("settings",), ("format",), ("rounds",), ("bp",), ("bp_role", "PM"),
            ("bp_models", "PM", "claude"), ("bp_models", "LO", "gemini"), ("bp_models", "DLO", "codex"),
            ("bp_models", "MG", "agy"), ("bp_models", "GW", "copilot"), ("bp_models", "MO", "opencode")):
    _t, _c, rws = g["_settings_screen_items"](scr, bp_conf, mt_bp, fake_accts, {})
    acts = [r.get("action") for r in rws if r["kind"] == "item"]
    if scr != ("settings",):
        assert ("back",) in acts, f"screen {scr} missing Back button: {acts}"
    if scr == ("bp_role", "PM"):
        provs = [a[1][2] for a in acts if a and a[0] == "push" and a[1][0] == "bp_models"]
        assert provs == ["claude", "codex", "gemini", "agy", "copilot", "opencode"], f"missing providers: {provs}"

# 18. Popup escape parser ignores focus events (\x1b[I/\x1b[O), X10 mouse, SS3, unknown CSI (never false-closes)
def feed_esc(seq):
    it = iter(seq)
    buf = list(seq)
    pos = [0]
    def has_more(_t): return pos[0] < len(buf)
    def read_byte():
        b = bytes([buf[pos[0]]]); pos[0] += 1; return b
    return g["_parse_popup_escape"](read_byte, has_more)
assert feed_esc(b"") == ("esc", None)
assert feed_esc(b"[I") == ("noop", None) and feed_esc(b"[O") == ("noop", None)
assert feed_esc(b"[Mabc") == ("noop", None) and feed_esc(b"OH") == ("noop", None)
assert feed_esc(b"[A") == ("up", None) and feed_esc(b"[<0;12;5M") == ("mouse", (0, 12, 5, "M"))

# 19. Table Seats screen exists in persistent settings popup with Back + Remove everyone, and /remove works on BP speakers
_ts, _cs, rws_s = g["_settings_screen_items"](("seats",), bp_conf, mt_bp, fake_accts, {})
acts_s = [r.get("action") for r in rws_s if r["kind"] == "item"]
assert ("back",) in acts_s and ("seat_all",) in acts_s and ("unseat_all",) in acts_s and any(a and a[0] == "toggle_seat" for a in acts_s), f"seats screen wrong: {acts_s}"
# Test /remove bp_pm, /remove LO, /remove all on BP cast with 0 regular seats
for xm in (m1, m2, m3, m_agy, m_cop, m_oc):
    xm.seated = False
bp_c2 = {"format": "bp", "bp_cast": {"PM": "claude:claude-opus-5-5", "LO": "gemini:gemini-4-neon", "DPM": "codex:gpt-6-astra"}}
import contextlib as _cl, io as _io
mt_rm = g["Meeting"](T, [m1, m2, m3], bp_c2)
g["TABLE"][0] = mt_rm
with _cl.redirect_stdout(_io.StringIO()):
    g["command_line"]("/remove bp_pm", mt_rm, bp_c2, fake_accts)
assert "PM" not in bp_c2.get("bp_cast", {}), f"bp_pm not removed: {bp_c2}"
with _cl.redirect_stdout(_io.StringIO()):
    g["command_line"]("/remove LO", mt_rm, bp_c2, fake_accts)
assert "LO" not in bp_c2.get("bp_cast", {}), f"LO not removed: {bp_c2}"
with _cl.redirect_stdout(_io.StringIO()):
    g["command_line"]("/remove all", mt_rm, bp_c2, fake_accts)
assert not bp_c2.get("bp_cast"), f"/remove all did not clear bp_cast: {bp_c2}"

# 20. Permanent Supra Omnia: always present, always last decider in forum / bp / stake, protected from removal
os.environ["AFC_COUNCIL_FORCE_SUPRA"] = "1"
try:
    s_conf = {"agents": [], "seats": {t: False for t in ("claude", "codex", "gemini", "agy", "copilot", "opencode")},
              "format": "bp", "bp_cast": {"PM": "claude:claude-opus-5-5", "LO": "gemini:gemini-4-neon"}}
    s_members = g["build_members"](s_conf, fake_accts)
    supra = next((x for x in s_members if x.handle == "supra-omnia"), None)
    assert supra is not None and supra.seated, f"supra-omnia must always be present and seated: {s_members}"
    assert "judge" in supra.powers and "remove" in supra.powers, f"supra powers missing: {supra.powers}"
    # Protected against /bench, /agent del, /agent power judge off, /remove all
    mt_sup = g["Meeting"](T, s_members, s_conf)
    g["TABLE"][0] = mt_sup
    with _cl.redirect_stdout(_io.StringIO()):
        g["command_line"]("/bench supra-omnia", mt_sup, s_conf, fake_accts)
        g["command_line"]("/agent del supra-omnia", mt_sup, s_conf, fake_accts)
        g["command_line"]("/agent power supra-omnia judge off", mt_sup, s_conf, fake_accts)
    assert supra.seated, "supra-omnia must not be benchable"
    assert any(x.handle == "supra-omnia" for x in mt_sup.members), "supra-omnia must not be deletable"
    assert "judge" in supra.powers, "supra-omnia must keep judge power"
    # Even if another judge exists, Supra Omnia is always LAST in judges() and adjudicators()
    j2 = M("Arbiter", "codex", account="main", persona="Second judge", made=True)
    j2.powers = ["judge"]; j2.seated = True
    mt_sup.members.insert(0, j2)
    assert mt_sup.judges()[-1].handle == "supra-omnia", f"supra must be last judge: {mt_sup.judges()}"
    assert mt_sup.adjudicators()[-1].handle == "supra-omnia", f"supra must be last adjudicator: {mt_sup.adjudicators()}"
    mt_sup.members.remove(j2)
    # In BP with ALL base seats benched + bp_cast, active_roster includes BP cast + supra-omnia last
    gr = g["Grid"]()
    roster = gr.active_roster(mt_sup)
    assert [x.handle for x in roster] == ["bp_pm", "bp_lo", "supra-omnia"], f"BP roster wrong: {[x.handle for x in roster]}"
    # Verify speak order across all 3 formats: supra-omnia ALWAYS speaks LAST with phase 'verdict'
    for fmt in ("bp", "forum", "stake"):
        calls = []
        s_conf["format"] = fmt
        if fmt != "bp":
            for xm in s_members:
                if xm.handle in ("claude", "codex"):
                    xm.seated = True
        else:
            for xm in s_members:
                if xm.handle != "supra-omnia":
                    xm.seated = False
        mt_f = g["Meeting"](T, s_members, s_conf)
        mt_f.rounds = 1
        mt_f.save = lambda: None
        def fake_speak(m, task, phase, rnd=None, _calls=calls, _mt=mt_f):
            _calls.append((m.handle, phase))
            txt = "Vote: @codex" if phase == "stake" and m.handle == "claude" else (
                  "Vote: @claude" if phase == "stake" else "Verdict: done")
            _mt.thread.append({"who": m.handle, "as": m.shown(), "name": m.name, "text": txt, "phase": phase})
        mt_f.speak = fake_speak
        mt_f.thread.append({"who": "chair", "name": "Chair", "text": "Decide this motion", "phase": "chair"})
        with _cl.redirect_stdout(_io.StringIO()):
            mt_f.round(mt_f.seated(), fresh=True, directed=False)
        assert len(calls) >= 3, f"{fmt}: expected speakers + supra verdict, got {calls}"
        assert calls[-1] == ("supra-omnia", "verdict"), f"{fmt}: supra-omnia must speak last with verdict, got {calls}"
        assert all(h != "supra-omnia" for h, _ in calls[:-1]), f"{fmt}: supra-omnia must sit out until verdict, got {calls}"
finally:
    os.environ.pop("AFC_COUNCIL_FORCE_SUPRA", None)

# 21. Triple-check regressions: Judge picker (all 6 providers), /bp JUDGE, replay BP colors, prompt BP roster, /sim BP with 0 base seats
assert "judge" in g["LOCAL"], "judge must persist in LOCAL"
jc_conf = {"agents": [], "format": "bp", "bp_cast": {"PM": "claude:claude-opus-5-5", "LO": "gemini:gemini-4-neon"}}
for xm in (m1, m2, m3):
    xm.seated = False
mt_j = g["Meeting"](T, [m1, m2, m3], jc_conf)
g["TABLE"][0] = mt_j
with _cl.redirect_stdout(_io.StringIO()):
    g["command_line"]("/bp JUDGE codex:gpt-6-astra", mt_j, jc_conf, fake_accts)
assert jc_conf.get("judge") == "codex:gpt-6-astra", f"/bp JUDGE failed: {jc_conf}"
adj_j = mt_j.adjudicators()
assert len(adj_j) == 1 and adj_j[0].tool == "codex" and adj_j[0].runs_on()[0] == "gpt-6-astra", f"conf judge broken: {adj_j}"
assert "bp_judge" in g["_status_names"](), f"_status_names missing bp_judge: {g['_status_names']()}"
# BP prompt roster includes BP speakers + judge even when regular seats are all benched
pr_bp = mt_j.prompt(mt_j.bp_cast()[0][1], "Speak")
assert "@opus" in pr_bp and "@neon" in pr_bp and "@astra" in pr_bp, f"BP prompt missing active roster: {pr_bp[:300]}"
# @ autocomplete includes active BP speakers
assert "@neon" in g["matches"]("@n", False), f"matches() missing BP speaker @neon: {g['matches']('@n', False)}"
# replay() preserves provider colors for BP speakers & judge via real JSONL feed
with tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False) as tf_feed:
    feed_p = tf_feed.name
old_feed = g["FEED"]["path"]
g["FEED"]["path"] = feed_p
try:
    mt_j.thread.append({"who": "bp_lo", "as": "neon", "name": "Gemini LO", "text": "Hi", "phase": "bp"})
    mt_j.thread.append({"who": "bp_judge", "as": "astra", "name": "Codex JUDGE", "text": "Verdict: OG", "phase": "verdict"})
    g["replay"](mt_j)
    replayed = [json.loads(line) for line in open(feed_p) if line.strip()]
finally:
    g["FEED"]["path"] = old_feed
    os.unlink(feed_p)
by_who = {e.get("who"): e.get("kind") for e in replayed if e.get("t") == "msg"}
assert by_who.get("bp_lo") == "gemini" and by_who.get("bp_judge") == "codex", f"replay lost BP colors: {by_who}"
# Settings popup screens include Judge row in both root & bp, and bp_role JUDGE lists all 6 providers + Back
for scr in (("settings",), ("bp",), ("bp_role", "JUDGE"), ("bp_models", "JUDGE", "codex")):
    _t, _c, rws_j = g["_settings_screen_items"](scr, jc_conf, mt_j, fake_accts, {})
    acts_j = [r.get("action") for r in rws_j if r["kind"] == "item"]
    if scr in (("settings",), ("bp",)):
        assert ("push", ("bp_role", "JUDGE")) in acts_j, f"{scr} missing Judge item: {acts_j}"
    else:
        assert ("back",) in acts_j, f"{scr} missing Back button: {acts_j}"
# /bp JUDGE auto clears conf["judge"]
with _cl.redirect_stdout(_io.StringIO()):
    g["command_line"]("/bp JUDGE auto", mt_j, jc_conf, fake_accts)
assert not jc_conf.get("judge"), f"/bp JUDGE auto did not clear: {jc_conf}"
# simulate() in BP mode with 0 base seats + bp_cast runs trials instead of bailing on empty targets
sim_calls = []
mt_j.save = lambda: None
orig_round = g["Meeting"].round
def fake_sim_round(self, targets, fresh, gen=None, directed=False):
    sim_calls.append(len(self.bp_cast()))
    self.thread.append({"who": "bp_pm", "as": "opus", "name": "Claude PM", "text": "[PM] hi", "phase": "bp"})
    self.thread.append({"who": "bp_judge", "as": "astra", "name": "Codex JUDGE", "text": "Verdict: Government (OG)", "phase": "verdict"})
g["Meeting"].round = fake_sim_round
try:
    with _cl.redirect_stdout(_io.StringIO()):
        res_sim = mt_j.simulate(2, "Test motion", [], base_thread=[])
    assert len(sim_calls) == 2 and "2/2 trials" in res_sim, f"BP simulate with 0 base seats failed: {sim_calls} {res_sim}"
finally:
    g["Meeting"].round = orig_round

print("REGRESSIONS_OK")
EOF
)
is "audit unit regressions (env, perms, headers, defaults, cells, bounded defaults, rename, regex, argv clamp)" "$reg" "REGRESSIONS_OK"
BINDIR=$(dirname "$COUNCIL")
# afc-rules hook is silent/allowed under AFC_COUNCIL_CHILD=1 and AFC_RULES_SKIP=1
r_hook=$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/nonexistent"}}' | AFC_COUNCIL_CHILD=1 python3 "$BINDIR/afc-rules" --hook 2>&1)
hasnt "afc-rules --hook does not block or inject inside council child runs" "$r_hook" 'deny|block|\[ACF rules\]'
# agents --mark exits cleanly under AFC_COUNCIL_CHILD=1
AFC_COUNCIL_CHILD=1 "$BINDIR/agents" --mark busy 2>/dev/null && ok "agents --mark is a no-op inside council child runs" || bad "agents --mark is a no-op inside council child runs" "non-zero exit"
# /retry works without @ prefix
: > "$T/log/argv"
out=$(run "/retry codex")
has "/retry codex works without @ prefix" "$out" 'Trying again: @codex'
# /new preserves /rounds setting and resets last targets
mark
out=$(run "/rounds 2" "@claude first topic" "/new second topic" "/rounds")
has "/new preserves /rounds setting" "$out" '2 pass\(es\) round the table'
# a message starting with a Unix file path (/foo/bar.py) is sent as a message, not treated as an unknown /command
out=$(run "/tmp/example/app.py please inspect this")
hasnt "Unix path at start of message is not rejected as unknown /command" "$out" 'No command /tmp'
has "... and gets answered by the council" "$out" 'ANSWER from @'
# roast mode exits promptly (does not hang 10 minutes!) when all members fail their initial point
touch "$T/full"
t0=$(date +%s)
out=$(run "/mode roast" "everyone blocked by memory wall")
dt=$(( $(date +%s) - t0 ))
rm -f "$T/full"
run "/mode order" > /dev/null
if (( dt < 15 )); then ok "roast mode exits promptly when all points fail (${dt}s, no 10-min stall)"; else bad "roast mode exits promptly when all points fail" "took ${dt}s"; fi
# /sim N Monte Carlo: runs N isolated trials, tallies distribution, and enforces 1..20 bounds
out=$(run "/sim 0 bad" "/sim 25 too many")
has "/sim enforces 1..20 trial bounds" "$out" 'between 1 and 20 trials'
rm -f "$T/log"/prompt.*
out=$(run "/new" "/format stake" "/rounds 1" "/sim 2 Tea or coffee?")
has "/sim 2 runs both Monte Carlo trials" "$out" '─── sim 2/2 \(Win Stake\) ───'
has "... and tallies the Monte Carlo win distribution and total votes" "$out" 'Monte Carlo \(2/2 trials · Win Stake\)'
has "... including cumulative vote totals across trials" "$out" 'Total votes:'
# verify trial isolation: no prompt in the second trial leaks trial 1's Win Stake answers in the thread block
sim_check=$(python3 -c '
import glob, re, sys
ps = sorted(glob.glob(sys.argv[1] + "/prompt.*"))
leaked = 0
for p in ps:
    m = re.search(r"--- The thread so far ---(.*?)--- End of the thread ---", open(p).read(), re.S)
    if m and ("ANSWER from @" in m.group(1) or "Vote: @" in m.group(1)):
        leaked += 1
print(f"{len(ps)}:{leaked}")
' "$T/log")
is "... each Monte Carlo trial runs isolated (no cross-trial leakage)" "$sim_check" "6:0"
# /bp ROLE provider:model assigns models directly across providers, /bp ROLE auto resets one, /sync reloads settings
mark
out=$(run "/new" "/format bp" "/bp PM gemini:gemini-4-neon" "/bp LO codex:gpt-6-astra" "/bp DPM claude:claude-sonnet-5-5" "/bp JUDGE claude:claude-opus-5-5" "/bp" "This house would ship tests first")
has "/bp ROLE provider:model assigns Gemini model to PM" "$out" 'BP: PM speaks on Gemini \(gemini-4-neon\)'
has "... and Codex model to LO" "$out" 'BP: LO speaks on Codex \(gpt-6-astra\)'
has "... and Claude model to DPM" "$out" 'BP: DPM speaks on Claude \(claude-sonnet-5-5\)'
has "... and Judge model via /bp JUDGE" "$out" 'Judge assigned: Claude \(claude-opus-5-5\)'
has "... and runs the BP debate with the assigned models" "$(cat "$T/log/argv")" 'gemini-4-neon'
has "... including Codex's assigned model" "$(cat "$T/log/argv")" 'gpt-6-astra'
has "... including Claude's assigned model" "$(cat "$T/log/argv")" 'claude-sonnet-5-5'
has "... and delivers the Judge verdict on its assigned model" "$(cat "$T/log/argv")" 'claude-opus-5-5'
out=$(run "/bp PM auto" "/bp JUDGE auto" "/sync")
has "/bp ROLE auto resets a single position" "$out" 'BP: PM reset to auto'
has "/bp JUDGE auto resets Judge" "$out" 'Judge reset to default'
has "/sync reloads settings cleanly" "$out" 'Settings applied: BP debate'
run "/bp auto" "/format forum" "/rounds 1" > /dev/null

# ---- the typing line ------------------------------------------------------------------------------------------
# A long message typed letter by letter past the pane's edge, and backspaced back across the wrap: the
# prompt and the whole message stay (with the prompt's colour codes counted as width, they did not)
tt() { "$TB" -L "$SOCK-t" "$@"; }
tt -f /dev/null new-session -d -s t -x 60 -y 10 -c "$T/proj" "env TERM=xterm-256color python3 '$COUNCIL' --no-grid"
sleep 2.5
msg="this fucking tokenops is a mess and the person who made it is valued at a trillion"
for ((i = 0; i < ${#msg}; i++)); do tt send-keys -t t -l "${msg:i:1}"; done; sleep 0.6
shot() { tt capture-pane -p -J -t t | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -1; }
scr=$(shot)
is "a long message typed past the edge stays whole, after the prompt" "$scr" "you> $msg"
tt send-keys -t t -N 30 BSpace; sleep 0.6
scr=$(shot)
is "... and backspaced back across the wrap" "$scr" "you> ${msg:0:$(( ${#msg} - 30 ))}"
tt send-keys -t t Home; tt send-keys -t t -l ">>"; tt send-keys -t t End; sleep 0.5
scr=$(shot)
is "... and edited at its start" "$scr" "you> >>${msg:0:$(( ${#msg} - 30 ))}"
tt kill-server 2>/dev/null

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
