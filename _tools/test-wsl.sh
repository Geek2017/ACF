#!/usr/bin/env bash
# test-wsl.sh: pretend to be WSL and check what the fleet asks Windows to do.
# Windows itself is stood in for: powershell.exe, wt.exe, cmd.exe, wslpath, clip.exe are scripts
# that record how they were called and answer the way Windows would. This proves the plumbing in
# bin/agents (which call, which arguments, which quoting) -- not that Windows behaves as expected.
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
REPO=${ACF_REPO:?set ACF_REPO to the project folder}
SBX=$(mktemp -d); H="$SBX/home"; W="$SBX/win"; SOCK="$SBX/tmux.sock"
pass=0; fail=0
ok()   { printf '  pass  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }
has()  { if grep -qF -e "$2" "$1" 2>/dev/null; then ok "$3"; else no "$3" "not in $(basename "$1"): $2"; fi; }
hasnt(){ if grep -qF -e "$2" "$1" 2>/dev/null; then no "$3" "found in $(basename "$1"): $2"; else ok "$3"; fi; }
cleanup() { "$TMUX" -L wsltest kill-server 2>/dev/null; rm -rf "$SBX"; }
trap cleanup EXIT

TMUX=$(command -v tmux)
UB="$SBX/ubin"; mkdir -p "$UB"
for f in /usr/bin/*; do ln -s "$f" "$UB/${f##*/}" 2>/dev/null; done
rm -f "$UB/kdialog" "$UB/xclip" "$UB/notify-send" "$UB/zenity"   # a Windows PC has no X desktop
ln -sf "$TMUX" "$UB/tmux"       # the patched build: the system one cannot talk to its server
mkdir -p "$H/.local/bin" "$H/.local/lib/afc" "$H/.config/agents" "$H/.claude" "$W" "$SBX/proj"
ln -s "$REPO/bin/agents" "$H/.local/bin/agents"
for f in afc-agent-info afc-min afc-reflow afc-move afc-logs; do ln -sf "$REPO/bin/$f" "$H/.local/bin/$f"; done
printf 'proj %s\n' "$SBX/proj" > "$H/.config/agents/projects"
printf 'main ~/.claude\n' > "$H/.config/agents/accounts"
printf 'start-gap 0\n' > "$H/.config/agents/settings"
A="$H/.local/bin/agents"

# ------------------------------------------------------------------ Windows, stood in for
CLIP="$SBX/clipboard"; KIND="$SBX/clipkind"; echo text > "$KIND"; printf 'hello from windows' > "$CLIP"
mk() { cat > "$W/$1"; chmod +x "$W/$1"; }
mk powershell.exe <<EOF
#!/usr/bin/env bash
# Stands in for Windows PowerShell. Decodes -EncodedCommand the way Windows would, records it,
# and answers as the real one would for the few things the fleet asks.
b=""; prev=""
for a in "\$@"; do [[ "\$prev" == -EncodedCommand ]] && b=\$a; prev=\$a; done
[[ -n "\$b" ]] || { echo "NO ENCODED COMMAND: \$*" >> "$W/ps.log"; exit 1; }
cmd=\$(printf '%s' "\$b" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null)
{ echo "--- call"; printf '%s\n' "\$cmd"; } >> "$W/ps.log"
case "\$cmd" in
  *"Get-Clipboard -Format Image"*) [[ "\$(cat "$KIND")" == image ]] && printf 'image\r\n' ;;
  *"Get-Clipboard -Raw"*)          printf '%s\r\n' "\$(cat "$CLIP")" ;;
  *FolderBrowserDialog*)           printf 'C:\\\\Users\\\\jo\\\\picked\r\n' ;;
  *ToastNotification*)             printf 'toast shown\r\n' ;;
  *AppActivate*)                   [[ -e "$W/wt-running" ]] && printf 'ok\r\n' ;;
