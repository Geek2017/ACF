#!/usr/bin/env bash
# collect.sh: bring the machine-side files of the fleet INTO this project folder.
#
# The fleet's own programs and its tmux config LIVE in this folder: their home-folder paths
# (~/.local/bin/agents, ~/.tmux.conf, ...) are links to the files here, so there is nothing to
# collect for those. What still lives in the home folder is machine plumbing and machine data:
# the resource guard, the systemd units, the account / project / price lists, the terminal config.
# This script copies those in, so the folder also records how this machine is set up.
#
#   bash _tools/collect.sh            copy
#   bash _tools/collect.sh --dry-run  say what would be copied, change nothing
#
# Never copied: sign-ins (.credentials.json, .claude.json), chats, logs, the built tmux program.
# From Claude's and Gemini's settings only the fleet's own keys are taken (see the two jq lines).
# Names listed in ~/.config/agents/copy-names (a private map kept on the machine, not here) are
# swapped for stand-ins in the copied lists under config/, so this folder never carries them.
set -euo pipefail
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1
HERE="$(cd "$(dirname "$0")/.." && pwd)"
n=0; missing=0; lives=0

put() {  # <source file> <path inside the project>
  local src=$1 dst="$HERE/$2"
  if [[ ! -e "$src" ]]; then echo "  missing: $src"; missing=$((missing + 1)); return 0; fi
  if [[ -e "$dst" && "$(readlink -f "$src")" == "$(readlink -f "$dst")" ]]; then lives=$((lives + 1)); return 0; fi   # a link to this folder
  if (( DRY )); then echo "  would copy $src -> $2"; else mkdir -p "$(dirname "$dst")"; cp -pL "$src" "$dst"; fi
  n=$((n + 1))
}

B="$HOME/.local/bin"
for f in agents afc-agent-info afc-bar afc-copy afc-council afc-even afc-gap afc-logs afc-longcopy afc-min afc-model-menu afc-move \
         afc-reflow afc-statusline llm-usage claude-usage autonice jobq keepawake-agents; do
  put "$B/$f" "bin/$f"
done
put "$HOME/.local/lib/afc/pb.py" "lib/afc/pb.py"

put "$HOME/.tmux.conf" "tmux/tmux.conf"
put "$HOME/.local/opt/tmux-3.8/afc-thin-scrollbar.patch" "tmux/afc-tmux-3.8.patch"

U="$HOME/.config/systemd/user"
for f in agents.slice agents-pool.service autonice.service keepawake-agents.service afc-logs.service afc-logs.timer; do
  put "$U/$f" "config/systemd/user/$f"
done

A="$HOME/.config/agents"
for f in accounts accounts-agy accounts-codex accounts-gemini account-labels prices projects log-projects settings; do
  put "$A/$f" "config/agents/$f"
done
put "$HOME/.config/autonice/rules" "config/autonice/rules"
put "$HOME/.config/alacritty/alacritty.toml" "config/alacritty/alacritty.toml"

put "$HOME/.local/share/agents/kwin-focus.js" "share/agents/kwin-focus.js"
put "$HOME/.local/share/applications/agents.desktop" "share/applications/agents.desktop"
for f in "$HOME/.local/share/llm-usage/nobrowser/"*; do
  [[ -e "$f" ]] && put "$f" "share/llm-usage/nobrowser/$(basename "$f")"
done

# Only the fleet's own keys from the agents' settings files: never the whole file.
snippet() {  # <settings file> <jq filter> <path inside the project>
  if [[ ! -r "$1" ]]; then echo "  missing: $1"; missing=$((missing + 1)); return 0; fi
  if (( DRY )); then echo "  would write $3 (selected keys of $1)"; else mkdir -p "$(dirname "$HERE/$3")"; jq "$2" "$1" > "$HERE/$3"; fi
  n=$((n + 1))
}
snippet "$HOME/.claude/settings.json" '{tui, statusLine, hooks}' "config/claude/settings.fleet-keys.json"
snippet "$HOME/.gemini/settings.json" '{experimental, modelConfigs}' "config/gemini/settings.fleet-keys.json"

# Names that must not appear in this folder are swapped for stand-ins in the copied files under
# config/ only (never in bin/ or tmux/: those are the live programs), using a map that stays on
# the machine (~/.config/agents/copy-names: "<name here> <stand-in>" per line, whole words, exact
# case). install.sh swaps them back. With no map file, nothing is swapped.
MAP="$HOME/.config/agents/copy-names"
swapped=0
if [[ -r "$MAP" ]] && (( ! DRY )); then
  args=()
  while read -r live standin _; do
    [[ -z "$live" || "$live" == \#* || -z "$standin" ]] && continue
    args+=(-e "s/\\b${live}\\b/${standin}/g")
  done < "$MAP"
  if (( ${#args[@]} )); then
    while IFS= read -r -d '' f; do
      grep -Iq . "$f" 2>/dev/null || continue          # text files only
      before=$(cksum < "$f"); sed -i "${args[@]}" "$f"
      [[ "$(cksum < "$f")" == "$before" ]] || swapped=$((swapped + 1))
    done < <(find "$HERE/config" -type f -print0)
  fi
fi
(( swapped )) && echo "  names swapped for stand-ins in $swapped file(s)"

echo "$( ((DRY)) && echo 'DRY RUN: ' )$n file(s) copied in, $lives already live here (linked)$( ((missing)) && echo ", $missing missing" )"
(( missing == 0 ))
