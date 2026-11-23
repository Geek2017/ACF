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
[[ -f "$L/judge" ]] && grep -q "power to take a member off the table" <<< "$prompt" && reply="$reply"$'\n'"Remove: @$(cat "$L/judge") - repeats itself"
# an agent asked to keep something: its Remember: line
[[ -f "$L/remember" ]] && grep -q "lines starting 'Remember:'" <<< "$prompt" && reply="$reply"$'\n'"Remember: $who keeps an eye on cost"
[[ -f "$L/echo-name" ]] && reply="@$who: $reply"     # an LLM that copies the thread's "@name:" format
[[ -f "$L/long" ]] && reply="$reply $(printf 'wordy%.0s ' $(seq 1 60))end"
# an agent whose project's instructions add a greeting and a footer to every reply
[[ -f "$L/footer" ]] && reply="My Lord. $reply"$'\n\n'"You: whatever the chair said"$'\n\n'"SITREP · ARMY/MDMP · P1 · Done: x · Open: y · Next: z"
if [[ -n "$out" ]]; then echo "codex log noise on stdout"; printf '%s\n' "$reply" > "$out"; else printf '%s\n' "$reply"; fi
EOF
chmod +x "$T/agents"
# account folders with settings of their own: what the pane headers show as the defaults
mkdir -p "$T/ch" "$T/xh"; echo '{"model": "sonnet"}' > "$T/ch/settings.json"
printf 'model = "gpt-test"\nmodel_reasoning_effort = "medium"\n[profiles.x]\nmodel = "not-this"\n' > "$T/xh/config.toml"
# the Codex account's own list of models (what + add and Alt+M offer)
# the Claude account's known models (what its menus offer), and Antigravity's list as `agy models` gave it
echo '{"additionalModelCostsCache": {"claude-haiku-4-5-20251001": {}, "claude-fable-5-2": {}, "claude-haiku-5-5": {}, "other": {}}}' > "$T/ch/.claude.json"
mkdir -p "$T/cache/afc-council"
echo '{"agy": ["gemini-4-neon-low", "gemini-4-neon-high", "gemini-4-neon-xhigh", "claude-opus-5-5-medium", "claude-opus-5-5-high", "gpt-oss-120b-medium"]}' > "$T/cache/afc-council/models.json"
export XDG_CACHE_HOME="$T/cache" AFC_COUNCIL_NO_REFRESH=1
echo '{"models": [{"slug": "gpt-6-astra", "visibility": "list"}, {"slug": "gpt-hidden", "visibility": "hide"}, {"slug": "gpt-6-sol", "visibility": "list"}, {"slug": "gpt-test", "visibility": "list"}]}' > "$T/xh/models_cache.json"
sed -i.bak -e "s|/home/x/.claude\$|$T/ch|" -e "s|/home/x/.codex\$|$T/xh|" "$T/accounts.txt"
export COUNCIL_TEST_DIR="$T" AFC_COUNCIL_AGENTS="$T/agents" AFC_COUNCIL_CONF="$T/council.json"
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
# the remove power: an agent takes a member off the table on its own judgement (benched, never deleted)
run "/agent new Arbiter claude The final judge of the council" > /dev/null
has "/agent power NAME remove: the agent may remove members" "$(run "/agent power arbiter remove on")" 'may now remove members'
echo codex > "$T/judge"; mark; out=$(run "@arbiter rule on it"); rm -f "$T/judge"
has "... it is told so in its prompt" "$(cat $(since | head -1))" 'power to take a member off the table'
has "... Remove: @codex (an LLM's own seat): it leaves the table, and the council says why" "$out" '⚖ @arbiter: @codex taken off the table .*\(repeats itself\)'
has "... its answer shows it" "$out" '⚖ Removed @codex: repeats itself'
hasnt "... @codex is off the table" "$(run "/agents" | grep -m1 'At the table:')" '@codex'
run "/seat codex" > /dev/null
run "/agent new Victim claude A member who talks too much" > /dev/null; echo "- 2026-11-22: something kept" >> "$T/proj/agents/victim/MEMORY.md"
echo victim > "$T/judge"; out=$(run "@arbiter @victim rule on it"); rm -f "$T/judge"
has "... Remove: @victim (an agent you made): deleted for good, its memory wiped" "$out" '⚖ @arbiter: @victim removed for good, its memory wiped'
is "... its folder is gone, not moved aside" "$(ls -d "$T/proj/agents/victim" "$T/proj/agents/_removed/victim-"* 2>/dev/null | wc -l | tr -d ' ')" 0
hasnt "... and it is gone from the agents" "$(cat "$T/council.json")" '"name": "Victim"'
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
has "an LLM that does not exist is refused" "$out" 'LLM must be claude, codex, gemini or agy'
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
has "Gemini has no effort setting, and says what to do instead" "$out" "@gemini: Gemini's command line has no effort setting"
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
out=$(run "/model @claude default" "/effort @codex default" "/agent del quick")
has "default goes back to the LLM's own" "$out" '@claude: model back to its default'

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
  is "Alt+K opens a tab called council" "$(tm list-windows -F '#{window_name}' | grep -c '^council$')" 1
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
  has "... Gemini with none set: default model, and no effort (it has none)" "$(hdr gemini)" '\]default model#\[default\]'
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
  tm select-pane -t "$(pane_of gemini)"; tm send-keys -K -c "$CL" M-m; sleep 0.8; tm send-keys -K -c "$CL" h; sleep 0.5; tm send-keys -K -c "$CL" Escape; sleep 1
  has "Gemini's menu has no effort to pick: h does nothing" "$(hdr gemini)" '\]default model#\[default\]'
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
  tm send-keys -t "$chair" "/quit" Enter; sleep 2.5
  is "/quit closes the whole council tab, grid and all" "$(tm list-windows -F '#{window_name}' | grep -c '^council$')" 0
else
  echo "  skip  Alt+K end to end (~/.local/bin/afc-council is not this folder's bin/afc-council)"
fi

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