esac
exit 0
EOF
mk wslpath <<EOF
#!/usr/bin/env bash
# -w: Linux path -> Windows path. -u: back again. Only what the fleet uses.
case "\$1" in
  -w) printf '%s\n' "\\\\\\\\wsl.localhost\\\\Ubuntu\${2//\//\\\\}" ;;
  -u) p=\${2//\\\\//}; case "\$p" in C:/*) printf '%s\n' "/mnt/c/\${p#C:/}" ;; *) printf '%s\n' "\$p" ;; esac ;;
esac
EOF
mk wt.exe <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/wt.log"
EOF
mk cmd.exe <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/cmd.log"
[[ "\$*" == *LOCALAPPDATA* ]] && printf 'C:\\\\Users\\\\jo\\\\AppData\\\\Local\r\n'
exit 0
EOF
mk clip.exe <<EOF
#!/usr/bin/env bash
cat > "$W/clip-got"
EOF

export WSL_DISTRO_NAME=Ubuntu
run() { env -u DISPLAY -i HOME="$H" PATH="$W:$UB" WSL_DISTRO_NAME=Ubuntu \
            AGENTS_SOCK=wsltest TERM=xterm LANG=C.UTF-8 bash "$A" "$@" 2>&1; }

echo "Finding Windows"
out=$(run --doctor)
has <(printf '%s' "$out") "Windows is reachable" "the fleet sees it is on Windows and finds PowerShell"
has <(printf '%s' "$out") "Windows Terminal (wt.exe)" "it finds Windows Terminal"
hasnt <(printf '%s' "$out") "keepawake-agents" "it does not ask for keep-awake, which Windows has no use for"
has <(printf '%s' "$out") "of this PC's memory" "it says how much of the PC's memory WSL was given"

echo "The clipboard"
"$TMUX" -L wsltest -f /dev/null new-session -d -s t "cat > $SBX/paned" 2>/dev/null
sleep 1
pane=$("$TMUX" -L wsltest list-panes -F '#{pane_id}' | head -1)
SOCK=$("$TMUX" -L wsltest display -p '#{socket_path}')
: > "$W/ps.log"
echo text > "$KIND"; printf 'hello from windows' > "$CLIP"
run --paste "$pane" "$SOCK" >/dev/null
has "$W/ps.log" "Get-Clipboard -Format Image" "it asks Windows whether an image is on the clipboard"
has "$W/ps.log" "Get-Clipboard -Raw" "then asks for the text"
"$TMUX" -L wsltest send-keys -t "$pane" Enter; sleep 1
if python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if d == b"hello from windows\n" else 1)' "$SBX/paned" 2>/dev/null
then ok "the text reaches the pane exactly, with no newline added"
else no "the text reaches the pane exactly, with no newline added" "pane got: $(od -c "$SBX/paned" 2>/dev/null | head -3 | tr '\n' ' ')"; fi
: > "$W/ps.log"; echo image > "$KIND"
run --paste "$pane" "$SOCK" >/dev/null
hasnt "$W/ps.log" "Get-Clipboard -Raw" "an image is handed to the agent instead of pasted as text"

echo "Quoting (a project path Windows would choke on)"
: > "$W/ps.log"
mkdir -p "$SBX/it's a \"project\""
run --pick "$SBX/it's a \"project\"" >/dev/null 2>&1
has "$W/ps.log" "FolderBrowserDialog" "Alt+N opens Windows' folder dialog"
has "$W/ps.log" "it''s a" "a quote in the path is doubled, so it cannot break out of the PowerShell string"

echo "Notifications"
: > "$W/ps.log"
run --notify "$pane" done 99 >/dev/null 2>&1
has "$W/ps.log" "ToastNotification" "a finished turn sends a Windows toast"

echo "The Agents window"
: > "$W/wt.log"
run --new-window >/dev/null 2>&1 &
sleep 2; kill %1 2>/dev/null
has "$W/wt.log" "wsl.exe -d Ubuntu" "it opens Windows Terminal on this distro"
has "$W/wt.log" "-w new" "in a window of its own"

