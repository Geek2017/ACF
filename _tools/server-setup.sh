#!/usr/bin/env bash
# server-setup.sh: set a newly installed Ubuntu server (no desktop) up to run the fleet, in one go.
# Run it ON the server, over SSH, as the user the agents will run as (not root):
#
#   git clone https://github.com/Geek2017/ACF.git ~/acf
#   bash ~/acf/_tools/server-setup.sh             do it (sudo asks for your password)
#   bash ~/acf/_tools/server-setup.sh --dry-run   say what it would do, change nothing
#   bash ~/acf/_tools/server-setup.sh --copy      real copies in the home folder instead of links
#                                                 (for when this folder will not stay where it is)
#
# What it does:
#   1. apt: git, the build tools, jq, python3, curl. Plus tmux's build libraries when the ones
#      kept in tmux/deps do not fit this machine (they are for Ubuntu 24.04 on amd64).
#   2. Claude Code, with its own installer, when `claude` is missing.
#   3. _tools/install.sh --apply: programs, tmux config, lists and systemd units into the home
#      folder. First run only: a later run just reports what install.sh would change, because
#      it would put this folder's copies of the lists and units back over yours.
#   4. agents.slice sized for THIS machine (the copy in this folder is sized for the desktop it
#      came from): all cores but one, slowed at 75% of memory, stopped at 85%. Only on the run
#      that installs the files, or when the unit is missing; a unit that is there is left alone.
#   5. _tools/build-tmux.sh: the patched tmux, and ~/.local/bin/tmux pointing at it.
#   6. ~/.claude/settings.json: the fleet's keys (classic mode, status line, hooks).
#   7. Linger on, so the fleet keeps running after you log out, and the background services
#      started: agents-pool, autonice, afc-logs.
# Every step is skipped when it is already done, so running it again is safe.
#
# What it leaves alone: sign-ins (it prints how at the end); Codex, Gemini and Antigravity
# (install the ones you want yourself); the keep-screen-awake service (a server has no screen);
# and what only a desktop has: the Agents window, the Alt+N folder dialog, image paste.
set -euo pipefail
DRY=0; COPY=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --copy) COPY=(--copy) ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ME=$(id -un)
# _tools/windows-setup.sh runs this script for the Linux half of a WSL set-up and then adds the
# Windows half, so it asks for its own wording and its own closing advice:
#   ACF_SETUP_NAME  what to call this machine in what is printed   ACF_SETUP_TAIL=0  no closing advice
#   ACF_SETUP_LEFT  a file to write what could not be done into, one per line
#   ACF_SETUP_LINGER=0  leave linger off (the .deb's first run on a desktop: no sudo asked)
WHAT=${ACF_SETUP_NAME:-this server}
PATH_BEFORE=$PATH
export PATH="$HOME/.local/bin:$PATH"
LEFT=()   # things this run could not do, repeated at the end

step() { printf '\n== %s\n' "$1"; }
run()  { if (( DRY )); then printf '  would run: %s\n' "$*"; else "$@"; fi; }

(( EUID != 0 )) || { echo "Run this as the user the agents will run as, not as root. It calls sudo itself." >&2; exit 1; }
command -v apt-get >/dev/null || { echo "This script is for Ubuntu / Debian: it installs with apt." >&2; exit 1; }
(( DRY )) && echo "DRY RUN: nothing is changed."

