#!/usr/bin/env bash
# test-even.sh: tests for bin/afc-even, which evens out a row or column of splits after a split, a
# close or a minimise (tmux 3.8's own select-layout -E pushed a top/bottom stack off the tab's edge).
# Touches nothing of yours: a tmux server of its own (own socket name), a client of its own in a
# pseudo-terminal 118 columns wide (the width the fault showed at), and panes that only sleep.
# The key-press checks press the fleet's real keys (Alt+-, Alt+\, Alt+Q, Alt+H, Alt+U) in that client.
# The guard checks (afc-even --guard, started by afc-reflow after each layout change) wait up to a
# few seconds for it, then look: no split past the tab's edge or squeezed below 8 x 3.
#
#   bash _tools/test-even.sh                 test bin/afc-even, bin/agents and tmux/tmux.conf of this folder
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
EVEN="$HERE/bin/afc-even"; CONF="$HERE/tmux/tmux.conf"
[[ $# -eq 0 ]] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
TB="$HOME/.local/bin/tmux"; [[ -x "$TB" ]] || TB=$(command -v tmux) || { echo "tmux is not installed" >&2; exit 2; }
for f in agents afc-even afc-min; do
  [[ "$(readlink -f "$HOME/.local/bin/$f" 2>/dev/null)" == "$(readlink -f "$HERE/bin/$f")" ]] ||
    echo "  note: ~/.local/bin/$f is not this folder's bin/$f; the key-press checks use ~/.local/bin/$f"
done
pass=0; fail=0
T_=$(mktemp -d /tmp/acf-even-test.XXXXXX)
SOCK="acfeven-$$"
export AGENTS_SOCK="$SOCK" AGENTS_LIST="$T_/projects" AGENTS_LAYOUT="$T_/layout" AGENTS_NO_NOTIFY=1
tm() { "$TB" -L "$SOCK" "$@"; }
cp=""
trap 'tm kill-server 2>/dev/null; [[ -n "$cp" ]] && kill "$cp" 2>/dev/null; rm -rf "$T_"' EXIT
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got: $2   expected: $3"; fi; }

# The panes as "x+w/y+h" in layout order, and whether every pane is inside the tab
geom() { tm list-panes -t "$1" -F '#{pane_left}+#{pane_width}/#{pane_top}+#{pane_height}' | tr '\n' ' ' | sed 's/ $//'; }
inside() {
  local w h; read -r w h < <(tm display -p -t "$1" '#{window_width} #{window_height}')
  tm list-panes -t "$1" -F '#{pane_left} #{pane_width} #{pane_top} #{pane_height}' |
    awk -v W="$w" -v H="$h" '$1 + $2 > W || $3 + $4 > H { bad = 1 } END { exit bad }'
}
fits() { if inside "$2"; then ok "$1"; else bad "$1" "a pane is past the tab's edge: $(geom "$2") in $(tm display -p -t "$2" '#{window_width}x#{window_height}')"; fi; }
count() { tm display -p -t "$1" '#{window_panes}'; }
count_to() {  # <window> <n>: the pane count once it reaches n, or what it is after 5 s (a close takes a moment on a busy machine)
  local i; for i in $(seq 50); do [[ "$(count "$1")" == "$2" ]] && break; sleep 0.1; done; count "$1"; }
minimised() { tm show -gqv @min_count; }
hidden_from() { tm list-panes -s -t =afcmin -F '#{@min_from}' 2>/dev/null | grep -cx -- "$1"; }   # minimised from that tab
guards() {  # guards still at work on this test server
  local n=0 pid; for pid in $(pgrep -f 'afc-even --guard'); do grep -qz "^AGENTS_SOCK=$SOCK\$" "/proc/$pid/environ" 2>/dev/null && n=$((n + 1)); done; echo $n
}
usable() {  # every pane inside the tab and at least 8 x 3
  inside "$1" && ! tm list-panes -t "$1" -F '#{pane_width} #{pane_height}' | awk '$1 < 8 || $2 < 3 { bad = 1 } END { exit !bad }'
}
settle() { local i; for i in $(seq 1 "${2:-20}"); do usable "$1" && return 0; sleep 0.25; done; return 1; }
attach() {  # <columns>: (re)attach the test client at that width
  [[ -n "$cp" ]] && kill "$cp" 2>/dev/null; sleep 0.3
  script -qfc "stty cols $1 rows 45; exec env TERM=xterm-256color '$TB' -L '$SOCK' attach -t agents" /dev/null </dev/null >/dev/null 2>&1 &
  cp=$!; local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -n "$(tm list-clients 2>/dev/null)" ]] && break; sleep 0.3; done
  CL=$(tm list-clients -F '#{client_name}' | head -1)
}
widths() { tm list-panes -t "$1" -F '#{pane_left} #{pane_width}' | sort -n | uniq | awk '{ printf "%s%s", s, $2; s = " " }'; }

