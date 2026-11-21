#!/usr/bin/env bash
# test-copy.sh: tests for bin/afc-copy, the filter that cleans what the fleet's mouse copy puts on
# the clipboard (quote bar, marks and margin off; lines the pane broke joined again). Touches
# nothing of yours: the filter runs with --print, so the clipboard is never written, and the one
# end-to-end check uses a tmux server of its own on its own socket under a temp folder.
#
#   bash _tools/test-copy.sh                 test bin/afc-copy of this folder
#   bash _tools/test-copy.sh --copy FILE     test another copy
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
COPY="$HERE/bin/afc-copy"
while (( $# )); do
  case "$1" in
    --copy) COPY="$2"; shift ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done
pass=0; fail=0
T=$(mktemp -d /tmp/acf-copy-test.XXXXXX)
trap '[[ -S "$T/s" ]] && "${TMUXBIN:-tmux}" -S "$T/s" kill-server 2>/dev/null; rm -rf "$T"' EXIT

is() {   # is <name> <width or -> <input> <expected>
  local name=$1 w=$2 got
  if [[ "$w" == - ]]; then got=$(printf '%s' "$3" | env -u TMUX python3 "$COPY" --print)
  else got=$(printf '%s' "$3" | python3 "$COPY" --width "$w" --print); fi
  if [[ "$got" == "$4" ]]; then pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else fail=$((fail + 1)); printf '  FAIL  %s\n        got:      %s\n        expected: %s\n' "$name" "${got//$'\n'/⏎}" "${4//$'\n'/⏎}"; fi
}

echo "clean copy of $COPY"

# ---- the case it was written for: a quoted paragraph in a 56-wide pane, picked up from mid-line ----
is "a quoted paragraph comes out as one line of plain text" 56 \
'KingCaller is an AI voice platform for small and
  ▎ growing businesses. Our AI phone agents answer every
  ▎ inbound call, qualify callers, book appointments
  ▎ straight into your calendar, transfer to a person
  ▎ when needed, and send follow-up texts. Outbound
  ▎ agents work through call lists for reminders and
  ▎ lead follow-up. Every call is recorded, transcribed
  ▎ and summarized in one workspace, and you pay only
  ▎ for the minutes you use.' \
'KingCaller is an AI voice platform for small and growing businesses. Our AI phone agents answer every inbound call, qualify callers, book appointments straight into your calendar, transfer to a person when needed, and send follow-up texts. Outbound agents work through call lists for reminders and lead follow-up. Every call is recorded, transcribed and summarized in one workspace, and you pay only for the minutes you use.'

is "the same picked up from the start of the line" 56 \
'  ▎ KingCaller is an AI voice platform for small and
  ▎ growing businesses. Our AI phone agents answer every
  ▎ inbound call.' \
'KingCaller is an AI voice platform for small and growing businesses. Our AI phone agents answer every inbound call.'

is "an empty quote line stays a paragraph break" 56 \
'  ▎ First paragraph of the quote that runs to the edge
  ▎ and over it.
  ▎
  ▎ Second paragraph.' \
'First paragraph of the quote that runs to the edge and over it.

Second paragraph.'

is "a reply (● mark, two-space margin) is joined and loses mark and margin" 56 \
'● The fleet never stopped: all 14 panes and every agent
  were still running. Only its window had closed.

  Next paragraph.' \
'The fleet never stopped: all 14 panes and every agent were still running. Only its window had closed.

Next paragraph.'

is "tool output (⎿ mark) loses the mark and its margin, lines kept" 80 \
'  ⎿  active
     leftovers: 0' \
'active
leftovers: 0'

# ---- what must NOT be joined ---------------------------------------------------------------------
is "short lines of code keep their breaks, the margin goes" 56 \
'    cd /srv/app
    npm install
    npm run build' \
'cd /srv/app
npm install
npm run build'

is "a short line is not joined to a long first word below it" 56 \
'  run this:
  /usr/local/share/some/very/long/path/to/a/program-name --flag' \
'run this:
/usr/local/share/some/very/long/path/to/a/program-name --flag'

is "a line that ends near the edge by itself is not joined to a short word" 56 \
'  const first = computeSomethingFrom(input, options);
  if (first) return first;' \
'const first = computeSomethingFrom(input, options);
if (first) return first;'

is "list items stay apart; an item the pane broke is joined" 54 \
'  - Added the duplicate stop to the resource guard, so
    a second copy is stopped.
  - Tested on made-up servers.
  1. First numbered step that is long enough to reach
     the edge.
  2. Second.' \
'- Added the duplicate stop to the resource guard, so a second copy is stopped.
- Tested on made-up servers.
1. First numbered step that is long enough to reach the edge.
2. Second.'

is "a table keeps its rows" 40 \
'  ┌──────────────┬─────────────────────┐
  │ Who          │ Using               │
  ├──────────────┼─────────────────────┤
  │ Tab 2        │ 223%                │
  └──────────────┴─────────────────────┘' \
'┌──────────────┬─────────────────────┐
│ Who          │ Using               │
├──────────────┼─────────────────────┤
│ Tab 2        │ 223%                │
└──────────────┴─────────────────────┘'

is "a blank line is never joined across" 30 \
'  aaaa bbbb cccc dddd eeee ffff

  gggggggggg' \
'aaaa bbbb cccc dddd eeee ffff

gggggggggg'

# ---- odd inputs ------------------------------------------------------------------------------------
is "a long address the pane cut is joined without a space" 40 \
'https://example.com/a/very/long/address/
that/continues/here' \
'https://example.com/a/very/long/address/that/continues/here'

is "one word is left as it is" 56 'KingCaller' 'KingCaller'
is "one line loses its margin and bar" 56 '  ▎ just this line' 'just this line'
is "empty lines at both ends go, trailing blanks too" 56 $'\n  text here   \n\n' 'text here'
is "without a width nothing is joined, the dressing still goes" - \
'  ▎ growing businesses. Our AI phone agents answer every
  ▎ inbound call.' \
'growing businesses. Our AI phone agents answer every
inbound call.'
is "wide characters count two cells" 20 \
'  日本語のテキスト です
  next' \
'日本語のテキスト です next'
is "nothing in, nothing out" 56 '' ''

raw=$'  ▎ growing businesses.\n  ▎ inbound call.'
got=$(printf '%s' "$raw" | python3 "$COPY" --width 56 --raw --print)
if [[ "$got" == "$raw" ]]; then pass=$((pass + 1)); echo "  ok    --raw changes nothing"; else fail=$((fail + 1)); echo "  FAIL  --raw changes nothing"; fi

got=$(printf '  ▎ to the sink' | python3 "$COPY" --width 56 -- tee "$T/sink" >/dev/null; cat "$T/sink")
if [[ "$got" == "to the sink" ]]; then pass=$((pass + 1)); echo "  ok    the cleaned text goes to the clipboard command it is given"; else fail=$((fail + 1)); echo "  FAIL  the cleaned text goes to the clipboard command it is given: $got"; fi

# ---- end to end: a real tmux copy, the way the fleet's bindings call it ------------------------------
TMUXBIN="$HOME/.local/bin/tmux"; [[ -x "$TMUXBIN" ]] || TMUXBIN=$(command -v tmux || true)
if [[ -n "$TMUXBIN" ]]; then
  tm() { "$TMUXBIN" -S "$T/s" "$@"; }
  printf '%s\n' '  ▎ growing businesses. Our AI phone agents answer every' '  ▎ inbound call, qualify callers, book appointments' '  ▎ straight into your calendar.' > "$T/screen"
  tm -f /dev/null new-session -d -s t -x 56 -y 12 "cat '$T/screen'; sleep 60"
  sleep 0.5
  tm set -s set-clipboard on
  tm copy-mode -t t \; send -t t -X history-top \; send -t t -X begin-selection \; send -t t -X -N 2 cursor-down \; send -t t -X end-of-line
  # the fleet's mouse binding: -F fills in the pane's width, -C keeps tmux from also writing the terminal's clipboard
  tm send -t t -X -F copy-pipe-and-cancel -C "python3 '$COPY' --width #{pane_width} --print > '$T/out'" 2> "$T/err"
  sleep 0.7
  want='growing businesses. Our AI phone agents answer every inbound call, qualify callers, book appointments straight into your calendar.'
  if [[ "$(cat "$T/out" 2>/dev/null)" == "$want" ]]; then pass=$((pass + 1)); echo "  ok    a tmux copy with the fleet's binding gives the clean text (pane width filled in by tmux)"
  else fail=$((fail + 1)); echo "  FAIL  a tmux copy with the fleet's binding gives the clean text"; echo "        got: $(cat "$T/out" 2>&1 | tr '\n' '⏎')  err: $(cat "$T/err" 2>&1)"; fi
  # the keyboard and long-copy way: no width given, the filter asks tmux itself
  tm set -s copy-command "python3 '$COPY' --print > '$T/out2'"
  tm copy-mode -t t \; send -t t -X history-top \; send -t t -X begin-selection \; send -t t -X -N 2 cursor-down \; send -t t -X end-of-line \; send -t t -X copy-pipe-and-cancel
  sleep 0.7
  if [[ "$(cat "$T/out2" 2>/dev/null)" == "$want" ]]; then pass=$((pass + 1)); echo "  ok    as the plain copy-command it finds the pane's width by itself"
  else fail=$((fail + 1)); echo "  FAIL  as the plain copy-command it finds the pane's width by itself"; echo "        got: $(cat "$T/out2" 2>&1 | tr '\n' '⏎')"; fi
else
  echo "  skip  end-to-end tmux copy (no tmux here)"
fi

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
