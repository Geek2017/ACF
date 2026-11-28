#!/usr/bin/env bash
# install.sh: set a machine up to run the fleet FROM this folder. The reverse of collect.sh.
#
#   bash _tools/install.sh                  DRY RUN (the default): say what would change, touch nothing
#   bash _tools/install.sh --apply          do it
#   bash _tools/install.sh --apply --copy   do it with real copies instead of links (for a machine
#                                           where this folder will not stay put)
#
# Two kinds of file:
#   LINKED   the fleet's own programs, its library, the tmux config, the launcher files. The home
#            path becomes a link to the file in this folder, so the folder is where they live and
#            an edit here is live at once.
#   COPIED   machine plumbing and machine data: the resource guard (autonice, jobq, keepawake),
#            the systemd units, the account / project / price lists, the terminal config. These
#            must keep working even if this folder's disk is not mounted, so they are real files
#            in the home folder; this folder keeps a copy.
# Any home file that would be replaced is first kept as <file>.bak-<date>.
#
# What it does NOT do, on purpose:
#   - sign any account in, or touch .credentials.json / .claude.json
#   - edit Claude's or Gemini's settings.json: it prints the keys to merge (config/claude, config/gemini)
#   - build the patched tmux: that is _tools/build-tmux.sh
#   - restart the fleet or reload systemd: it prints the commands
set -euo pipefail
APPLY=0; COPY=0
for a in "$@"; do case "$a" in --apply) APPLY=1 ;; --copy) COPY=1 ;; *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac; done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)
same=0; changed=0

