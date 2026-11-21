#!/usr/bin/env bash
# test-turn.sh: tests for the turn stop of bin/autonice ("turn <class> <time>" in the rules: a dev
# server that a Claude agent in a fleet pane started is stopped once that agent's reply has ended).
# Touches nothing of yours: a second autonice with its own rules and state folder, a tmux server of
# its own on its own socket with made-up panes whose marks the test sets by hand, and made-up
# servers (`node <temp>/fakenext dev`) that no real rule matches. All under one temp folder.
#
#   bash _tools/test-turn.sh                    test bin/autonice of this folder
#   bash _tools/test-turn.sh --autonice FILE    test another copy (the live one: ~/.local/bin/autonice)
#   bash _tools/test-turn.sh --keep             leave the temp folder for a look
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AUTONICE="$HERE/bin/autonice"; KEEP=0
while (( $# )); do
  case "$1" in
    --autonice) AUTONICE="$2"; shift ;;
    --keep) KEEP=1 ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done
command -v node >/dev/null || { echo "node is needed for the made-up server"; exit 2; }
TMUXBIN="$HOME/.local/bin/tmux"; [[ -x "$TMUXBIN" ]] || TMUXBIN=$(command -v tmux) || { echo "tmux is needed"; exit 2; }

T=$(mktemp -d /tmp/acf-turn-test.XXXXXX)
mkdir -p "$T/app/web" "$T/other"
SOCK="$T/sock"
tm() { "$TMUXBIN" -S "$SOCK" "$@"; }
GUARD=; SERVERS=()
cleanup() {
  [[ -n "$GUARD" ]] && kill "$GUARD" 2>/dev/null
  for p in "${SERVERS[@]:-}"; do [[ -n "$p" ]] && { kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done
  pkill -KILL -f "$T/fakenext" 2>/dev/null
  tm kill-server 2>/dev/null
  (( KEEP )) || rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | head -c 900; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

printf 'setInterval(() => {}, 60000);\n' > "$T/fakenext"
GATE='gate dev ^[^ ]*node [^ ]*/fakenext dev( |$)'
TIME=3
export AUTONICE_INTERVAL=1 AUTONICE_NO_NOTIFY=1 AUTONICE_TMUX="$TMUXBIN" JOBQ_RUN="$T/run"
RULES="slots dev 9"$'\n'"$GATE"$'\n'"turn dev ${TIME}s"

guard() {   # guard <rules text>: (re)start the test autonice with these rules
  [[ -n "$GUARD" ]] && { kill "$GUARD" 2>/dev/null; wait "$GUARD" 2>/dev/null; }
  printf '%s\n' "$1" > "$T/rules"; : > "$T/log"
  AUTONICE_RULES="$T/rules" bash "$AUTONICE" >> "$T/log" 2>&1 &
  GUARD=$!
}
# The made-up fleet: three panes, two in the project folder, one in another project.
tm -f /dev/null new-session -d -s t -x 80 -y 24 -c "$T/app" 'sleep 900'
A=$(tm display -p -t t '#{pane_id}')
B=$(tm split-window -d -P -F '#{pane_id}' -t "$A" -c "$T/app" 'sleep 900')
C=$(tm new-window -d -P -F '#{pane_id}' -t t: -c "$T/other" 'sleep 900')
[[ "$A" == %* && "$B" == %* && "$C" == %* && "$A$B$C" != "$A$A$A" ]] || { echo "the made-up fleet could not be set up: A=$A B=$B C=$C"; exit 2; }
mark() {   # mark <pane> busy|wait|done|idle|left : what the fleet's hooks would have set
  case "$2" in
    idle) tm set -pu -t "$1" @state \; set -pu -t "$1" @bgshell ;;
    left) tm set -p -t "$1" @state busy \; set -p -t "$1" @bgshell 4242 ;;
    *)    tm set -p -t "$1" @state "$2" \; set -pu -t "$1" @bgshell ;;
  esac
}
n=0
server() {   # server <pane or - > <folder> [agent=1|0]: a made-up server as an agent in that pane would start it; sets $S, $E
  local pane=$1 dir=$2 agent=${3:-1}
  n=$((n + 1)); E="$T/err.$n"
  (
    cd "$dir" || exit 1
    unset TMUX TMUX_PANE CLAUDECODE
    [[ "$pane" != - ]] && export TMUX="$SOCK,1,0" TMUX_PANE="$pane"
    (( agent )) && export CLAUDECODE=1
    exec setsid node "$T/fakenext" dev
  ) > /dev/null 2> "$E" < /dev/null &
  S=$!; SERVERS+=("$S")
}
# status_has <text>: --status of the test autonice holds that text. Read whole first: a `| grep -q`
# would end early and, under pipefail, fail the check it just passed.
status_has() { local out; out=$(AUTONICE_RULES="$T/rules" bash "$AUTONICE" --status 2>/dev/null); [[ "$out" == *"$1"* ]]; }
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
gone_within() { local i; for ((i = 0; i < $2 * 5; i++)); do alive "$1" || return 0; sleep 0.2; done; return 1; }
stop() { local p; for p in "$@"; do kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; }
WAIT=$((TIME + 5))      # a server whose agent finished is gone by then
STAY=$((TIME + 4))      # and one that should stay is still there after this

echo "turn stop of $AUTONICE"
mark "$A" busy; mark "$B" idle; mark "$C" idle
guard "$RULES"

