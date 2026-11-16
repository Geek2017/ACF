#!/usr/bin/env bash
# test-fleet.sh: try the launcher on a throw-away fleet before it is trusted with the real one.
#
#   bash _tools/test-fleet.sh                     test this folder's bin/ and tmux/tmux.conf
#   bash _tools/test-fleet.sh --bin DIR           test the agents, afc-agent-info and afc-logs in DIR instead
#   bash _tools/test-fleet.sh --conf FILE         with that tmux config instead
#   bash _tools/test-fleet.sh --keep              leave the sandbox folder behind, to look into it
#
# Nothing here reaches the real fleet: the test fleet has its own tmux server (its own socket name), its
# own home folder under /tmp, and stand-in programs for claude, codex, gemini, agy, notify-send and the
# usage tools, so no agent is started, no model is asked and no notification is shown. It takes about
# three minutes. It ends with the number of checks passed and failed, and exits 1 if any failed.
#
# What it checks: start; the saved layout (tabs, splits, accounts, chats, plan mode, minimised splits)
# and that a restart gives all of it back identically; that a fleet going down hard does not spoil the
# saved layout; --fresh; changes to the project list; the watcher starting itself again; agents that
# start slowly or a moment apart; a chat with nothing in it, a chat open elsewhere, Gemini without an
# earlier chat; desktop notifications and the plan-limit warning; the overview; tab signals for Codex;
# work folders (git worktrees) and their clean-up; handing a chat to another tool; --doctor.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$HERE/bin" ]] || HERE="/nonexistent"
BIN="$HERE/bin"; CONF="$HERE/tmux/tmux.conf"; REPO="$HERE"; KEEP=0
while (( $# )); do
  case "$1" in
    --bin) BIN=$2; shift 2 ;; --conf) CONF=$2; shift 2 ;; --repo) REPO=$2; shift 2 ;; --keep) KEEP=1; shift ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
[[ -x "$BIN/agents" && -r "$CONF" ]] || { echo "no agents in $BIN, or no tmux config at $CONF" >&2; exit 2; }
TMUXBIN=$(command -v tmux) || { echo "tmux is not installed" >&2; exit 2; }

SBX=$(mktemp -d "${TMPDIR:-/tmp}/acf-test.XXXXXX"); H="$SBX/home"; SOCK="acftest-$$"
P1="$SBX/proj/p1"; P2="$SBX/proj/\$\$AFocus/p two"; P3="$SBX/proj/p3"; L="$H/.local/state/afc/layout"
sb() {
  env -u TMUX -u TMUX_PANE -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_CLI_HOME -u XDG_STATE_HOME -u XDG_CONFIG_HOME \
      -u AGENTS_LIST -u AGENTS_ACCOUNTS -u AGENTS_LAYOUT -u AGENTS_SETTINGS -u AGENTS_WORKTREES -u AGENTS_CLAUDE \
      HOME="$H" AGENTS_SOCK="$SOCK" AGENTS_LAYOUT_EVERY=2 XDG_RUNTIME_DIR="$SBX/run" \
      PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}
tm() { sb tmux -L "$SOCK" "$@"; }
A="$H/.local/bin/agents"

