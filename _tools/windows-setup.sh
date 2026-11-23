#!/usr/bin/env bash
# windows-setup.sh: set Windows up to run the fleet, in one go. The fleet is a tmux program, and
# tmux is not a Windows program, so it runs in WSL2 — real Linux, on the same PC. Run this INSIDE
# the WSL window (Start > Ubuntu), as yourself, not as root:
#
#   git clone https://github.com/Geek2017/ACF.git ~/acf
#   bash ~/acf/_tools/windows-setup.sh             do it (sudo asks for your Linux password)
#   bash ~/acf/_tools/windows-setup.sh --dry-run   say what it would do, change nothing
#   bash ~/acf/_tools/windows-setup.sh --copy      real copies in the home folder instead of links
#
# No WSL yet? In a Windows PowerShell started as administrator:  wsl --install -d Ubuntu
# then restart, let Ubuntu make your Linux user, and run the three lines above in its window.
#
# What this does:
#   1. Checks WSL: systemd on (the budget and the chat-log timer need it) and Windows reachable
#      from Linux. systemd is turned on here, in /etc/wsl.conf; it takes a restart of WSL, which
#      only Windows can do, so this stops and tells you the one line to run.
#   2. _tools/server-setup.sh for everything that is plain Linux: apt packages, Claude Code,
#      install.sh, agents.slice sized for this machine, the patched tmux, Claude's settings,
#      linger and the background services.
#   3. A "Fleet" profile in Windows Terminal, so the fleet is one click from the drop-down.
#   4. Says what to put in .wslconfig when WSL has too little of the PC's memory.
# Every step is skipped when it is already done, so running it again is safe.
#
# What Windows gets that a headless server does not: sign-in opens your real browser, the clipboard
# is shared both ways, notifications are Windows toasts, and Alt+N opens Windows' folder dialog.
# What it does not get: the keep-screen-awake service (Windows decides when it sleeps; while it
# sleeps, so do the agents), and a toast has no "Open the tab" button the way Linux's has.
#
# Keep projects in the Linux home folder, not on C:. A project under /mnt/c is several times
# slower, because every file an agent reads crosses between Windows and Linux.
set -euo pipefail
DRY=0; PASS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1; PASS+=(--dry-run) ;;
    --copy) PASS+=(--copy) ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LEFT=()

step() { printf '\n== %s\n' "$1"; }
run()  { if (( DRY )); then printf '  would run: %s\n' "$*"; else "$@"; fi; }

[[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null || {
  echo "This is not WSL. On Windows, open the Ubuntu window (Start > Ubuntu) and run it there." >&2
  echo "On an Ubuntu server: bash _tools/server-setup.sh   On a Mac: bash _tools/mac-setup.sh" >&2
  exit 1; }
(( EUID != 0 )) || { echo "Run this as yourself, not as root. It calls sudo itself." >&2; exit 1; }
DISTRO=${WSL_DISTRO_NAME:-Ubuntu}
(( DRY )) && echo "DRY RUN: nothing is changed."

step "WSL itself"
if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]]; then echo "  systemd is on"
else
  if grep -qs '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then
    echo "  systemd is set in /etc/wsl.conf but is not running yet: WSL has to be restarted."
  elif (( DRY )); then echo "  would add [boot] systemd=true to /etc/wsl.conf (needs sudo)"
  else
    printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    echo "  turned systemd on in /etc/wsl.conf"
  fi
  if (( ! DRY )); then
    echo
    echo "  WSL has to restart before systemd runs, and only Windows can do that. In a Windows"
    echo "  PowerShell or Command Prompt window (not this one), run:"
    echo
    echo "      wsl --shutdown"
    echo
    echo "  Then open Ubuntu again and run this script again. It carries on from here."
    exit 0
  fi
fi
if command -v powershell.exe >/dev/null || command -v pwsh.exe >/dev/null; then echo "  Windows is reachable from here (powershell.exe)"
else
  echo "  !! no powershell.exe on the PATH: Windows interop looks turned off."
  echo "     The fleet still runs, but the clipboard, notifications and the folder dialog will not."
  LEFT+=("Turn Windows interop on: put [interop] enabled=true and appendWindowsPath=true in /etc/wsl.conf, then run wsl --shutdown in a Windows window.")