step "1. Packages"
ID=""; VERSION_ID=""; [[ -r /etc/os-release ]] && . /etc/os-release
pk=(git jq python3 curl ca-certificates procps)
# The build tools only when tmux is to be built here: the .deb brings it built (_tools/first-run.sh
# points ~/.local/opt/tmux-3.8 at it), so a machine set up from the package needs no sudo for them.
BUILT=0; [[ -x "$HOME/.local/opt/tmux-3.8/bin/tmux" ]] && BUILT=1
(( BUILT )) || pk+=(build-essential pkg-config patch)
SYSDEPS=()
if [[ "$(dpkg --print-architecture)" != amd64 || "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
  SYSDEPS=(--system-deps); (( BUILT )) || pk+=(libevent-dev libncurses-dev bison)
fi
need=()
for p in "${pk[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || need+=("$p")
done
if (( ${#need[@]} == 0 )); then echo "  all there"
else
  run sudo apt-get update -q
  run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${need[@]}"
fi

step "2. Claude Code"
if command -v claude >/dev/null; then echo "  already there: $(command -v claude)"
elif (( DRY )); then echo "  would run Claude Code's own installer (https://claude.ai/install.sh)"
else curl -fsSL https://claude.ai/install.sh | bash
fi

step "3. The fleet's files"
FRESH=0
if [[ ! -e "$HOME/.local/bin/agents" ]]; then
  FRESH=1
  if (( DRY )); then bash "$HERE/_tools/install.sh" "${COPY[@]}" | sed '/^Left for you:/,$d'
  else bash "$HERE/_tools/install.sh" --apply "${COPY[@]}" | sed '/^Left for you:/,$d'; fi
else
  echo "  installed before. What install.sh would change now (it is not run again here, because it"
  echo "  puts this folder's copies of the lists and units over yours):"
  bash "$HERE/_tools/install.sh" "${COPY[@]}" | sed '/^Left for you:/,$d' | sed '/^$/d; /^Nothing was changed/d' | tail -4
  echo "  To take those:  bash $HERE/_tools/install.sh --apply"
  # Programs added to the fleet since then (afc-council, afc-copy, afc-even ...) would have no link
  # and their keys would do nothing, so each missing one is linked now. Programs only: the lists,
  # the units and anything already in place are left as they are.
  for f in "$HERE"/bin/* "$HERE"/lib/afc/*; do
    [[ -f "$f" ]] || continue
    b=${f##*/}
    case "$b" in *.bak-*|autonice|jobq|keepawake-agents) continue ;; esac     # the guard is copied, at the first run
    case "$f" in "$HERE"/lib/*) dst="$HOME/.local/lib/afc/$b" ;; *) dst="$HOME/.local/bin/$b" ;; esac
    if [[ -e "$dst" || -L "$dst" ]]; then continue; fi
    run mkdir -p "${dst%/*}"
    if (( ${#COPY[@]} )); then run cp "$f" "$dst"; run chmod 755 "$dst"; else run ln -s "$f" "$dst"; fi
    (( DRY )) || echo "  new since the last set-up, now in place: $dst"
  done
fi

step "4. The resource budget (agents.slice)"
U="$HOME/.config/systemd/user/agents.slice"
cores=$(nproc); cap=$(( cores > 1 ? cores - 1 : 1 ))
mem=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
high=$(( mem * 75 / 100 )); max=$(( mem * 85 / 100 ))
if [[ -e "$U" ]] && (( ! FRESH )); then
  if cmp -s "$U" "$HERE/config/systemd/user/agents.slice"; then
    echo "  $U is this folder's copy, sized for the desktop it came from: left alone."
    echo "  To have it sized for this machine, delete it and run this again."
  else echo "  $U is already this machine's own: left alone"; fi
elif (( DRY )); then
  echo "  would size it for $WHAT ($cores cores, $mem MB): $cap core(s), slowed at $high MB, stopped at $max MB"
else
  mkdir -p "${U%/*}"
  cat > "$U" <<EOF
[Unit]
Description=Capped CPU group for AI agents and builds (autonice moves them here)

[Slice]
# Sized by _tools/server-setup.sh for $WHAT ($cores cores, $mem MB of memory): all cores but
# one, slowed at 75% of memory, one runaway agent stopped at 85%. Change the numbers and run:
#   systemctl --user daemon-reload
CPUQuota=$(( cap * 100 ))%
MemoryHigh=${high}M
MemoryMax=${max}M
MemorySwapMax=1G
# At most 2500 processes (threads count too; a busy fleet is 350-450). Past it a new one fails to
# start, so a pile-up of helpers stops itself instead of filling the memory.
TasksMax=2500
EOF
  echo "  sized for $WHAT ($cores cores, $mem MB): $cap core(s), slowed at $high MB, stopped at $max MB"
  echo "  change it in $U"
fi

step "5. The patched tmux"
T="$HOME/.local/opt/tmux-3.8/bin/tmux"
if [[ -x "$T" ]]; then echo "  already built: $("$T" -V)"
else run bash "$HERE/_tools/build-tmux.sh" "${SYSDEPS[@]}"
fi
L="$HOME/.local/bin/tmux"
if [[ "$(readlink -f "$L" 2>/dev/null)" == "$T" ]]; then echo "  ~/.local/bin/tmux points at it"
elif [[ -e "$L" && ! -L "$L" ]]; then
  echo "  !! $L is a program of its own, left alone. The fleet will use that one, not the patched build."
  LEFT+=("Replace $L with a link to the patched build:  ln -sf $T $L")
else run ln -sfn "$T" "$L"
fi

step "6. Claude's settings"
S="$HOME/.claude/settings.json"; K="$HERE/config/claude/settings.fleet-keys.json"
if [[ ! -e "$S" ]]; then
  run mkdir -p "$HOME/.claude"; run cp "$K" "$S"
  (( DRY )) || echo "  wrote $S"
elif grep -qs 'agents --mark' "$S"; then echo "  the fleet's hooks are already in $S"
elif (( DRY )); then echo "  would add the fleet's keys to $S if it has no hooks or status line of its own"
elif jq -e 'has("hooks") or has("statusLine") | not' "$S" >/dev/null 2>&1; then
  cp -p "$S" "$S.bak-$(date +%Y%m%d-%H%M%S)"
  jq -s '.[0] * .[1]' "$S" "$K" > "$S.acf-new" && mv -f "$S.acf-new" "$S"
  echo "  added the fleet's keys to $S (the old file is kept beside it as .bak-<date>)"
else
  echo "  !! $S has hooks or a status line of its own: not touched."
  LEFT+=("Merge $K into $S (keys: tui, statusLine, hooks)")
fi

step "7. Linger and the background services"
if ! command -v systemctl >/dev/null || ! command -v loginctl >/dev/null; then
  echo "  !! no systemd on this machine: the fleet will run with no resource budget and no chat log"
  LEFT+=("No systemd here: nothing caps the agents and afc-logs is not scheduled.")
else
  if [[ "$(loginctl show-user "$ME" -p Linger --value 2>/dev/null)" == yes ]]; then echo "  linger is already on"
  elif [[ "${ACF_SETUP_LINGER:-1}" == 0 ]]; then echo "  linger left off (on a desktop the fleet runs while you are logged in)"
  else run sudo loginctl enable-linger "$ME"; fi
  if (( DRY )); then
    echo "  would run: systemctl --user daemon-reload"
    echo "  would run: systemctl --user enable --now agents-pool.service autonice.service afc-logs.timer"
  elif systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable --now agents-pool.service autonice.service afc-logs.timer
    for u in agents-pool.service autonice.service afc-logs.timer; do
      printf '  %-22s %s\n' "$u" "$(systemctl --user is-active "$u" 2>/dev/null || true)"
    done
  else
    echo "  !! this shell cannot reach your systemd user session (logged in through su or sudo -u?)"
    LEFT+=("Log in over SSH as $ME and run:  systemctl --user daemon-reload && systemctl --user enable --now agents-pool.service autonice.service afc-logs.timer")
  fi
fi

echo
[[ -z "${ACF_SETUP_LEFT:-}" ]] || { : > "$ACF_SETUP_LEFT"; ((${#LEFT[@]} == 0)) || printf '%s\n' "${LEFT[@]}" > "$ACF_SETUP_LEFT"; }
if (( DRY )); then [[ "${ACF_SETUP_TAIL:-1}" == 1 ]] && echo "DRY RUN: nothing was changed. Run it again without --dry-run to do it."; exit 0; fi
[[ "${ACF_SETUP_TAIL:-1}" == 1 ]] || exit 0          # windows-setup.sh prints its own closing advice
acct=$(awk '!/^#/ && NF { print $1; exit }' "$HOME/.config/agents/accounts" 2>/dev/null || true)
echo "Done. Left for you:"
n=1
for l in "${LEFT[@]}"; do echo "  $n. $l"; n=$((n + 1)); done
case ":$PATH_BEFORE:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  $n. Log out and back in, so that ~/.local/bin is on your PATH."; n=$((n + 1)) ;;
esac
echo "  $n. Sign in:        agents --as ${acct:-main}     then type /login, open the link on your own computer, paste the code back"
echo "  $((n + 1)). Add a project:  cd <its folder> && agents --add"
echo "  $((n + 2)). Start:          agents     (leave it running: Ctrl+B then D; come back: agents)"
echo
echo "The accounts are listed in ~/.config/agents/accounts; the names there are yours to change."
echo "agents --doctor checks the set-up. On a server it reports keepawake-agents as not running: that is expected."