echo "The copy (afc-copy to Windows' clipboard)"
cp_run() { env -i HOME="$H" PATH="$W:$UB" WSL_DISTRO_NAME=Ubuntu DISPLAY=:0 LANG=C.UTF-8 \
             python3 "$REPO/bin/afc-copy" --width 0 "$@"; }
cc=$(env -i HOME="$H" PATH="$UB" WSL_DISTRO_NAME=Ubuntu TERM=xterm "$TMUX" -L wslconf -f "$REPO/tmux/tmux.conf" \
       new-session -d -s c 'sleep 30' \; show -sv copy-command 2>/dev/null)
"$TMUX" -L wslconf kill-server 2>/dev/null
if [[ "$cc" == *afc-copy* ]]; then ok "under WSL the tmux config still copies through afc-copy (no clip.exe of its own)"
else no "under WSL the tmux config still copies through afc-copy (no clip.exe of its own)" "copy-command is: $cc"; fi
mk xclip <<EOF
#!/usr/bin/env bash
cat > "$W/xclip-got"
EOF
rm -f "$W/clip-got" "$W/xclip-got"
printf '  ● plain words\n' | cp_run
if [[ "$(cat "$W/clip-got" 2>/dev/null)" == "plain words" ]]; then ok "a copy goes to clip.exe, cleaned, even with WSLg's xclip there"
else no "a copy goes to clip.exe, cleaned, even with WSLg's xclip there" "clip.exe got: $(cat "$W/clip-got" 2>/dev/null)"; fi
[[ -e "$W/xclip-got" ]] && no "and not to xclip" || ok "and not to xclip"
rm -f "$W/xclip"
printf 'plain words' | cp_run
if python3 -c 'import sys; sys.exit(0 if open(sys.argv[1], "rb").read() == b"plain words" else 1)' "$W/clip-got"
then ok "plain ASCII reaches clip.exe as it is"; else no "plain ASCII reaches clip.exe as it is" "$(od -c "$W/clip-got" | head -2)"; fi
printf 'em dash — tick ✓ café' | cp_run
if python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if d[:2] == b"\xff\xfe" and d[2:].decode("utf-16-le") == "em dash — tick ✓ café" else 1)' "$W/clip-got"
then ok "anything else goes as UTF-16 behind a byte-order mark, so Windows does not turn it into mojibake"
else no "anything else goes as UTF-16 behind a byte-order mark, so Windows does not turn it into mojibake" "$(od -c "$W/clip-got" | head -2)"; fi

echo "The machine wall (WSL with no agents.slice to read)"
printf '%s 10 95\n' "$(date +%s)" > "$SBX/load-full"; printf '%s 10 40\n' "$(date +%s)" > "$SBX/load-calm"
room() { env -i HOME="$H" PATH="$W:$UB" WSL_DISTRO_NAME=Ubuntu TERM=xterm LANG=C.UTF-8 AGENTS_SOCK=wsltest \
           AGENTS_STAT="$SBX/no-slice/memory.stat" AGENTS_LOAD="$1" bash "$A" --room 2>&1; }
out=$(room "$SBX/load-full"); rc=$?
if (( rc == 1 )) && [[ "$out" == *"RAM is 95% full"* ]]; then ok "with RAM 95% full a new agent is refused, though there is no slice to weigh"
else no "with RAM 95% full a new agent is refused, though there is no slice to weigh" "exit $rc: $out"; fi
out=$(room "$SBX/load-calm"); rc=$?
(( rc == 0 )) && ok "and let through at 40%" || no "and let through at 40%" "exit $rc: $out"

echo "When Windows is out of reach"
out=$(env -i HOME="$H" PATH="$UB" WSL_DISTRO_NAME=Ubuntu TERM=xterm LANG=C.UTF-8 bash "$A" --doctor 2>&1)
has <(printf '%s' "$out") "Windows interop looks turned off" "with no powershell.exe it says interop is off"
has <(printf '%s' "$out") "wsl --shutdown" "and gives the line that fixes it"

echo
echo "$pass passed, $fail failed."
exit $(( fail > 0 ))