newtab() {   # <name>: a tab with one pane; prints its window id
  local w; w=$(tm new-window -d -P -F '#{window_id}' -n "$1" "sleep 600")
  tm set -w -t "$w" @project "$1"; echo "$w"
}
split() {    # <how> <pane>: as the split menu does (split-window, then afc-even for the new pane); prints the new pane
  local p w; w=$(tm display -p -t "$2" '#{window_id}')
  p=$(tm split-window "$1" -t "$2" -P -F '#{pane_id}' "sleep 600")
  python3 "$EVEN" --window "$w"; echo "$p"
}

echo "afc-even of $EVEN"
tm -f "$CONF" new-session -d -s agents -n base -x 161 -y 45 "sleep 600"
attach 118
[[ -n "$CL" ]] || { echo "no test client could attach"; exit 1; }

# ---- the fault: A | B | C, then C split below ----------------------------------------------------
w=$(newtab t1); tm select-window -t "$w"; sleep 0.3
A=$(tm display -p -t "$w" '#{pane_id}')
B=$(split -fh "$A"); C=$(split -fh "$B")
is "three columns share the tab evenly" "$(widths "$w")" "37 37 36"
D=$(split -v "$C")
fits "C split below: the stack stays on screen" "$w"
is "... and the columns keep their widths" "$(widths "$w")" "37 37 36"
is "... and C and D are halves" "$(tm list-panes -t "$w" -F '#{pane_height}' | tail -2 | tr '\n' ' ')" "21 21 "
E=$(split -v "$D")
fits "D split below: a stack of three stays on screen" "$w"
is "... in thirds" "$(tm list-panes -t "$w" -F '#{pane_height}' | tail -3 | tr '\n' ' ')" "14 14 13 "
F=$(split -fh "$A")
fits "a split to the right with a stack in the row: all on screen" "$w"
is "... four columns, the stack counted as one" "$(widths "$w")" "27 27 27 26"

# ---- --gone, and the close the fleet does ----------------------------------------------------------
is "--gone: a member of a stack of three names a survivor and the stack's depth" "$(python3 "$EVEN" --gone "$E")" "$C 1"
is "--gone: a column of the row names a survivor and depth 0" "$(python3 "$EVEN" --gone "$F")" "$A 0"
tm kill-pane -t "$E"; python3 "$EVEN" "$C" 1
fits "after closing E and evening its stack: on screen" "$w"
is "... C and D halves again" "$(tm list-panes -t "$w" -F '#{pane_height}' | sed -n '3,4p' | tr '\n' ' ')" "21 21 "
is "--gone: a stack of two names nothing (the survivor fills it)" "$(python3 "$EVEN" --gone "$D")" ""

# ---- the real keys -----------------------------------------------------------------------------------
key() { tm send-keys -K -c "$CL" "$@"; sleep 0.7; }
# Alt+\ and Alt+- build their menu first (agents --split-menu / --split-down), which on a machine with
# many processes takes longer than the 0.7 s above: wait until it is built, or the next key reaches the pane.
menu() { local i; tm send-keys -K -c "$CL" "$1"; sleep 0.3
         for i in $(seq 50); do pgrep -f -- "--split-(menu|down) $CL " >/dev/null || break; sleep 0.1; done; sleep 0.4; }
w=$(newtab t2); tm select-window -t "$w"; sleep 0.3
A=$(tm display -p -t "$w" '#{pane_id}')
menu 'M-\'; key t; menu 'M-\'; key t
is "Alt+\\ twice (plain terminal): three panes" "$(count "$w")" 3
menu M--; key t
is "Alt+- (plain terminal): four panes" "$(count "$w")" 4
fits "Alt+- in the right column: the stack stays on screen" "$w"
menu M--; key t
fits "Alt+- again: a stack of three, on screen" "$w"
key M-q; key y
is "Alt+Q, y: one split closed, the others still there" "$(count_to "$w" 4)" 4
fits "... and all of them on screen" "$w"
key M-q; key n
is "Alt+Q, n: nothing closed" "$(count "$w")" 4
m0=$(minimised); key M-q; key m
is "Alt+Q, m (minimise it instead): one split fewer in the tab" "$(count "$w")" 3
is "... and it is minimised, not closed" "$(minimised)" "$((m0 + 1))"
key M-u
is "... and Alt+U brings it back" "$(count "$w")" 4
w1=$(newtab t2b); tm select-window -t "$w1"; sleep 0.3
key M-q; key m; key Escape
is "Alt+Q, m on a tab's only split does nothing (the choice is greyed out there)" "$(count "$w1") $(hidden_from "$w1")" "1 0"
tm select-window -t "$w"; sleep 0.3
key M-h
is "Alt+H: the split is minimised" "$(count "$w")" 3
fits "... the rest on screen" "$w"
key M-u
is "Alt+U: it is back" "$(count "$w")" 4
fits "... and everything on screen" "$w"