# Stand-in names in the copied lists under config/ are swapped back to the machine's real names,
# using the private map ~/.config/agents/copy-names ("<name here> <stand-in>" per line). On a
# machine with no map the lists are installed as they are, stand-ins and all.
MAP="$HOME/.config/agents/copy-names"
UNSWAP=()
if [[ -r "$MAP" ]]; then
  while read -r live standin _; do
    [[ -z "$live" || "$live" == \#* || -z "$standin" ]] && continue
    UNSWAP+=(-e "s/\\b${standin}\\b/${live}/g")
  done < "$MAP"
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

keep() { [[ -e "$1" || -L "$1" ]] && cp -pP "$1" "$1.bak-$STAMP"; return 0; }

copy() {  # <path inside the project> <target file> [mode]
  local src="$HERE/$1" dst=$2 mode=${3:-}
  [[ -e "$src" ]] || { echo "  not in the project: $1"; return 0; }
  if [[ "$1" == config/* ]] && (( ${#UNSWAP[@]} )) && grep -Iq . "$src" 2>/dev/null; then
    sed "${UNSWAP[@]}" "$src" > "$TMP/f"; touch -r "$src" "$TMP/f"; chmod --reference="$src" "$TMP/f"; src="$TMP/f"
  fi
  # A launcher runs `agents` by its full path, so it names this machine's home folder, not the one
  # it was collected from.
  if [[ "$1" == share/applications/*.desktop ]]; then
    sed -E "s|^(Exec=)[^ ]*/\.local/bin/|\1$HOME/.local/bin/|" "$src" > "$TMP/f"
    touch -r "$src" "$TMP/f"; chmod --reference="$src" "$TMP/f"; src="$TMP/f"
  fi
  # Auto-scale RAM/CPU/slot limits to the installing machine's specs (RAM + CPU cores).
  case "$1" in
    config/systemd/user/agents.slice|config/systemd/user/app.slice.d/memory.conf|config/systemd/user/agents-council.slice|config/systemd/user/agents-express.slice|config/autonice/rules)
      if [[ -r "$HERE/_tools/tune-specs.py" ]] && command -v python3 >/dev/null 2>&1; then
        local tflags=()
        (( DESKTOP )) || tflags+=(--headless)
        python3 -I "$HERE/_tools/tune-specs.py" "${tflags[@]}" apply "$1" "$src" "$TMP/tuned"
        touch -r "$src" "$TMP/tuned"; chmod --reference="$src" "$TMP/tuned"; src="$TMP/tuned"
      fi
      ;;
  esac
  if [[ -e "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then same=$((same + 1)); return 0; fi
  changed=$((changed + 1))
  if (( ! APPLY )); then echo "  would $([[ -e "$dst" || -L "$dst" ]] && echo replace || echo create) $dst (copy)"; return 0; fi
  mkdir -p "$(dirname "$dst")"; keep "$dst"; rm -f "$dst"
  cp -p "$src" "$dst"
  [[ -n "$mode" ]] && chmod "$mode" "$dst"
  echo "  copied  $dst"
}

link() {  # <path inside the project> <target file> [mode]
  if (( COPY )); then copy "$@"; return 0; fi
  local src="$HERE/$1" dst=$2
  [[ -e "$src" ]] || { echo "  not in the project: $1"; return 0; }
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then same=$((same + 1)); return 0; fi
  changed=$((changed + 1))
  if (( ! APPLY )); then echo "  would $([[ -e "$dst" || -L "$dst" ]] && echo replace || echo create) $dst (link)"; return 0; fi
  mkdir -p "$(dirname "$dst")"; keep "$dst"
  ln -s "$src" "$dst.acf-new" && mv -Tf "$dst.acf-new" "$dst"      # swapped in one step: never a moment without it
  echo "  linked  $dst"
}

# KDE: the Agents window's own icon is Alacritty's (it puts its icon on every window it opens), and
# KWin shows that in the title bar. A window rule ties the window (class Agents) to agents.desktop,
# and KWin then takes the icon from the launcher: the logo. Added to the rule for that window when
# there is one (the "reopen where it was" rule), else as a rule of its own. Nothing without KWin.
kwin_logo() {
  local kw rc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrulesrc" g found="" list
  command -v kwin_x11 >/dev/null || command -v kwin_wayland >/dev/null || return 0
  kw=$(command -v kwriteconfig6 || command -v kwriteconfig5) || return 0
  section() { [[ -r "$rc" ]] || return 0; awk -v g="[$1]" '$0 == g { s = 1; next } /^\[/ { s = 0 } s' "$rc" 2>/dev/null; }
  list=$(section General | sed -n 's/^rules=//p')
  for g in ${list//,/ }; do
    if section "$g" | grep -qx 'wmclass=agents'; then found=$g; break; fi
  done
  if [[ -n "$found" ]] && section "$found" | grep -qx 'desktopfile=agents' && section "$found" | grep -qx 'desktopfilerule=2'; then
    same=$((same + 1)); return 0
  fi
  changed=$((changed + 1))
  if (( ! APPLY )); then echo "  would add a KWin rule: the Agents window shows the logo ($rc)"; return 0; fi
  keep "$rc"
  if [[ -z "$found" ]]; then
    found=agents-logo
    "$kw" --file "$rc" --group "$found" --key Description "Agents window: the fleet's logo as its icon"
    "$kw" --file "$rc" --group "$found" --key wmclass agents
    "$kw" --file "$rc" --group "$found" --key wmclassmatch 1
    "$kw" --file "$rc" --group "$found" --key types 1
    list=${list:+$list,}$found
    "$kw" --file "$rc" --group General --key rules "$list"
    "$kw" --file "$rc" --group General --key count "$(tr ',' '\n' <<< "$list" | grep -c .)"
  fi
  "$kw" --file "$rc" --group "$found" --key desktopfile agents
  "$kw" --file "$rc" --group "$found" --key desktopfilerule 2
  { qdbus6 org.kde.KWin /KWin reconfigure || qdbus org.kde.KWin /KWin reconfigure; } >/dev/null 2>&1 || true
  echo "  KWin rule: the Agents window shows the logo (from the next window it opens)"
}

# A Mac gets the fleet's programs and lists only: the resource guard, the systemd units, the KDE
# launcher files and the Alacritty config are for Linux (_tools/mac-setup.sh is what a Mac runs).
# Windows runs it in WSL, which IS Linux and keeps the guard and the units; what it skips is the
# desktop around them, since the window is Windows Terminal's (_tools/windows-setup.sh).
MAC=0; [[ "$(uname -s)" == Darwin ]] && MAC=1
DESKTOP=1; (( MAC )) && DESKTOP=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then DESKTOP=0; fi
GUARD=" autonice jobq keepawake-agents "
for f in "$HERE"/bin/*; do
  [[ -f "$f" ]] || continue            # not a program: a __pycache__ left by python3, say
  b=$(basename "$f")
  [[ "$b" == *.bak-* ]] && continue    # a copy kept by hand before an edit, not a program
  if [[ "$GUARD" == *" $b "* ]]; then (( MAC )) || copy "bin/$b" "$HOME/.local/bin/$b" 755; else link "bin/$b" "$HOME/.local/bin/$b" 755; fi
done
for f in "$HERE"/lib/afc/*; do [[ -f "$f" ]] && link "lib/afc/$(basename "$f")" "$HOME/.local/lib/afc/$(basename "$f")"; done
link tmux/tmux.conf "$HOME/.tmux.conf"
if (( DESKTOP )); then
  link share/agents/kwin-focus.js "$HOME/.local/share/agents/kwin-focus.js"
  # A real file, never a link: KDE will not start a launcher whose real path is outside its own
  # folders ("Access denied, not owned by root and executable flag not set"), so a link into this
  # folder leaves the Agents menu entry and its shortcut dead.
  copy share/applications/agents.desktop "$HOME/.local/share/applications/agents.desktop" 755
  # The logo (made from logo.png by build-logo.py): the launcher's and the taskbar's icon, and the
  # splash's frames. Real files, so they still show when this folder's disk is not mounted.
  for f in "$HERE"/share/icons/hicolor/*/apps/acf.png; do [[ -f "$f" ]] && copy "${f#"$HERE"/}" "$HOME/.local/${f#"$HERE"/}"; done
  for f in "$HERE"/share/acf/*; do [[ -f "$f" ]] && copy "share/acf/${f##*/}" "$HOME/.local/share/acf/${f##*/}"; done
  kwin_logo
fi
for f in "$HERE"/share/llm-usage/nobrowser/*; do link "share/llm-usage/nobrowser/$(basename "$f")" "$HOME/.local/share/llm-usage/nobrowser/$(basename "$f")" 755; done

if (( ! MAC )); then
  for f in "$HERE"/config/systemd/user/* "$HERE"/config/systemd/user/*/*; do
    [[ -f "$f" ]] || continue
    rel=${f#"$HERE/config/systemd/user/"}
    if [[ "$rel" == app.slice.d/* ]] && (( ! DESKTOP )); then continue; fi
    copy "config/systemd/user/$rel" "$HOME/.config/systemd/user/$rel"
  done
fi
for f in "$HERE"/config/agents/*; do copy "config/agents/$(basename "$f")" "$HOME/.config/agents/$(basename "$f")"; done
if (( DESKTOP )); then
  copy config/autonice/rules "$HOME/.config/autonice/rules"
  copy config/alacritty/alacritty.toml "$HOME/.config/alacritty/alacritty.toml"
fi

if (( APPLY )); then [[ -e "$HOME/.local/bin/afc" ]] || ln -s agents "$HOME/.local/bin/afc"
elif [[ ! -e "$HOME/.local/bin/afc" ]]; then echo "  would link ~/.local/bin/afc -> agents"; fi
# /collab in each Claude account and Gemini home (a /collab of your own is left alone)
python3 -I "$HERE/bin/afc-collab" install $( ((APPLY)) || echo --dry-run ) | sed 's/^/  /' || echo "  afc-collab install failed"

echo
echo "$( ((APPLY)) || echo 'DRY RUN: ' )$changed file(s) $( ((APPLY)) && echo 'set up' || echo 'would change' ), $same already as they should be."
(( APPLY )) || echo "Nothing was changed. Run again with --apply to do it."
cat <<'EOF'

Left for you:
  1. Merge config/claude/settings.fleet-keys.json into ~/.claude/settings.json (keys: tui, statusLine, hooks).
  2. Merge config/gemini/settings.fleet-keys.json into ~/.gemini/settings.json (keys: experimental, modelConfigs).
  3. systemctl --user daemon-reload && systemctl --user enable --now autonice.service afc-logs.timer afc-tmp-clean.timer
  4. Build the patched tmux if ~/.local/opt/tmux-3.8 is missing:  bash _tools/build-tmux.sh
     then point the tmux command at it:  ln -s ~/.local/opt/tmux-3.8/bin/tmux ~/.local/bin/tmux
  5. Sign each account in:  agents --as <account>  then /login.  Then start the fleet:  agents
EOF
