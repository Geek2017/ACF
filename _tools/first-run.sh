#!/usr/bin/env bash
# first-run.sh: the fleet's first start on a machine where it came from the .deb (build-deb.sh), for
# the user who started it. The package puts the fleet in /opt/agentic-cli-fleet (root's, read-only);
# this sets this user up to run it from there, then opens it. No sudo:
#
#   1. ~/.local/opt/tmux-3.8 points at the patched tmux the package brings, so nothing is built
#   2. _tools/server-setup.sh: Claude Code when it is missing (its own installer), install.sh
#      --apply (the programs linked to the package's, the Agents launcher, the logo, the lists, the
#      units), agents.slice sized for this machine, Claude's settings, the background services.
#      Linger is left off: on a desktop the fleet runs while you are logged in.
#   3. keep-awake on (the screen and the machine stay up while agents work)
#
# The "Agents" app-menu entry runs it (through /usr/bin/agentic-cli-fleet) in a terminal window,
# with the splash in front, the first time; after that the same entry opens the fleet. By hand:
#   bash /opt/agentic-cli-fleet/_tools/first-run.sh [--dry-run]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY=(); [[ "${1:-}" == --dry-run ]] && DRY=(--dry-run)
(( EUID != 0 )) || { echo "Run this as yourself, not as root." >&2; exit 1; }

printf '\n  Agentic CLI Fleet %s: setting the fleet up for %s on %s\n' \
  "$(cat "$ROOT/VERSION" 2>/dev/null || echo)" "$(id -un)" "$(hostname)"

printf '\n== The patched tmux\n'
T="$HOME/.local/opt/tmux-3.8"
if [[ -x "$T/bin/tmux" ]]; then echo "  already there: $T"
elif [[ -e "$T" || -L "$T" ]]; then echo "  !! $T is there but has no bin/tmux: left alone (server-setup.sh builds one)"
elif [[ ! -x "$ROOT/tmux-3.8/bin/tmux" ]]; then echo "  the package has none: server-setup.sh builds it"
elif (( ${#DRY[@]} )); then echo "  would link $T to the package's ($ROOT/tmux-3.8)"
else mkdir -p "${T%/*}"; ln -s "$ROOT/tmux-3.8" "$T"; echo "  $T -> $ROOT/tmux-3.8 ($("$T/bin/tmux" -V))"
fi

LEFTFILE=$(mktemp); trap 'rm -f "$LEFTFILE"' EXIT
ACF_SETUP_NAME="this computer" ACF_SETUP_LINGER=0 ACF_SETUP_TAIL=0 ACF_SETUP_LEFT="$LEFTFILE" \
  bash "$ROOT/_tools/server-setup.sh" "${DRY[@]}"
LEFT=(); while IFS= read -r l; do [[ -n "$l" ]] && LEFT+=("$l"); done < "$LEFTFILE"

printf '\n== Keep-awake\n'
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || ! command -v systemctl >/dev/null; then echo "  not here (no screen to keep awake)"
elif (( ${#DRY[@]} )); then echo "  would run: systemctl --user enable --now keepawake-agents.service"
elif systemctl --user enable --now keepawake-agents.service 2>/dev/null; then echo "  keepawake-agents.service on"
else echo "  !! could not start keepawake-agents.service"; fi

echo
(( ${#DRY[@]} )) && { echo "DRY RUN: nothing was changed."; exit 0; }
acct=$(awk '!/^#/ && NF { print $1; exit }' "$HOME/.config/agents/accounts" 2>/dev/null || true)
echo "Done. Left for you:"
n=1
for l in "${LEFT[@]}"; do echo "  $n. $l"; n=$((n + 1)); done
echo "  $n. Sign in:        agents --as ${acct:-main}     then type /login (your browser opens)"
echo "  $((n + 1)). Add a project:  in the fleet, Alt+N picks a folder (or: cd <folder> && agents --add)"
echo "  $((n + 2)). Codex, Gemini, Antigravity: install the ones you want; agents --doctor checks it all"
echo
if [[ -t 0 ]]; then
  read -rp "Press Enter to open the fleet now (or close this window and open Agents later) " _ || exit 0
  # in a window of its own (the Agents window, with the splash), and this set-up window closes
  setsid "$HOME/.local/bin/agents" --new-window >/dev/null 2>&1 < /dev/null &
fi