# ---- --fix: a tab the old way broke (the layout hooks off, so the guard does not repair it first) ----
tm set-hook -gu window-layout-changed; tm set-hook -gu window-resized
w=$(newtab t3); tm select-window -t "$w"; sleep 0.3
A=$(tm display -p -t "$w" '#{pane_id}')
B=$(tm split-window -fh -t "$A" -P -F '#{pane_id}' "sleep 600"); C=$(tm split-window -fh -t "$B" -P -F '#{pane_id}' "sleep 600")
tm select-layout -t "$w" even-horizontal; D=$(tm split-window -v -t "$C" -P -F '#{pane_id}' "sleep 600"); tm select-layout -E -t "$w"
if inside "$w"; then echo "  note: tmux's own select-layout -E did not break this tab (a fixed tmux?); --fix still checked"
else ok "tmux's own select-layout -E puts the stack past the edge (the fault, still in this tmux)"; fi
python3 "$EVEN" --fix >/dev/null
fits "--fix: everything back on screen" "$w"
is "... the columns shared out evenly" "$(widths "$w")" "37 37 36"
before=$(geom "$w"); python3 "$EVEN" --fix >/dev/null
is "--fix on a tab that fits changes nothing" "$(geom "$w")" "$before"
is "--fix leaves the panes in their places" "$(tm list-panes -t "$w" -F '#{pane_id}' | tr '\n' ' ')" "$A $B $C $D "

# ---- the guard: a split is never left out of sight ----------------------------------------------------
tm source-file "$CONF"            # the layout hooks back on
w=$(newtab t4); tm select-window -t "$w"; sleep 0.3
A=$(tm display -p -t "$w" '#{pane_id}')
B=$(tm split-window -fh -t "$A" -P -F '#{pane_id}' "sleep 600"); C=$(tm split-window -fh -t "$B" -P -F '#{pane_id}' "sleep 600")
tm select-layout -t "$w" even-horizontal; D=$(tm split-window -v -t "$C" -P -F '#{pane_id}' "sleep 600")
tm select-pane -t "$D"; tm select-layout -E -t "$w"
if settle "$w"; then ok "a tab tmux's -E broke is put right by itself"; else bad "a tab tmux's -E broke is put right by itself" "$(geom "$w")"; fi
is "... by sharing out again: all four splits still in the tab, none minimised" "$(count "$w") $(hidden_from "$w")" "4 0"

w=$(newtab t5); tm select-window -t "$w"; sleep 0.3
A=$(tm display -p -t "$w" '#{pane_id}')
B=$(split -fh "$A"); C=$(split -fh "$B")
tm select-pane -t "$A"; tm resize-pane -t "$A" -x 100
if settle "$w"; then ok "a border dragged over a split: it is not left squeezed out of sight"; else bad "a border dragged over a split: it is not left squeezed out of sight" "$(geom "$w")"; fi
is "... it is minimised, not closed" "$(count "$w") $(hidden_from "$w")" "2 1"
aw=$(tm display -p -t "$A" '#{pane_width}')
if (( aw >= 90 )); then ok "... and the split you widened keeps its width ($aw)"; else bad "... and the split you widened keeps its width" "it is $aw wide"; fi
if [[ "$(tm display -p -t "$B" '#{session_name}')" == afcmin ]]; then ok "... the one beside it went to the minimised splits"; else bad "... the one beside it went to the minimised splits" "$B is in $(tm display -p -t "$B" '#{session_name}')"; fi

w=$(newtab t6); tm select-window -t "$w"; sleep 0.3
A=$(tm display -p -t "$w" '#{pane_id}'); p=$A
for _ in 1 2 3 4 5; do p=$(split -fh "$p"); done
attach 40
if settle "$w" 24; then ok "the window shrunk to 40 columns: no split squeezed out of sight"; else bad "the window shrunk to 40 columns: no split squeezed out of sight" "$(geom "$w")"; fi
is "... the ones without room are minimised, not closed" "$(( $(count "$w") + $(hidden_from "$w") ))" 6
if (( $(count "$w") >= 2 )); then ok "... and more than one is still shown ($(count "$w"))"; else bad "... and more than one is still shown" "$(count "$w")"; fi
is "... the split you are in is one of them" "$(tm display -p -t "$p" '#{window_id}')" "$w"
attach 118
if settle "$w"; then ok "back to 118 columns: everything shown is in sight"; else bad "back to 118 columns: everything shown is in sight" "$(geom "$w")"; fi
for _ in $(seq 1 20); do [[ "$(guards)" == 0 ]] && break; sleep 0.25; done
is "nothing of the guard left running" "$(guards)" 0

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