# ---- 1. the server lives while its agent works and goes when the reply ends ---------------------------
server "$A" "$T/app"; s1=$S; s1_err=$E
sleep "$STAY"
check "while the agent works its server stays" "alive $s1" "$(cat "$T/log")"
check "--status lists it with its pane" "status_has ' $s1  pane $A: its agent is working'" "$(AUTONICE_RULES="$T/rules" bash "$AUTONICE" --status 2>&1 | tail -5)"
mark "$A" done
check "it is still there just after the reply ended (inside the time)" "sleep 1; alive $s1"
check "and is stopped once the reply has ended for the time" "gone_within $s1 $WAIT" "$(cat "$T/log")"
check "the log says why" "grep -q 'turn: stopped $s1, its agent.s reply ended (pane $A, done)' '$T/log'" "$(cat "$T/log")"
check "the server was told why on its own output" "grep -q 'the agent that started it has finished its reply' '$s1_err'" "$(cat "$s1_err" 2>&1)"

# ---- 2. the other ways a reply ends, and the ones that are not an end ---------------------------------
mark "$A" busy; server "$A" "$T/app"; s2=$S; sleep 2
mark "$A" left
check "a reply that ended with a background shell still running counts as ended" "gone_within $s2 $WAIT" "$(cat "$T/log")"
mark "$A" busy; server "$A" "$T/app"; s3=$S; sleep 2
mark "$A" idle
check "an agent that was closed counts as ended" "gone_within $s3 $WAIT" "$(cat "$T/log")"
mark "$A" busy; server "$A" "$T/app"; s4=$S; sleep 2
mark "$A" wait
sleep "$STAY"
check "an agent waiting for your permission has not ended: its server stays" "alive $s4" "$(cat "$T/log")"
mark "$A" done; sleep 1; mark "$A" busy
sleep "$STAY"
check "a new prompt inside the time keeps the server" "alive $s4" "$(cat "$T/log")"
stop "$s4"

# ---- 3. servers that are not an agent's are never touched ----------------------------------------------
mark "$A" done
server "$A" "$T/app" 0; mine=$S          # typed in the pane by you: the pane, but no agent mark
server - "$T/app" 1; desk=$S             # an agent outside tmux (the desktop app)
server - "$T/app" 0; plain=$S            # a plain terminal
sleep "$STAY"
check "a server you typed in the pane yourself stays" "alive $mine" "$(cat "$T/log")"
check "a server of an agent outside the fleet stays" "alive $desk" "$(cat "$T/log")"
check "a server from a plain terminal stays" "alive $plain" "$(cat "$T/log")"
check "none of them is listed as an agent's" "! grep -q -E '^($mine|$desk|$plain) ' '$T/run/turn'" "$(cat "$T/run/turn" 2>&1)"
stop "$mine" "$desk" "$plain"

# ---- 4. another agent at work in the same project keeps it ---------------------------------------------
mark "$A" busy; mark "$B" busy
server "$A" "$T/app"; s5=$S
server "$A" "$T/app/web"; s6=$S          # a server in a subfolder of the project
sleep 2
mark "$A" done
sleep "$STAY"
check "its own agent is done, but another agent works in that folder: the server stays" "alive $s5" "$(cat "$T/log")"
check "the same for a server in a subfolder of that agent's folder" "alive $s6" "$(cat "$T/log")"
check "--status says who keeps it" "status_has ' $s5  pane $A: another agent in that project is working'" "$(AUTONICE_RULES="$T/rules" bash "$AUTONICE" --status 2>&1 | tail -4)"
mark "$B" done; mark "$C" busy
check "an agent at work in ANOTHER project does not keep it" "gone_within $s5 $WAIT && gone_within $s6 3" "$(cat "$T/log")"

# ---- 5. the pane or the whole fleet is gone -------------------------------------------------------------
mark "$C" done; mark "$B" busy; server "$B" "$T/other"; s7=$S; sleep 2
tm kill-pane -t "$B"
check "the agent's pane was closed: its server is stopped" "gone_within $s7 $WAIT" "$(cat "$T/log")"

# ---- 6. tmux cannot be asked: nothing is stopped ---------------------------------------------------------
mark "$A" done
export AUTONICE_TMUX=/bin/false
guard "$RULES"
server "$A" "$T/app"; s8=$S
sleep "$STAY"
check "the pane state cannot be read (tmux fails to answer): the server is left alone" "alive $s8" "$(cat "$T/log")"
export AUTONICE_TMUX="$TMUXBIN"
guard "$RULES"
check "once it can be read again the finished agent's server is stopped" "gone_within $s8 $WAIT" "$(cat "$T/log")"

# ---- 7. no rule, or a time it cannot read: nothing is stopped --------------------------------------------
guard "slots dev 9"$'\n'"$GATE"
server "$A" "$T/app"; s9=$S
sleep "$STAY"
check "without a 'turn' rule nothing is stopped" "alive $s9" "$(cat "$T/log")"
check "--status says it is off" "status_has \"off (no 'turn' rule)\""
guard "slots dev 9"$'\n'"$GATE"$'\n'"turn dev soon"
sleep "$STAY"
check "a time it cannot read turns the rule off" "alive $s9" "$(cat "$T/log")"

# ---- 8. the fleet's tmux server is gone -------------------------------------------------------------------
guard "$RULES"$'\n'"single dev 2s"$'\n'"idle dev 3h"
mark "$A" busy; sleep 2
check "with the other rules beside it a working agent's server still stays" "sleep $STAY; alive $s9" "$(cat "$T/log")"
tm kill-server; sleep 0.5
check "the whole fleet is gone (no tmux server): its agents' servers are stopped" "gone_within $s9 $WAIT" "$(cat "$T/log")"

echo
echo "$pass passed, $fail failed"
(( KEEP )) && echo "kept: $T"
exit $(( fail > 0 ))