fi
mem=$(awk '/^MemTotal:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo)
echo "  WSL has ${mem}G of this PC's memory and $(nproc) core(s)"

step "The fleet: everything that is plain Linux (_tools/server-setup.sh, its own steps 1-7)"
LEFTFILE=$(mktemp)
trap 'rm -f "$LEFTFILE"' EXIT
ACF_SETUP_NAME="this PC's WSL" ACF_SETUP_TAIL=0 ACF_SETUP_LEFT="$LEFTFILE" \
  bash "$HERE/_tools/server-setup.sh" "${PASS[@]}"
while IFS= read -r l; do [[ -n "$l" ]] && LEFT+=("$l"); done < "$LEFTFILE"

step "Windows Terminal"
# Its settings.json lives under the Store app's folder; the path differs between the Store build,
# the preview build and the unpackaged one, so look for whichever is there.
WTDIR=""
WLAD=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r' || true)
for d in "$(wslpath -u "$WLAD" 2>/dev/null || true)"; do
  [[ -n "$d" && -d "$d" ]] || continue
  for c in "Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState" \
           "Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState" \
           "Microsoft/Windows Terminal"; do
    [[ -e "$d/$c/settings.json" ]] && { WTDIR="$d/$c"; break 2; }
  done
done
# The profile's icon is the fleet's logo: share/acf/acf.ico (made from logo.png by build-logo.py),
# copied to %LOCALAPPDATA%\AgenticCLIFleet, since Windows Terminal reads an icon from a Windows path.
# Without it, the old ⌨️.
ICON="⌨️"
ICODIR=$(wslpath -u "$WLAD" 2>/dev/null || true)
if [[ -n "$WTDIR" && -n "$ICODIR" && -d "$ICODIR" && -f "$HERE/share/acf/acf.ico" ]]; then
  if (( DRY )); then ICON="$WLAD\\AgenticCLIFleet\\acf.ico"; echo "  would copy the logo to $ICON"
  elif mkdir -p "$ICODIR/AgenticCLIFleet" && cp -f "$HERE/share/acf/acf.ico" "$ICODIR/AgenticCLIFleet/acf.ico"; then
    ICON="$WLAD\\AgenticCLIFleet\\acf.ico"
  fi
fi
if [[ -z "$WTDIR" ]]; then
  echo "  Windows Terminal's settings were not found: no profile added."
  echo "  (Get Windows Terminal from the Microsoft Store; it is the one that draws the fleet properly.)"
  LEFT+=("Install Windows Terminal from the Microsoft Store, then run this script again to add the Fleet profile.")
elif grep -q '"name": *"Fleet"' "$WTDIR/settings.json" 2>/dev/null; then
  # A Fleet profile made before the logo still has the ⌨️ (or no icon): it gets the logo. An icon
  # you chose yourself is left alone.
  old=$(jq -r '[.profiles.list[]? | select(.name == "Fleet") | (.icon // "")][0] // ""' "$WTDIR/settings.json" 2>/dev/null || echo "?")
  if [[ "$ICON" == "⌨️" || ( "$old" != "⌨️" && -n "$old" ) ]] || ! command -v jq >/dev/null; then
    echo "  the Fleet profile is already there"
  elif (( DRY )); then echo "  the Fleet profile is already there; would give it the logo as its icon"
  else
    cp -p "$WTDIR/settings.json" "$WTDIR/settings.json.bak-$(date +%Y%m%d-%H%M%S)"
    jq --arg i "$ICON" '(.profiles.list[]? | select(.name == "Fleet") | .icon) = $i' "$WTDIR/settings.json" \
        > "$WTDIR/settings.json.acf-new" \
      && mv -f "$WTDIR/settings.json.acf-new" "$WTDIR/settings.json" \
      && echo "  the Fleet profile is already there; its icon is now the logo" \
      || { rm -f "$WTDIR/settings.json.acf-new"; echo "  the Fleet profile is already there (its icon could not be changed)"; }
  fi
elif (( DRY )); then echo "  would add a Fleet profile to $WTDIR/settings.json"
elif ! command -v jq >/dev/null; then
  echo "  !! jq is not installed yet: no profile added."
  LEFT+=("Run this script again (jq comes with step 2) to add the Fleet profile to Windows Terminal.")
else
  cp -p "$WTDIR/settings.json" "$WTDIR/settings.json.bak-$(date +%Y%m%d-%H%M%S)"
  jq --arg d "$DISTRO" --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg i "$ICON" '
    .profiles.list = ((.profiles.list // []) + [{
      name: "Fleet",
      guid: ("{" + $g + "}"),
      commandline: ("wsl.exe -d " + $d + " --cd ~ -- $HOME/.local/bin/agents"),
      icon: $i,
      startingDirectory: null,
      closeOnExit: "always"
    }])' "$WTDIR/settings.json" > "$WTDIR/settings.json.acf-new" \
    && mv -f "$WTDIR/settings.json.acf-new" "$WTDIR/settings.json" \
    && echo "  added a Fleet profile (the old settings are kept beside it as .bak-<date>)" \
    || { echo "  !! could not edit $WTDIR/settings.json"; LEFT+=("Add a Windows Terminal profile running: wsl.exe -d $DISTRO --cd ~ -- \$HOME/.local/bin/agents"); }
fi

echo
if (( DRY )); then echo "DRY RUN: nothing was changed. Run it again without --dry-run to do it."; exit 0; fi
acct=$(awk '!/^#/ && NF { print $1; exit }' "$HOME/.config/agents/accounts" 2>/dev/null || true)
echo "Done. Left for you:"
n=1
for l in "${LEFT[@]}"; do echo "  $n. $l"; n=$((n + 1)); done
echo "  $n. Sign in:        agents --as ${acct:-main}     then /login (it opens your Windows browser)"
echo "  $((n + 1)). Add a project:  cd <its folder> && agents --add     (keep it under $HOME, not on /mnt/c)"
echo "  $((n + 2)). Start:          agents     (or the Fleet profile in Windows Terminal's drop-down)"
echo "                  leave it running: Ctrl+B then D; come back: agents"
echo
if (( $(awk '/^MemTotal:/ { print int($2 / 1048576) }' /proc/meminfo) < 8 )); then
  echo "WSL has only ${mem}G of memory, which is tight for several agents. To give it more, make"
  echo "%UserProfile%\\.wslconfig on Windows say:"
  echo "    [wsl2]"
  echo "    memory=16GB"
  echo "then run  wsl --shutdown  in a Windows window. The budget resizes itself when you delete"
  echo "~/.config/systemd/user/agents.slice and run this script again."
  echo
fi
echo "agents --doctor checks the set-up, including the Windows side."
