# mac.sh: read first thing by the fleet's shell programs on macOS, never on Linux.
#
# The programs are written for bash 4 or newer, GNU tools and /proc. A Mac has bash 3.2, BSD
# tools and no /proc. So here:
#   - a program that the Mac's old bash started is started again under Homebrew's bash
#   - the GNU tools Homebrew installs with a g in front (gdate, gstat, gsed ...) are used under
#     their plain names INSIDE the program, through shell functions. PATH is not changed for
#     that, so the agents in the panes keep the Mac's own tools.
#   - $PROC is where afc-procfs writes what Linux has in /proc, and "pf <pid>..." asks it to.
#     The files are a snapshot, so a program calls pf right before it reads them.
#   - p_comm and p_age answer two single questions without that detour.
# The tools come from _tools/mac-setup.sh (brew install bash coreutils gnu-sed gawk grep findutils flock).
BREW=/opt/homebrew; [[ -d "$BREW/bin" ]] || BREW=/usr/local
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x "$BREW/bin/bash" ]]; then exec "$BREW/bin/bash" "$0" "$@"; fi
  echo "${0##*/}: needs bash 4 or newer. On a Mac: bash _tools/mac-setup.sh" >&2
  exit 1
fi
case ":$PATH:" in *":$BREW/bin:"*) ;; *) PATH="$PATH:$BREW/bin" ;; esac
for _c in cp mv ln ls date stat readlink numfmt timeout mktemp sort head tail touch chmod realpath du sed awk grep find xargs; do
  if _g=$(command -v "g$_c" 2>/dev/null); then eval "$_c() { \"$_g\" \"\$@\"; }"; fi
done
unset _c _g
MAC=1
PROC="${TMPDIR:-/tmp}"; PROC="${PROC%/}/afc-proc"
pf() { "$HOME/.local/bin/afc-procfs" "$@" 2>/dev/null || true; }
p_comm() {  # pid -> its short name, as Linux shows it
  local c; c=$(ps -o ucomm= -p "$1" 2>/dev/null) || return 1
  c=${c%"${c##*[![:space:]]}"}
  case "$c" in claude.exe) c=claude ;; antigravity) c=agy ;; esac
  printf '%s\n' "$c"
}
p_age() {  # pid -> the seconds it has been running (ps gives [[dd-]hh:]mm:ss here)
  local e; e=$(ps -o etime= -p "$1" 2>/dev/null) || return 1
  awk '{ n = split($1, a, "-"); m = split(a[n], b, ":"); s = 0; for (i = 1; i <= m; i++) s = s * 60 + b[i]; print (n == 2 ? a[1] * 86400 : 0) + s }' <<< "$e"
}
