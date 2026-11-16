#!/bin/bash
# mac-setup.sh: set a Mac up to run the fleet, in one go. Run it ON the Mac, as yourself (not root):
#
#   git clone https://github.com/Geek2017/ACF.git ~/acf
#   bash ~/acf/_tools/mac-setup.sh             do it
#   bash ~/acf/_tools/mac-setup.sh --dry-run   say what it would do, change nothing
#   bash ~/acf/_tools/mac-setup.sh --copy      real copies in the home folder instead of links
#                                              (for when this folder will not stay where it is)
#
# The fleet was written for Linux. On a Mac its programs run under Homebrew's bash with Homebrew's
# GNU tools, and read processes through afc-procfs instead of /proc (lib/afc/mac.sh says how).
# What this does:
#   1. Homebrew packages: bash, coreutils, gnu-sed, gawk, grep, findutils, flock (what the
#      programs use), pkgconf, libevent, utf8proc (what the tmux build needs), jq when missing.
#   2. _tools/install.sh --apply: programs, tmux config and lists into the home folder. First run
#      only: a later run just reports what install.sh would change, because it would put this
#      folder's copies of the lists back over yours.
#   3. _tools/build-tmux.sh: the patched tmux, and ~/.local/bin/tmux pointing at it.
#   4. ~/.claude/settings.json: the fleet's keys (classic mode, status line, hooks).
#   5. The chat log every 15 minutes, as a launchd job (io.github.acf.afc-logs).
#   6. ~/.local/bin on your PATH, by one line in ~/.zprofile, when it is not there yet.
# Every step is skipped when it is already done, so running it again is safe.
#
# What a Mac does not get: the resource budget (agents.slice, autonice, jobq are Linux's cgroups
# and systemd, so nothing caps the agents here), keep-awake, desktop notifications, and the plan
# limits in the pane headers (Claude keeps its sign-in in the Keychain on a Mac, not in a file).
# It leaves alone: sign-ins, and the agents themselves (claude, codex, gemini, agy: install the
# ones you want). In Terminal, turn on Settings > Profiles > Keyboard > "Use Option as Meta key":
# the fleet's keys are all Alt+something.
#
# Written for the Mac's own bash 3.2: it runs before Homebrew's bash is there.
set -euo pipefail
DRY=0; COPY=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --copy) COPY=--copy ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LEFT=""   # things this run could not do, repeated at the end (one per line)

step() { printf '\n== %s\n' "$1"; }
run()  { if (( DRY )); then printf '  would run: %s\n' "$*"; else "$@"; fi; }
left() { LEFT="$LEFT$1"$'\n'; }

[[ "$(uname -s)" == Darwin ]] || { echo "This script is for a Mac. On an Ubuntu server: bash _tools/server-setup.sh" >&2; exit 1; }
(( EUID != 0 )) || { echo "Run this as yourself, not as root." >&2; exit 1; }
BREW=/opt/homebrew; [[ -x "$BREW/bin/brew" ]] || BREW=/usr/local
[[ -x "$BREW/bin/brew" ]] || { echo "Homebrew is not installed. Get it from https://brew.sh, then run this again." >&2; exit 1; }
GNU="$BREW/opt/coreutils/libexec/gnubin:$BREW/opt/gnu-sed/libexec/gnubin"   # for install.sh only
(( DRY )) && echo "DRY RUN: nothing is changed."

step "1. Homebrew packages"
need=""
for p in bash coreutils gnu-sed gawk grep findutils flock pkgconf libevent utf8proc; do
  [[ -d "$BREW/opt/$p" ]] || need="$need $p"
done
command -v jq >/dev/null 2>&1 || [[ -x "$BREW/bin/jq" ]] || need="$need jq"
if [[ -z "$need" ]]; then echo "  all there"
else
  # shellcheck disable=SC2086
  run env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW/bin/brew" install $need
fi
for c in claude codex gemini agy; do
  if PATH="$HOME/.local/bin:$BREW/bin:$PATH" command -v "$c" >/dev/null 2>&1; then have="${have:-} $c"; fi
done
echo "  agents on this Mac:${have:- none}"
[[ " ${have:-} " == *" claude "* ]] || left "Install Claude Code (https://claude.com/claude-code): every project tab starts it."

step "2. The fleet's files"
FRESH=0
inst() { PATH="$GNU:$BREW/bin:$PATH" "$BREW/bin/bash" "$HERE/_tools/install.sh" "$@" $COPY | sed '/^Left for you:/,$d'; }
if [[ ! -e "$HOME/.local/bin/agents" ]]; then
  FRESH=1
  if (( DRY )); then
    if [[ -x "$BREW/bin/bash" && -d "$BREW/opt/coreutils" ]]; then inst; else echo "  would run _tools/install.sh --apply (it needs the packages of step 1 first)"; fi
  else inst --apply; fi
else
  echo "  installed before. What install.sh would change now (it is not run again here, because it"
  echo "  puts this folder's copies of the lists over yours):"
  inst | sed '/^$/d; /^Nothing was changed/d' | tail -4
  echo "  To take those:  PATH=\"$GNU:\$PATH\" $BREW/bin/bash $HERE/_tools/install.sh --apply"
