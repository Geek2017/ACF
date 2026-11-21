#!/usr/bin/env bash
# test-single.sh: tests for the duplicate stop of bin/autonice ("single <class> <time>" in the rules:
# a second dev server started in a folder that already has one is stopped, the first stays; with
# the word "port" on the rule, only one started for the same port). Touches nothing of yours: a second autonice with its own rules and state folder under one
# temp folder, watching only made-up servers (`node <temp>/fakenext dev`) that no real rule matches.
# No desktop notification is sent.
#
#   bash _tools/test-single.sh                    test bin/autonice of this folder
#   bash _tools/test-single.sh --autonice FILE    test another copy (the live one: ~/.local/bin/autonice)
#   bash _tools/test-single.sh --keep             leave the temp folder for a look
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

T=$(mktemp -d /tmp/acf-single-test.XXXXXX)
mkdir -p "$T/app" "$T/other app"
GUARD=; SERVERS=()
cleanup() {
  [[ -n "$GUARD" ]] && kill "$GUARD" 2>/dev/null
  for p in "${SERVERS[@]:-}"; do [[ -n "$p" ]] && { kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done
  pkill -KILL -f "$T/fakenext" 2>/dev/null
  (( KEEP )) || rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | head -c 900; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# The made-up dev server: sleeps. FAKE_LISTEN=1 makes it listen on a free port,
# FAKE_SLOW_EXIT=1 makes it take 2.5 s to stop when asked (a server shutting down).
cat > "$T/fakenext" <<'EOF'
if (process.env.FAKE_LISTEN) require('net').createServer().listen(0, '127.0.0.1');
if (process.env.FAKE_SLOW_EXIT) process.on('SIGTERM', () => setTimeout(() => process.exit(0), 2500));
setInterval(() => {}, 60000);
EOF
GATE='gate dev ^[^ ]*node [^ ]*/fakenext dev( |$)'
GRACE=3
export AUTONICE_INTERVAL=1 AUTONICE_NO_NOTIFY=1 AUTONICE_DUP_GRACE=$GRACE JOBQ_RUN="$T/run"

guard() {   # guard <rules text>: (re)start the test autonice with these rules
  [[ -n "$GUARD" ]] && { kill "$GUARD" 2>/dev/null; wait "$GUARD" 2>/dev/null; }
  printf '%s\n' "$1" > "$T/rules"; : > "$T/log"
  AUTONICE_RULES="$T/rules" bash "$AUTONICE" >> "$T/log" 2>&1 &
  GUARD=$!
}
n=0
server() {   # server <folder> [arguments]: starts a background made-up server there, sets $S to its pid and $E to its error output
  local dir=$1; shift
  n=$((n + 1)); E="$T/err.$n"
  ( cd "$dir" && exec setsid node "$T/fakenext" dev "$@" ) > /dev/null 2> "$E" < /dev/null &
  S=$!; SERVERS+=("$S")
}
# status_has <text>: --status of the test autonice holds that text. Read whole first: a `| grep -q`
# would end early and, under pipefail, fail the check it just passed.
status_has() { local out; out=$(AUTONICE_RULES="$T/rules" bash "$AUTONICE" --status 2>/dev/null); [[ "$out" == *"$1"* ]]; }
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
gone_within() {   # gone_within <pid> <seconds>
  local i; for ((i = 0; i < $2 * 5; i++)); do alive "$1" || return 0; sleep 0.2; done; return 1
}
stop() { local p; for p in "$@"; do kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; }
WAIT=$((GRACE + 5))     # a duplicate is gone by then
STAY=$((GRACE + 4))     # and something that is not one is still there after this

echo "duplicate stop of $AUTONICE"

# ---- 1. the same server twice in one folder: the second goes, the first stays -----------------------
guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev"
FAKE_LISTEN=1 server "$T/app"; first=$S
sleep 1.5
server "$T/app"; second=$S; second_err=$E
check "the second copy is still there inside the grace time" "sleep 1; alive $second"
check "the second copy is stopped" "gone_within $second $WAIT" "$(cat "$T/log")"
check "the first one stays" "alive $first" "$(cat "$T/log")"
check "the log says why, with the first one's pid" "grep -q 'single: stopped $second, a dev server already runs in $T/app (pid $first' '$T/log'" "$(cat "$T/log")"
check "and the port the first one listens on" "grep -Eq 'single: stopped $second, .*\\(pid $first, port [0-9]+\\)' '$T/log'" "$(cat "$T/log")"
check "the stopped copy was told why on its own output" "grep -q 'autonice: stopped this dev server: one already runs in this folder (pid $first' '$second_err'" "$(cat "$second_err" 2>&1)"
check "--status shows the rule is on" "status_has 'on for: dev, one per folder (after $GRACE s'"
server "$T/app"; third=$S
check "a third copy started later is stopped as well" "gone_within $third $WAIT" "$(cat "$T/log")"
check "the first one is still there after all that" "alive $first"

# ---- 2. one per folder, whatever the port; another folder is another project ---------------------------
server "$T/app" -p 3217; p1=$S
server "$T/other app"; o1=$S
check "a second server in the folder on another port (-p 3217) is stopped too" "gone_within $p1 $WAIT" "$(cat "$T/log")"
check "the same server in another folder is left alone" "sleep 1; alive $o1" "$(cat "$T/log")"
server "$T/other app"; o2=$S
check "a second one in the other folder (a space in its name) is stopped" "gone_within $o2 $WAIT" "$(cat "$T/log")"
check "the ones they doubled are untouched" "alive $o1 && alive $first"
stop "$o1"

# ---- 3. with "port" on the rule: one per folder AND port ------------------------------------------------
guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev ${GRACE}s port"
server "$T/app" -p 3217; p1=$S; p1_err=$E
sleep "$STAY"
check "a second server on a port of its own (-p 3217) is left alone" "alive $p1" "$(cat "$T/log")"
check "--status says one per folder and port" "status_has 'on for: dev, one per folder and port (after $GRACE s'"
server "$T/app" --port=3217; p2=$S; p2_err=$E
check "a second one for that same port, written --port=3217, is stopped" "gone_within $p2 $WAIT" "$(cat "$T/log")"
check "and is told it may use another port" "grep -q 'or start this one on another port with -p' '$p2_err'" "$(cat "$p2_err" 2>&1)"
PORT=4000 server "$T/app"; e1=$S
sleep "$STAY"
check "PORT=4000 beside the default-port server is left alone" "alive $e1" "$(cat "$T/log")"
PORT=4000 server "$T/app"; e2=$S
check "a second PORT=4000 is stopped" "gone_within $e2 $WAIT" "$(cat "$T/log")"
check "the ones they doubled are untouched" "alive $p1 && alive $e1 && alive $first"
stop "$p1" "$e1" "$first"
guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev"

# ---- 4. a restart is not a duplicate -----------------------------------------------------------------
FAKE_SLOW_EXIT=1 server "$T/app"; old=$S
sleep 2
kill -TERM "$old"; server "$T/app"; new=$S        # the old one takes 2.5 s to go; the new one starts at once
sleep "$STAY"
check "restarting (old still shutting down as the new starts) keeps the new one" "alive $new && ! alive $old" "$(cat "$T/log")"
stop "$new"

# ---- 5. a copy whose output nobody reads cannot hang the watcher -------------------------------------
server "$T/app"; a=$S
sleep 1.5
( cd "$T/app" && exec setsid node "$T/fakenext" dev ) > /dev/null 2> >(exit 0) < /dev/null &
b=$!; SERVERS+=("$b")
check "it is stopped all the same" "gone_within $b $((WAIT + 2))" "$(cat "$T/log")"
server "$T/app"; c=$S
check "and the watcher goes on working: the next copy is stopped too" "gone_within $c $WAIT" "$(cat "$T/log")"
stop "$a"

# ---- 6. a copy the gate holds paused is stopped, not left frozen -------------------------------------
guard "slots dev 1"$'\n'"$GATE"$'\n'"single dev"
server "$T/app"; g1=$S
sleep 2
server "$T/app"; g2=$S
sleep 1.5
check "with one slot the second copy is paused first" "[[ \"\$(ps -o stat= -p $g2)\" == T* ]]" "$(cat "$T/log")"
check "then stopped as a duplicate" "gone_within $g2 $WAIT" "$(cat "$T/log")"
check "the slot holder stays" "alive $g1"
stop "$g1"

# ---- 7. a copy started in a terminal is stopped too --------------------------------------------------
if command -v script >/dev/null; then
  guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev"
  server "$T/app"; t1=$S
  sleep 1.5
  ( cd "$T/app" && exec script -qfc "node '$T/fakenext' dev" /dev/null ) > "$T/term.out" 2>&1 < /dev/null &
  sleep 1.5
  tpid=$(pgrep -n -f "^node $T/fakenext dev$")
  if [[ -n "$tpid" && "$tpid" != "$t1" && "$(ps -o tty= -p "$tpid" | tr -d ' ')" != "?" ]]; then
    SERVERS+=("$tpid")
    check "a terminal-started copy is stopped" "gone_within $tpid $WAIT" "$(cat "$T/log")"
    check "and the reason is shown in that terminal" "grep -q 'autonice: stopped this dev server' '$T/term.out'" "$(cat "$T/term.out" 2>&1)"
  else
    bad "a terminal-started copy could not be made (no terminal given)" "pid=${tpid:-none}"
  fi
  stop "$t1"
else
  echo "  skip  terminal-started copy (no 'script' here)"
fi

# ---- 8. no rule: nothing is stopped -------------------------------------------------------------------
guard "slots dev 5"$'\n'"$GATE"
server "$T/app"; k1=$S
server "$T/app"; k2=$S
sleep "$STAY"
check "without a 'single' rule both copies stay" "alive $k1 && alive $k2" "$(cat "$T/log")"
check "--status says it is off" "status_has \"off (no 'single' rule)\""
guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev soon"
sleep "$STAY"
check "a time it cannot read turns the rule off, it does not stop things" "alive $k1 && alive $k2" "$(cat "$T/log")"
guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev 1"
sleep "$STAY"
check "a bare number is minutes: 'single dev 1' leaves a few seconds old copy alone" "alive $k1 && alive $k2" "$(cat "$T/log")"
guard "slots dev 5"$'\n'"$GATE"$'\n'"single dev 6s"$'\n'"idle dev 3h"
sleep 4
check "the rule's own time is used: 'single dev 6s' has not stopped the copy after 4 s" "alive $k2" "$(cat "$T/log")"
check "turning the rule on stops the newer of two already running" "gone_within $k2 8 && alive $k1" "$(cat "$T/log")"
check "the idle stop beside it still lists the one that stays" "grep -q '^$k1 ' '$T/run/idle'" "$(cat "$T/run/idle" 2>&1)"

echo
echo "$pass passed, $fail failed"
(( KEEP )) && echo "kept: $T"
exit $(( fail > 0 ))