cleanup() {
  tm kill-server 2>/dev/null
  pkill -f "^/bin/bash $H/.local/bin/" 2>/dev/null
  sleep 0.5
  if (( KEEP )); then echo "sandbox kept: $SBX"; else rm -rf "$SBX"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------- the sandbox
mkdir -p "$H/.local/bin" "$H/.local/lib/afc" "$H/.config/agents" "$H/.claude/projects" "$H/.claude-others" \
         "$H/.gemini/antigravity-cli" "$SBX/run" "$P1" "$P2" "$P3"
chmod 700 "$SBX/run"
ln -s "$TMUXBIN" "$H/.local/bin/tmux"
ln -s "$BIN/agents" "$A"
for f in afc-agent-info afc-min afc-reflow afc-move; do
  if [[ -e "$BIN/$f" ]]; then ln -s "$BIN/$f" "$H/.local/bin/$f"; else ln -s "$REPO/bin/$f" "$H/.local/bin/$f"; fi
done
ln -s "$REPO/lib/afc/pb.py" "$H/.local/lib/afc/pb.py"
ln -s "$CONF" "$H/.tmux.conf"
printf 'P1 %s\nPtwo %s\n' "$P1" "$P2" > "$H/.config/agents/projects"
printf 'main ~/.claude\nothers ~/.claude-others\n' > "$H/.config/agents/accounts"
printf 'main ~/.codex\nacctb ~/.codex-b\n' > "$H/.config/agents/accounts-codex"
printf 'start-gap 0\n' > "$H/.config/agents/settings"
printf '{"workspace": "%s", "conversationId": "conv-agy-1"}\n' "$P2" > "$H/.gemini/antigravity-cli/history.jsonl"
( cd "$P1" && git init -q . && git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m first ) || true

stub() { cat > "$H/.local/bin/$1"; chmod +x "$H/.local/bin/$1"; }
stub claude <<'EOF'
#!/bin/bash
# stand-in for Claude: keeps the per-run record the real one keeps, notes how it was started, then waits
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; mkdir -p "$cfg/sessions" "$HOME/.claude/projects/stub"
id=""; prev=""; for a in "$@"; do [[ "$prev" == --resume ]] && id=$a; prev=$a; done
[[ -n "$id" ]] || id=$(cat /proc/sys/kernel/random/uuid)
[[ -e "$HOME/claude-slow" ]] && sleep 6
echo "{\"pid\":$$,\"sessionId\":\"$id\"}" > "$cfg/sessions/$$.json"
[[ -e "$HOME/claude-silent" ]] || : >> "$HOME/.claude/projects/stub/$id.jsonl"
echo "claude $* | cfg=${cfg#$HOME/} | cwd=$PWD" >> "$HOME/started.log"
echo "STUB claude $* chat $id"; while :; do sleep 3600; done
EOF
stub codex <<'EOF'
#!/bin/bash
# stand-in for Codex: a new one holds its session file open, as the real one does; a resumed one not yet
home="${CODEX_HOME:-$HOME/.codex}"
echo "codex $* | home=${home#$HOME/} | cwd=$PWD" >> "$HOME/started.log"
if [[ "${1:-}" != resume ]]; then
  f="$home/sessions/2026/11/16/rollout-2026-11-16T00-00-00-$(cat /proc/sys/kernel/random/uuid).jsonl"
  mkdir -p "${f%/*}"; exec 7>> "$f"; echo "$f" >> "$HOME/codex-rollouts.log"
fi
echo "STUB codex $*"; while :; do sleep 3600; done
EOF
stub gemini <<'EOF'
#!/bin/bash
echo "gemini $* | cwd=$PWD" >> "$HOME/started.log"
[[ "$*" == *--resume* && -e "$HOME/gemini-no-sessions" ]] && { echo "no sessions"; exit 1; }
echo "STUB gemini $*"; while :; do sleep 3600; done
EOF
stub agy <<'EOF'
#!/bin/bash
echo "agy $* | cwd=$PWD" >> "$HOME/started.log"
echo "STUB agy $*"; while :; do sleep 3600; done
EOF
stub notify-send <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/notify.log"
for a in "$@"; do [[ "$a" == -p ]] && echo 42; done
exit 0
EOF
stub claude-usage <<'EOF'
#!/bin/bash
# stand-in: "claude-usage --short 'claude <account>'" answers with what the test wrote for that account
acct=${2##* }; cat "$HOME/usage-$acct" 2>/dev/null
EOF
stub llm-usage <<'EOF'
#!/bin/bash
exit 0
EOF
stub afc-bar <<'EOF'
#!/bin/bash
# stand-in for the pane header: the agent in the pane, nothing for a plain terminal
w=$("$HOME/.local/bin/agents" --who "$1" 2>/dev/null); [[ -n "$w" ]] && echo " #[fg=red][$w]#[default]"
exit 0
EOF
stub afc-logs <<'EOF'
#!/bin/bash
# stand-in for the chat log: "file <chat>" prints the readable file of that chat, when the test made one
if [[ "${1:-}" == file && -e "$HOME/thread-$2.md" ]]; then echo "$HOME/thread-$2.md"; fi
exit 0
EOF

# ---------------------------------------------------------------------------------- helpers
n_pass=0; n_fail=0
ok()  { n_pass=$((n_pass + 1)); printf '  pass  %s\n' "$1"; }
bad() { n_fail=$((n_fail + 1)); printf '  FAIL  %s\n' "$1"; if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed "s|$SBX|SBX|g; s/^/          /"; fi; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got:  $2"$'\n'"want: $3"; fi; }
has() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "nothing like /$3/ in:"$'\n'"${2:0:600}"; fi; }
hasnt() { if grep -qE -- "$3" <<< "$2"; then bad "$1" "found /$3/ in:"$'\n'"${2:0:600}"; else ok "$1"; fi; }
geo() { tm list-panes -a -F '#{session_name} #{window_index}:#{window_name} #{pane_index} #{pane_width}x#{pane_height}+#{pane_left}+#{pane_top} #{?pane_active,ACTIVE,} proj=#{@project} min=#{?#{@min_from},yes,}' 2>/dev/null | grep -v holding | sed -E 's/^(afcmin [^ ]+) .* (proj=.*)$/\1 \2/'; }
bare() { sed -E 's/"I":"%[0-9]+"//g; s/"l":[0-9]+,?//g' "$1"; }   # pane ids and focus history differ from run to run
up() { sb "$A" "$@" </dev/null >/dev/null 2>&1; }
down() { tm kill-server 2>/dev/null; sleep 3; }
until_true() {  # seconds, command...: wait until the command succeeds
  local end=$(( SECONDS + $1 )); shift
  while (( SECONDS < end )); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 0.5; done
  return 1
}
saved() { [[ -r "$L" ]] && (( $(grep -c '^P' "$L") == $1 )); }
mark() { tm run-shell "TMUX_PANE=$1 $A --mark $2" 2>/dev/null; }
watchers() { pgrep -f "$A --layout-wat[c]h" | wc -l; }

echo "Testing $BIN/agents on a throw-away fleet (socket $SOCK, home $H)"

# ---------------------------------------------------------------------------------- start
echo "Start"
up; sleep 1
is "a start opens one tab per project" "$(tm list-windows -t agents -F '#{window_name}=#{window_panes}' | tr '\n' ' ')" "P1=1 Ptwo=1 "
sleep 600 & sp=$!; fails=0
for _ in $(seq 150); do out=$(sb "$A" --pane-account $sp 2>/dev/null) && [[ "$out" == main ]] || fails=$((fails + 1)); done
kill $sp 2>/dev/null
is "the account lookup answers every time (150 tries)" "$fails" 0
has "the help lists the new commands" "$(sb "$A" --help)" 'agents --doctor'

# ---------------------------------------------------------------------------------- the saved layout
echo "Saved layout"
tm resize-window -t agents:1 -x 160 -y 44; tm resize-window -t agents:2 -x 200 -y 44
p0=$(tm display -p -t agents:1.1 '#{pane_pid}'); p1=$(tm display -p -t agents:2.1 '#{pane_pid}')
tm split-window -fh -t agents:1 "$A --pane claude $p0 others"
tm split-window -v  -t agents:1.2 "$A --pane codex $p0 acctb"
tm split-window -v  -t agents:1.1 "$A --pane term $p0"
tm resize-pane -t agents:1.1 -x 97; tm resize-pane -t agents:1.1 -y 30; tm select-pane -t agents:1.3
tm split-window -fh -t agents:2 "$A --pane gemini $p1"
tm split-window -fh -t agents:2 "$A --pane gemini $p1"
tm split-window -fh -t agents:2 "$A --pane claude $p1 main"
tm split-window -fh -t agents:2 "$A --pane agy $p1"
tm split-window -fh -t agents:2 "$A --pane plan $p1 main"
sleep 1.5
tm run-shell "$H/.local/bin/afc-min hide $(tm display -p -t agents:2.4 '#{pane_id}')"
tm new-window -t agents: "$A --pane tab $p1"
until_true 20 saved 11 || true
lay=$(cat "$L" 2>/dev/null)
is "every tab is in the saved layout" "$(grep -c '^W' <<< "$lay")" 3
is "every split is in the saved layout" "$(grep -c '^P' <<< "$lay")" 11
has "Claude on its other account, with its chat" "$lay" $'^P\tclaude\tothers\t[0-9a-f-]{36}\ta\t'
has "Codex on its account, with the chat it holds open" "$lay" $'^P\tcodex\tacctb\t[0-9a-f-]{36}\t'
has "Antigravity with the folder's newest chat" "$lay" $'^P\tagy\tmain\tconv-agy-1\t'
has "a split started in plan mode is marked" "$lay" $'^P\tclaude\tmain\t[0-9a-f-]{36}\t[a-]*p\t'
has "the minimised split is marked" "$lay" $'^P\tclaude\tmain\t[0-9a-f-]{36}\tm\t'
has "a tab that is not a project is kept too" "$lay" $'^W\tp two\t-\t'
has "agents --layout reads it back" "$(sb "$A" --layout)" 'minimised'
geo > "$SBX/before.txt"; cp "$L" "$SBX/layout.before"

# ---------------------------------------------------------------------------------- notifications
echo "Notifications and the limit warning"
pane=$(tm display -p -t agents:1.1 '#{pane_id}'); : > "$H/notify.log"
mark "$pane" busy; tm set -p -t "$pane" @since $(( $(date +%s) - 100 )); mark "$pane" done; sleep 1.5
has "a long turn that ends unwatched is announced" "$(cat "$H/notify.log")" 'P1: done .*finished after 1 min'
mark "$pane" busy; mark "$pane" done; sleep 1.5
is "a turn of a few seconds is not" "$(grep -c 'P1: done' "$H/notify.log")" 1
mark "$pane" busy; mark "$pane" wait; sleep 1.5
has "an agent that asks is announced" "$(cat "$H/notify.log")" 'P1: waiting for you'
echo "S95% W40%" > "$H/usage-main"; echo "S10% W5%" > "$H/usage-others"
mark "$pane" busy; tm set -p -t "$pane" @since $(( $(date +%s) - 100 )); mark "$pane" done; sleep 2
has "an account close to its limit is announced, with the one that has room" "$(cat "$H/notify.log")" 'has used S95% W40%.*Most room: others'
mark "$pane" busy; tm set -p -t "$pane" @since $(( $(date +%s) - 100 )); mark "$pane" done; sleep 2
is "and only once in half an hour" "$(grep -c 'has used S95%' "$H/notify.log")" 1
printf 'start-gap 0\nnotify-done off\n' > "$H/.config/agents/settings"; before=$(grep -c ': done' "$H/notify.log")
mark "$pane" busy; tm set -p -t "$pane" @since $(( $(date +%s) - 100 )); mark "$pane" done; sleep 1.5
is "notify-done off in the settings silences it" "$(grep -c ': done' "$H/notify.log")" "$before"
printf 'start-gap 0\n' > "$H/.config/agents/settings"; rm -f "$H"/usage-*

tm set -pu -t "$pane" @state; mark "$pane" busy; s1=$(tm display -p -t "$pane" '#{@since}'); sleep 1.2; mark "$pane" busy
is "the start of a turn is noted once, not at every tool call" "$(tm display -p -t "$pane" '#{@since}')" "$s1"
if (( s1 > $(date +%s) - 10 )); then ok "and it is the time the turn began"; else bad "and it is the time the turn began" "@since=$s1"; fi
mark "$pane" done

echo "Overview"
ov=$(sb "$A" --overview)
is "the overview lists every agent and no terminal" "$(grep -cE '\[(claude|codex|gemini|agy)' <<< "$ov")" 9
has "with what each is doing" "$ov" 'P1 +done'
hasnt "without tmux styling in the terminal" "$ov" '#\['

echo "Tab signals for Codex"
cx=$(tm list-panes -t agents:1 -F '#{pane_id} #{pane_start_command}' | awk '/--pane codex/ {print $1}')
roll=$(head -1 "$H/codex-rollouts.log")
echo '{"type":"event_msg","payload":{"type":"task_started"}}' >> "$roll"
codex_busy() { [[ "$(tm display -p -t "$cx" '#{@busy}')" == "$1" ]]; }
until_true 12 codex_busy 1 && ok "a Codex turn that starts underlines its tab" || bad "a Codex turn that starts underlines its tab" "@busy=$(tm display -p -t "$cx" '#{@busy}')"
echo '{"type":"event_msg","payload":{"type":"task_complete"}}' >> "$roll"
until_true 12 codex_busy 0 && ok "and one that ends clears it" || bad "and one that ends clears it" "@busy=$(tm display -p -t "$cx" '#{@busy}')"
is "leaving the pane marked done" "$(tm display -p -t "$cx" '#{@state}')" done
ag=$(tm list-panes -t agents:2 -F '#{pane_id} #{pane_start_command}' | awk '/--pane agy/ {print $1}')
agy_busy() { [[ "$(tm display -p -t "$ag" '#{@busy}')" == "$1" ]]; }
db="$H/.gemini/antigravity-cli/conversations/conv-agy-1.db"; mkdir -p "${db%/*}"; n0=$(wc -l < "$H/notify.log")
( for _ in 1 2 3 4; do echo x >> "$db"; sleep 1.5; done ) &
until_true 12 agy_busy 1 && ok "Antigravity writing to its conversation underlines its tab" || bad "Antigravity writing to its conversation underlines its tab" "@busy=$(tm display -p -t "$ag" '#{@busy}')"
wait; until_true 25 agy_busy 0 && ok "and going quiet clears it" || bad "and going quiet clears it" "@busy=$(tm display -p -t "$ag" '#{@busy}')"
is "an estimated signal sends no notification" "$(wc -l < "$H/notify.log")" "$n0"
tm set -pu -t "$cx" @state; tm set -pu -t "$pane" @state; tm set -pu -t "$ag" @state

# ---------------------------------------------------------------------------------- stop and start again
echo "Restart"
until_true 10 saved 11 || true; cp "$L" "$SBX/layout.before"; geo > "$SBX/before.txt"
out=$(echo y | sb "$A" --kill 2>&1); sleep 3
has "agents --kill saves the layout first" "$out" 'Layout saved'
is "and leaves the same splits on file" "$(bare "$L" | cksum)" "$(bare "$SBX/layout.before" | cksum)"
has "agents --dry-run shows what would reopen" "$(sb "$A" --dry-run)" 'plan mode'
: > "$H/started.log"; up; sleep 7
is "every tab and split is back in place, with its size, focus and minimised split" "$(geo)" "$(cat "$SBX/before.txt")"
st=$(cat "$H/started.log")
has "Claude is back on its own account and chat" "$st" 'claude .*--resume [0-9a-f-]{36} \| cfg=\.claude-others'
has "Codex is back on its own account and chat" "$st" 'codex resume [0-9a-f-]{36} \| home=\.codex-b'
has "Antigravity is back on its conversation" "$st" 'agy --conversation conv-agy-1'
has "the plan-mode split is back in plan mode" "$st" 'claude .*--permission-mode plan --resume'
is "one Gemini split gets the folder's latest chat, the other a new one" "$(grep -c '^gemini --resume latest' <<< "$st")/$(grep -c '^gemini  ' <<< "$st")" "1/1"
is "the minimised split is minimised again" "$(tm show -gqv @min_count)" 1
until_true 12 saved 11 || true
is "what is saved after the restart is what was restored" "$(bare "$L" | cksum)" "$(bare "$SBX/layout.before" | cksum)"

echo "A fleet that goes down hard"
sum=$(cksum < "$L")
for p in $(tm list-panes -a -F '#{pane_pid}'); do kill -9 "$p" 2>/dev/null; sleep 0.3; done; tm kill-server 2>/dev/null; sleep 5
is "does not spoil the saved layout" "$(cksum < "$L")" "$sum"

echo "Other starts"
up --fresh; sleep 2
is "agents --fresh opens one pane per project" "$(geo | wc -l)" 2
down; cp "$SBX/layout.before" "$L"; cp "$H/.config/agents/projects" "$SBX/projects.bak"
printf '# closed: P1 %s\nPtwo %s\nP3 %s\n' "$P1" "$P2" "$P3" > "$H/.config/agents/projects"
up; sleep 4
is "a project off the list stays closed, a new one opens" "$(tm list-windows -t agents -F '#{window_name}=#{window_panes}' | tr '\n' ' ')" "Ptwo=5 p two=1 P3=1 "
down; cp "$SBX/projects.bak" "$H/.config/agents/projects"

echo "Agents that start a moment apart"
cp "$SBX/layout.before" "$L"; printf 'start-gap 1\n' > "$H/.config/agents/settings"; sum=$(bare "$L" | cksum); : > "$H/started.log"
up; sleep 2.5
waiting=0; for p in $(tm list-panes -a -F '#{pane_id}'); do if tm capture-pane -p -t "$p" | grep -q 'Starts in'; then waiting=$((waiting + 1)); fi; done
if (( waiting > 0 )); then ok "after a restart some agents wait their turn ($waiting were waiting 2 s in)"; else bad "after a restart some agents wait their turn" "none was waiting"; fi
is "while they wait, the saved layout is left alone" "$(bare "$L" | cksum)" "$sum"
until_true 20 test "$(wc -l < "$H/started.log")" -ge 9 || true; sleep 1
is "then all of them have started" "$(wc -l < "$H/started.log")" 9
is "in the same places as before" "$(geo)" "$(cat "$SBX/before.txt")"
printf 'start-gap 0\n' > "$H/.config/agents/settings"

echo "The watcher"
until_true 12 saved 11 || true
for w in $(pgrep -f "$A --layout-wat[c]h"); do kill "$w" 2>/dev/null; done; sleep 0.5
is "stopped by hand" "$(watchers)" 0
mark "$(tm display -p -t agents:1.1 '#{pane_id}')" done; sleep 1.5
if (( $(watchers) > 0 )); then ok "starts again at the next finished turn"; else bad "starts again at the next finished turn" "no watcher"; fi
sleep 3; touch "$H/claude-slow"; sum=$(cksum < "$L"); p0=$(tm display -p -t agents:1.1 '#{pane_pid}')
tm split-window -fh -t agents:1 "$A --pane claude $p0 main"; sleep 4
is "writes nothing while a new agent is still starting" "$(cksum < "$L")" "$sum"
until_true 15 saved 12 && ok "and writes the new split down once its chat is known" || bad "and writes the new split down once its chat is known" "$(grep -c '^P' "$L") splits on file"
hasnt "never without that chat" "$(cat "$L")" $'^P\tclaude\t[^\t]*\t-\t'
rm -f "$H/claude-slow"; down

echo "Chats that cannot simply be reopened"
EMPTY=11111111-aaaa-4bbb-8ccc-000000000001; OPEN=22222222-aaaa-4bbb-8ccc-000000000002
ids=($(awk -F'\t' '$1 == "P" && $2 == "claude" { print $4 }' "$SBX/layout.before"))
sed -e "s/${ids[0]}/$EMPTY/" -e "s/${ids[1]}/$OPEN/" "$SBX/layout.before" > "$L"
: >> "$H/.claude/projects/stub/$OPEN.jsonl"
( cd "$P1" && sb setsid claude --resume "$OPEN" >/dev/null 2>&1 & ); sleep 1
touch "$H/gemini-no-sessions"; : > "$H/started.log"
up; sleep 5
st=$(cat "$H/started.log")
hasnt "a chat nothing was said in is not resumed" "$st" "resume $EMPTY"
has "it comes back as a new chat" "$st" 'claude --allow-dangerously-skip-permissions \| cfg=\.claude \| cwd=.*/p1$'
shown=""; for p in $(tm list-panes -t agents:1 -F '#{pane_id}'); do shown+=$(tm capture-pane -p -t "$p"); done
has "a chat that is open in another window is not opened twice" "$shown" 'already open in another window'
is "Gemini with no earlier chat starts a new one instead" "$(grep -c '^gemini' <<< "$st")" 3
rm -f "$H/gemini-no-sessions"; pkill -f "^/bin/bash $H/.local/bin/claude --resume $OPEN" 2>/dev/null; down

# ---------------------------------------------------------------------------------- work folders
echo "Work folders"
rm -f "$L"; up; sleep 1.5
p0=$(tm display -p -t agents:1.1 '#{pane_pid}'); p1=$(tm display -p -t agents:2.1 '#{pane_pid}'); : > "$H/started.log"
tm split-window -fh -t agents:1 "$A --pane wt-claude $p0 main"; sleep 2.5
WT="$SBX/proj/.acf-worktrees/p1-1"
if [[ -d "$WT" ]]; then ok "a split can get a folder of its own"; else bad "a split can get a folder of its own" "no $WT"; fi
is "on a branch of its own" "$(git -C "$WT" branch --show-current 2>/dev/null)" "acf/p1-1"
has "the agent starts in it" "$(cat "$H/started.log")" "cwd=$WT\$"
wp=$(tm list-panes -t agents:1 -F '#{pane_id} #{pane_start_command}' | awk '/wt-claude/ {print $1}')
is "the pane header is told the branch" "$(tm display -p -t "$wp" '#{@wt}')" "acf/p1-1"
has "agents --worktrees lists it as in use" "$(sb "$A" --worktrees)" 'acf/p1-1 .*in use'
logs_project=$(HOME="$H" python3 -I -c 'import runpy, sys; m = runpy.run_path(sys.argv[1], run_name="x"); print(m["worktree_main"](sys.argv[2]))' "$( [[ -e "$BIN/afc-logs" ]] && echo "$BIN/afc-logs" || echo "$REPO/bin/afc-logs")" "$WT" 2>&1)
is "the chat log knows which project it came from" "$logs_project" "$(readlink -f "$P1")"
tm split-window -fh -t agents:2 "$A --pane wt-claude $p1 main"; sleep 1.5
shown=""; for p in $(tm list-panes -t agents:2 -F '#{pane_id}'); do shown+=$(tm capture-pane -p -t "$p"); done
has "a folder that is not a git project says so and starts no agent" "$shown" 'No work folder was made'
out=$(echo y | sb "$A" --worktrees --prune 2>&1)
if [[ -d "$WT" ]]; then ok "a work folder in use is not removed"; else bad "a work folder in use is not removed" "$out"; fi
tm kill-pane -t "$wp"; sleep 0.5
out=$(echo y | sb "$A" --worktrees --prune 2>&1)
if [[ ! -d "$WT" ]] && ! git -C "$P1" show-ref --verify --quiet refs/heads/acf/p1-1; then ok "a finished one is removed, with its branch"; else bad "a finished one is removed, with its branch" "$out"; fi

# ---------------------------------------------------------------------------------- handing a chat on
echo "Handing a chat to another tool"
pane=$(tm display -p -t agents:1.1 '#{pane_id}'); pid=$(tm display -p -t agents:1.1 '#{pane_pid}')
cl=$(pgrep -P "$pid" -x claude | head -1); chat=$(jq -r .sessionId "$H/.claude/sessions/$cl.json" 2>/dev/null)
echo "the earlier chat" > "$H/thread-$chat.md"; : > "$H/started.log"
sb "$A" --switch codex:main "$pane" "$pid" handoff >/dev/null 2>&1; sleep 2.5
has "the new agent is started on the log of the chat it takes over" "$(cat "$H/started.log")" "^codex The work in this folder .*$H/thread-$chat.md"
pid=$(tm display -p -t agents:1.1 '#{pane_pid}'); : > "$H/started.log"
sb "$A" --switch gemini "$pane" "$pid" fresh >/dev/null 2>&1; sleep 2
is "\"a new chat\" starts it with nothing" "$(cut -d'|' -f1 "$H/started.log")" "gemini  "

echo "Menus and the tmux config"
is "the tmux config loads without complaint" "$(tm source-file "$H/.tmux.conf" 2>&1)" ""
has "Alt+L is bound to the overview" "$(tm list-keys -T root 2>/dev/null)" 'M-l .*--overview-menu'
( sb script -qfc "tmux -L $SOCK attach -t agents" /dev/null >/dev/null 2>&1 & ); sleep 1.5
client=$(tm list-clients -F '#{client_name}' | head -1)
if [[ -n "$client" ]]; then
  pane=$(tm display -p -t agents:2.1 '#{pane_id}'); pid=$(tm display -p -t agents:2.1 '#{pane_pid}')
  is "the overview menu opens" "$(sb "$A" --overview-menu "$client" 2>&1; echo "rc=$?")" "rc=0"; tm send-keys -t "$pane" Escape 2>/dev/null
  is "the split menu's work-folder page says no in a folder without git" "$(sb "$A" --split-menu "$client" "$pane" "$pid" wt 2>&1; echo "rc=$?")" "rc=0"
  is "the split menu opens" "$(sb "$A" --split-menu "$client" "$pane" "$pid" 2>&1; echo "rc=$?")" "rc=0"
  is "the account menu opens, with each account's limits" "$(echo 'S12% W30%' > "$H/usage-main"; sb "$A" --account-menu "$client" "$pane" "$pid" 2>&1; echo "rc=$?")" "rc=0"
  is "Alt+G to another tool asks what to start from" "$(sb "$A" --switch codex:main "$pane" "$pid" ask "$client" 2>&1; echo "rc=$?")" "rc=0"
  is "and starts nothing until that is answered" "$(tm display -p -t "$pane" '#{pane_pid}')" "$pid"
else bad "a stand-in terminal could be attached for the menu checks" "no client"; fi

echo "The check-up"
doc=$(sb "$A" --doctor 2>&1)
has "agents --doctor reports on programs, hooks, services, fleet and lists" "$(tr '\n' ' ' <<< "$doc")" 'Programs.*Hooks.*Background services.*Fleet.*Lists'
has "and sees the watcher running" "$doc" 'ok +the watcher is running'

echo
echo "$n_pass passed, $n_fail failed."
(( n_fail == 0 ))