fi

step "3. The patched tmux"
T="$HOME/.local/opt/tmux-3.8/bin/tmux"
if [[ -x "$T" ]]; then echo "  already built: $("$T" -V)"
else run env PATH="$BREW/bin:$PATH" "$BREW/bin/bash" "$HERE/_tools/build-tmux.sh"
fi
L="$HOME/.local/bin/tmux"
if [[ -L "$L" && "$(readlink "$L")" == "$T" ]]; then echo "  ~/.local/bin/tmux points at it"
elif [[ -e "$L" && ! -L "$L" ]]; then
  echo "  !! $L is a program of its own, left alone. The fleet will use that one, not the patched build."
  left "Replace $L with a link to the patched build:  ln -sf $T $L"
else run ln -sfn "$T" "$L"
fi

step "4. Claude's settings"
S="$HOME/.claude/settings.json"; K="$HERE/config/claude/settings.fleet-keys.json"; JQ=$(PATH="$BREW/bin:$PATH" command -v jq || true)
if [[ ! -e "$S" ]]; then
  run mkdir -p "$HOME/.claude"; run cp "$K" "$S"
  (( DRY )) || echo "  wrote $S"
elif grep -qs 'agents --mark' "$S"; then echo "  the fleet's hooks are already in $S"
elif (( DRY )); then echo "  would add the fleet's keys to $S if it has no hooks or status line of its own"
elif [[ -n "$JQ" ]] && "$JQ" -e 'has("hooks") or has("statusLine") | not' "$S" >/dev/null 2>&1; then
  cp -p "$S" "$S.bak-$(date +%Y%m%d-%H%M%S)"
  "$JQ" -s '.[0] * .[1]' "$S" "$K" > "$S.acf-new" && mv -f "$S.acf-new" "$S"
  echo "  added the fleet's keys to $S (the old file is kept beside it as .bak-<date>)"
else
  echo "  !! $S has hooks or a status line of its own: not touched."
  left "Merge $K into $S (keys: tui, statusLine, hooks)"
fi

step "5. The chat log, every 15 minutes (launchd)"
JOB=io.github.acf.afc-logs; PL="$HOME/Library/LaunchAgents/$JOB.plist"
plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- ACF chat log: copy new agent chat records into each project's logs/acf (afc-logs). Written by _tools/mac-setup.sh. -->
<dict>
  <key>Label</key><string>$JOB</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/afc-logs</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$HOME/.local/bin:$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>19</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/acf-afc-logs.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/acf-afc-logs.log</string>
</dict>
</plist>
EOF
}
if [[ -e "$PL" ]] && [[ "$(plist)" == "$(cat "$PL")" ]] && launchctl print "gui/$(id -u)/$JOB" >/dev/null 2>&1; then echo "  already scheduled"
elif (( DRY )); then echo "  would write $PL and load it"
else
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  plist > "$PL"
  launchctl bootout "gui/$(id -u)/$JOB" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$PL" 2>/dev/null; then echo "  scheduled: $JOB (its output: ~/Library/Logs/acf-afc-logs.log)"
  else
    echo "  !! wrote $PL but could not load it from this shell (no desktop session?)"
    left "Load the chat log job once you are logged in at the Mac:  launchctl bootstrap gui/\$(id -u) $PL"
  fi
fi

step "6. PATH"
ZP="$HOME/.zprofile"
if /bin/zsh -lc 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0 ;; *) exit 1 ;; esac' 2>/dev/null; then echo "  ~/.local/bin is on your PATH"
elif (( DRY )); then echo "  would add ~/.local/bin to PATH in $ZP"
else
  printf '\n# Agentic CLI Fleet: its programs (agents, afc-logs ...) live in ~/.local/bin\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$ZP"
  echo "  added ~/.local/bin to PATH in $ZP (open a new Terminal window for it to count)"
fi

echo
if (( DRY )); then echo "DRY RUN: nothing was changed. Run it again without --dry-run to do it."; exit 0; fi
acct=$(awk '!/^#/ && NF { print $1; exit }' "$HOME/.config/agents/accounts" 2>/dev/null || true)
echo "Done. Left for you:"
n=1
while IFS= read -r l; do [[ -n "$l" ]] || continue; echo "  $n. $l"; n=$((n + 1)); done <<< "$LEFT"
echo "  $n. Terminal > Settings > Profiles > Keyboard: turn on \"Use Option as Meta key\" (the fleet's keys are Alt+something)."
echo "  $((n + 1)). Open a new Terminal window, then add a project:  cd <its folder> && agents --add"
echo "  $((n + 2)). Start:  agents     (leave it running: Ctrl+B then D; come back: agents)"
echo
echo "Claude uses the sign-in this Mac already has. Other accounts are listed in ~/.config/agents/accounts"
echo "(sign one in: agents --as ${acct:-main}, then /login). agents --doctor checks the set-up."
(( FRESH )) && echo "Nothing caps the agents' memory or CPU on a Mac: the resource budget is Linux only."
exit 0
