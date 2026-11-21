#!/usr/bin/env bash
# test-idle.sh: tests for the idle stop of bin/autonice ("idle <class> <time>" in the rules: a dev
# server that does no work for that long is stopped). Touches nothing of yours: a second autonice
# with its own rules and state folder under one temp folder, watching only made-up servers
# (`node <temp>/fakenext dev`) that no real rule matches. No desktop notification is sent.
#
#   bash _tools/test-idle.sh                    test bin/autonice of this folder
#   bash _tools/test-idle.sh --autonice FILE    test another copy (the live one: ~/.local/bin/autonice)
#   bash _tools/test-idle.sh --keep             leave the temp folder for a look
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AUTONICE="$HERE/bin/autonice"; KEEP=0
while (( $# )); do
  case "$1" in
    --autonice) AUTONICE="$2"; shift ;;
    --keep) KEEP=1 ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done
command -v node >/dev/null || { echo "node is needed for the made-up server"; exit 2; }

T=$(mktemp -d /tmp/acf-idle-test.XXXXXX)
GUARD=; SERVERS=()
cleanup() {
  [[ -n "$GUARD" ]] && kill "$GUARD" 2>/dev/null
  for p in "${SERVERS[@]:-}"; do [[ -n "$p" ]] && kill -KILL "$p" 2>/dev/null; done
  pkill -KILL -f "$T/fakenext" 2>/dev/null
  (( KEEP )) || rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2" | head -c 600; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# The made-up dev server: sleeps; on SIGUSR2 it works for 0.3 s (a page load).
cat > "$T/fakenext" <<'EOF'
process.on('SIGUSR2', () => { const end = Date.now() + 300; while (Date.now() < end); });
setInterval(() => {}, 60000);
EOF
GATE='gate dev ^[^ ]*node [^ ]*/fakenext dev( |$)'
export AUTONICE_INTERVAL=1 AUTONICE_NO_NOTIFY=1 JOBQ_RUN="$T/run"

guard() {   # guard <rules text>: (re)start the test autonice with these rules
  [[ -n "$GUARD" ]] && { kill "$GUARD" 2>/dev/null; wait "$GUARD" 2>/dev/null; }
  printf '%s\n' "$1" > "$T/rules"; : > "$T/log"
  AUTONICE_RULES="$T/rules" bash "$AUTONICE" >> "$T/log" 2>&1 &
  GUARD=$!
}
server() {   # server -> starts a background made-up server, sets $S to its pid
  setsid node "$T/fakenext" dev > /dev/null 2>&1 < /dev/null &
  S=$!; SERVERS+=("$S")
}
# status_has <text>: --status of the test autonice holds that text. Read whole first: a `| grep -q`
# would end early and, under pipefail, fail the check it just passed.
status_has() { local out; out=$(AUTONICE_RULES="$T/rules" bash "$AUTONICE" --status 2>/dev/null); [[ "$out" == *"$1"* ]]; }
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
gone_within() {   # gone_within <pid> <seconds>
  local i; for ((i = 0; i < $2 * 5; i++)); do alive "$1" || return 0; sleep 0.2; done; return 1
}

echo "idle stop of $AUTONICE"

# ---- 1. an idle server is stopped, a working one is not ------------------------------------------
guard "slots dev 3"$'\n'"$GATE"$'\n'"idle dev 6s"
server; idle=$S
server; busy=$S
( for _ in $(seq 1 14); do sleep 1; kill -USR2 "$busy" 2>/dev/null; done ) &
worker=$!
sleep 3
check "an idle server is still there before its time (3 s of 6)" "alive $idle"
check "the state file lists both watched servers" "grep -q '^$idle ' '$T/run/idle' && grep -q '^$busy ' '$T/run/idle'" "$(cat "$T/run/idle" 2>&1)"
check "--status shows the idle stop" "status_has '  $idle  idle '"
check "the idle server is stopped after its time" "gone_within $idle 9" "$(cat "$T/log")"
check "the log says why" "grep -q 'idle: stopped $idle, no work for' '$T/log'" "$(cat "$T/log")"
check "a server that keeps working is not stopped (12 s on)" "sleep 3; alive $busy" "$(cat "$T/log")"
wait "$worker" 2>/dev/null
check "once its work ends it is stopped too" "gone_within $busy 12" "$(cat "$T/log")"

# ---- 2. a server started in a terminal is watched too ----------------------------------------------
if command -v script >/dev/null; then
  script -qfc "node '$T/fakenext' dev" /dev/null > /dev/null 2>&1 < /dev/null &
  sleep 1.5
  tpid=$(pgrep -f "^node $T/fakenext dev" | head -n1)
  if [[ -n "$tpid" && "$(ps -o tty= -p "$tpid" | tr -d ' ')" != "?" ]]; then
    SERVERS+=("$tpid")
    check "a terminal-started server is stopped when idle" "gone_within $tpid 10" "$(cat "$T/log")"
  else
    bad "a terminal-started server could not be made (no terminal given)" "pid=${tpid:-none}"
  fi
else
  echo "  skip  terminal-started server (no 'script' here)"
fi

# ---- 3. no idle rule, or a long one: nothing is stopped -------------------------------------------
guard "slots dev 3"$'\n'"$GATE"
server; keep=$S
sleep 8
check "without an idle rule nothing is stopped" "alive $keep" "$(cat "$T/log")"
check "and nothing is listed as watched" "[[ ! -s '$T/run/idle' ]]" "$(cat "$T/run/idle" 2>&1)"
guard "slots dev 3"$'\n'"$GATE"$'\n'"idle dev 1"
sleep 8
check "a bare number is minutes: 'idle dev 1' leaves an 8 s old server alone" "alive $keep" "$(cat "$T/log")"
guard "slots dev 3"$'\n'"$GATE"$'\n'"idle dev soon"
sleep 4
check "a time it cannot read turns the rule off, it does not stop things" "alive $keep" "$(cat "$T/log")"
kill -KILL "$keep" 2>/dev/null

# ---- 4. a server the gate holds paused is not counted as idle --------------------------------------
guard "slots dev 1"$'\n'"$GATE"$'\n'"idle dev 6s"
server; first=$S
sleep 2
server; second=$S
sleep 2
check "the second server is paused, the one slot being busy" "[[ \"\$(ps -o stat= -p $second)\" == T* ]]" "$(cat "$T/log")"
check "the first is stopped as idle" "gone_within $first 9" "$(cat "$T/log")"
sleep 3
check "the paused one was not: it got the slot and its clock started then" "alive $second" "$(cat "$T/log")"
check "and it is stopped once it has been idle itself" "gone_within $second 10" "$(cat "$T/log")"

echo
echo "$pass passed, $fail failed"
(( KEEP )) && echo "kept: $T"
exit $(( fail > 0 ))
