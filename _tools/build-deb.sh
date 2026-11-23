#!/usr/bin/env bash
# build-deb.sh: the fleet as a Debian package, the installer for an Ubuntu desktop (24.04, amd64):
#   dist/agentic-cli-fleet_<VERSION>_amd64.deb
#
#   bash _tools/build-deb.sh              build it (about a minute: the patched tmux is compiled)
#   bash _tools/build-deb.sh --dry-run    say what it would put in, build nothing
#   bash _tools/build-deb.sh --no-tmux    leave the tmux build out (the first run then builds it)
#
# What the package holds:
#   /opt/agentic-cli-fleet/            this folder: programs, library, launcher files, the logo, the
#                                      tools, the tmux source and patch. Not .git, logs/, dist/, the
#                                      hand-kept .bak copies; the lists under config/agents/ go in
#                                      as empty templates (this machine's projects, accounts and
#                                      chat-log folders stay here)
#   /opt/agentic-cli-fleet/tmux-3.8/   the patched tmux, built for that place (build-tmux.sh)
#   /usr/bin/agentic-cli-fleet         the launcher: set up already, it opens the fleet window;
#                                      the first time for a user, it runs _tools/first-run.sh in a
#                                      terminal window with the splash in front
#   /usr/share/applications/agents.desktop, /usr/share/icons/hicolor/*/apps/acf.png,
#   /usr/share/metainfo/io.github.acf.agents.metainfo.xml
#                                      the "Agents" app-menu entry with the logo, and what software
#                                      centres show for the package (name, summary, logo)
# Installing it changes nothing in any home folder; the first run does that, as the user, with no
# sudo (first-run.sh). The per-user launcher it installs (~/.local/share/applications/agents.desktop)
# has the same name, so the menu keeps one "Agents" entry.
#
# Staged on ext4 (~/.cache/acf-deb): an NTFS folder cannot hold the modes dpkg-deb insists on.
# Installs nothing. Install the result with:  sudo apt install ./dist/agentic-cli-fleet_<VERSION>_amd64.deb
# The logo files must be up to date with logo.png (python3 _tools/build-logo.py makes them).
set -euo pipefail
umask 022
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DRY=0; TMUX=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-tmux) TMUX=0 ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
die() { echo "build-deb: $*" >&2; exit 1; }

PKG=agentic-cli-fleet
ARCH=amd64
OPT=/opt/$PKG
VERSION=$(tr -d ' \n' < "$HERE/VERSION" 2>/dev/null || true)
[[ "$VERSION" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || die "no version in $HERE/VERSION"
name=$(git -C "$HERE" config user.name 2>/dev/null || true); mail=$(git -C "$HERE" config user.email 2>/dev/null || true)
MAINTAINER=${ACF_DEB_MAINTAINER:-${name:-Agentic CLI Fleet} <${mail:-acf@localhost}>}
STAGE_ROOT=${ACF_DEB_STAGE:-$HOME/.cache/acf-deb}
STAGE="$STAGE_ROOT/${PKG}_${VERSION}_${ARCH}"
DEB="$STAGE_ROOT/${PKG}_${VERSION}_${ARCH}.deb"
DIST="$HERE/dist"
# never in the package: the repository, the chat logs, built packages, hand-kept copies, caches
EXCLUDE=(--exclude=./.git --exclude=./logs --exclude=./dist --exclude='__pycache__' --exclude='*.bak-*'
         --exclude='*.pyc' --exclude=./config/agents/copy-names)

if (( DRY )); then
  echo "would build $PKG $VERSION ($ARCH), maintainer $MAINTAINER"
  echo "  stage in $STAGE"
  echo "  $OPT/  <- this folder ($(tar -C "$HERE" "${EXCLUDE[@]}" -cf - . | wc -c | awk '{ printf "%.1f MB", $1 / 1048576 }'), lists in config/agents/ as templates)"
  (( TMUX )) && echo "  $OPT/tmux-3.8/  <- bash _tools/build-tmux.sh --prefix $OPT/tmux-3.8 --destdir <stage>" \
             || echo "  (no tmux build: the first run builds it)"
  printf '  %s\n' /usr/bin/$PKG /usr/share/applications/agents.desktop \
    "/usr/share/icons/hicolor/{$(ls "$HERE/share/icons/hicolor" | tr '\n' ',' | sed 's/,$//')}/apps/acf.png" \
    /usr/share/pixmaps/acf.png /usr/share/metainfo/io.github.acf.agents.metainfo.xml /usr/share/doc/$PKG/
  echo "  write $DEB, copy to $DIST/"
  command -v dpkg-deb >/dev/null || echo "  (missing: dpkg-deb)"
  exit 0
fi

command -v dpkg-deb >/dev/null || die "dpkg-deb not found"
[[ -f "$HERE/share/acf/splash.png" && -f "$HERE/share/icons/hicolor/256x256/apps/acf.png" ]] \
  || die "no logo files: run  python3 _tools/build-logo.py"
if python3 -c 'import PIL' 2>/dev/null; then
  python3 "$HERE/_tools/build-logo.py" --check >/dev/null || die "the logo files are older than logo.png: run  python3 _tools/build-logo.py"
fi

echo "staging in $STAGE..."
rm -rf "$STAGE" "$DEB"
mkdir -p "$STAGE/DEBIAN" "$STAGE$OPT"
tar -C "$HERE" "${EXCLUDE[@]}" -cf - . | tar -C "$STAGE$OPT" --no-same-owner -xf -
chmod -R u+rwX,go+rX,go-w "$STAGE$OPT"

# The lists under config/agents/ are this machine's: they go in as templates. Comments stay; of the
# account lists only each tool's default account (its own folder), named main; no projects, no
# chat-log folders, no labels.
A="$STAGE$OPT/config/agents"
keep_default() {  # <file> <default folder> [new name]
  [[ -f "$1" ]] || return 0
  awk -v d="$2" -v n="${3:-}" '/^#/ || !NF { print; next } $2 == d { if (n != "") $1 = n; printf "%-8s %s\n", $1, $2 }' "$1" > "$1.new"
  mv -f "$1.new" "$1"
}
keep_default "$A/accounts" "~/.claude" main
keep_default "$A/accounts-codex" "~/.codex"
keep_default "$A/accounts-gemini" "~"
keep_default "$A/accounts-agy" "~"
[[ -f "$A/projects" ]] && { grep -E '^#' "$A/projects" | grep -v '^# closed' > "$A/projects.new" || true; mv -f "$A/projects.new" "$A/projects"; }
[[ -f "$A/account-labels" ]] && { grep -E '^#' "$A/account-labels" > "$A/account-labels.new" || true; mv -f "$A/account-labels.new" "$A/account-labels"; }
: > "$A/log-projects"
chmod 644 "$A"/*
# This machine's own paths, where the launcher or a program names them, made general: the launcher
# runs ~/.local/bin/agents (install.sh writes the user's home in when it copies it), and Alt+N's
# folder dialog starts in the home folder. Then nothing of this machine's may be left.
sed -i -E "s|^(Exec=)[^ ]*/\.local/bin/|\1/home/USER/.local/bin/|" "$STAGE$OPT/share/applications/agents.desktop"
sed -i -E 's/\$\{AGENTS_PICK_DIR:-[^}]*\}/${AGENTS_PICK_DIR:-$HOME}/' "$STAGE$OPT/bin/agents"
left=$(grep -rIl -e "$HOME/" -e "/media/$(id -un)/" "$STAGE$OPT" 2>/dev/null | sed "s|^$STAGE||" || true)
[[ -z "$left" ]] || die "this machine's paths are still in: $left"

if (( TMUX )); then
  echo "building the patched tmux for $OPT/tmux-3.8 (about a minute, low priority)..."
  bash "$HERE/_tools/build-tmux.sh" --prefix "$OPT/tmux-3.8" --destdir "$STAGE" | sed 's/^/  /'
  [[ -x "$STAGE$OPT/tmux-3.8/bin/tmux" ]] || die "the tmux build left no program"
  strip --strip-unneeded "$STAGE$OPT/tmux-3.8/bin/tmux" 2>/dev/null || true
fi

# the launcher on the PATH
install -d "$STAGE/usr/bin"
cat > "$STAGE/usr/bin/$PKG" <<EOF
#!/bin/sh
# Agentic CLI Fleet (from the .deb): what the "Agents" entry in the app menu runs.
# Set up for this user already: open the fleet window, or bring it forward (agents --window).
# Not yet: set the fleet up first ($OPT/_tools/first-run.sh), in a terminal window, with the
# splash in front. Nothing here needs sudo.
ROOT=$OPT
A="\$HOME/.local/bin/agents"
if [ -x "\$A" ]; then
  if [ "\${1:-}" = --new-window ]; then exec "\$A" --new-window; fi
  exec "\$A" --window
fi
if [ -t 0 ]; then exec bash "\$ROOT/_tools/first-run.sh"; fi
"\$ROOT/bin/afc-splash" --text "Setting the fleet up…" >/dev/null 2>&1 &
if command -v alacritty >/dev/null 2>&1; then
  exec alacritty --title "Agentic CLI Fleet: setting up" -e bash "\$ROOT/_tools/first-run.sh"
elif command -v konsole >/dev/null 2>&1; then exec konsole -e bash "\$ROOT/_tools/first-run.sh"
elif command -v x-terminal-emulator >/dev/null 2>&1; then exec x-terminal-emulator -e bash "\$ROOT/_tools/first-run.sh"
fi
command -v notify-send >/dev/null 2>&1 && notify-send -i acf "Agentic CLI Fleet" "No terminal program found. Open a terminal and run: $PKG"
exit 1
EOF
chmod 755 "$STAGE/usr/bin/$PKG"

# the app-menu entry, the logo, and what a software centre shows
install -d "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/agents.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Agents
GenericName=Agentic CLI Fleet
Comment=Agentic CLI Fleet: one tab per project, the agents already running
Exec=/usr/bin/$PKG
Icon=acf
Terminal=false
Categories=Development;
Keywords=agents;claude;codex;gemini;antigravity;tmux;fleet;
StartupWMClass=Agents
Actions=new-window;

[Desktop Action new-window]
Name=New Agents Window (another monitor)
Exec=/usr/bin/$PKG --new-window
EOF
for d in "$HERE"/share/icons/hicolor/*/apps/acf.png; do
  r=${d#"$HERE"/share/}
  install -Dm644 "$d" "$STAGE/usr/share/$r"
done
install -Dm644 "$HERE/share/icons/hicolor/256x256/apps/acf.png" "$STAGE/usr/share/pixmaps/acf.png"
install -d "$STAGE/usr/share/metainfo"
cat > "$STAGE/usr/share/metainfo/io.github.acf.agents.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>io.github.acf.agents</id>
  <metadata_license>CC0-1.0</metadata_license>
  <name>Agentic CLI Fleet</name>
  <summary>Claude, Codex, Gemini and Antigravity agents side by side, one tab per project</summary>
  <description>
    <p>The fleet opens every project you work on in a tab of its own, with its coding agent already
    running, inside one terminal window. A resource budget keeps the agents from slowing the
    machine, a chat log keeps every conversation in its project, and the council lets several
    models discuss a question together.</p>
  </description>
  <launchable type="desktop-id">agents.desktop</launchable>
  <icon type="stock">acf</icon>
  <url type="homepage">https://github.com/Geek2017/ACF</url>
  <provides><binary>$PKG</binary></provides>
  <releases><release version="$VERSION" date="$(date +%F)"/></releases>
  <content_rating type="oars-1.1"/>
</component>
EOF

install -d "$STAGE/usr/share/doc/$PKG"
cat > "$STAGE/usr/share/doc/$PKG/README.Debian" <<EOF
Agentic CLI Fleet for Ubuntu
----------------------------

The fleet lives in $OPT. Installing the package changes no home folder.

The first time a user opens "Agents" from the app menu (or runs $PKG), it sets the fleet
up for that user, with no sudo ($OPT/_tools/first-run.sh): its programs are linked into
~/.local/bin, its tmux config, launcher, logo, lists and systemd user units are put in place,
the patched tmux the package brings is used ($OPT/tmux-3.8), Claude Code is installed when it
is missing, and the background services start. After that the same entry opens the fleet.

Then: sign in (agents --as main, then /login) and add projects (Alt+N in the fleet).
agents --doctor checks the set-up. The full guide: $OPT/README.md

Removing the package leaves each user's set-up in place; the links into $OPT stop working.
EOF
cat > "$STAGE/usr/share/doc/$PKG/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Agentic CLI Fleet
Source: https://github.com/Geek2017/ACF

Files: $OPT/tmux/src/* $OPT/tmux-3.8/*
Copyright: Nicholas Marriott and the tmux authors
License: ISC
EOF

# --- control ---------------------------------------------------------------------------------------
SHLIBS=""
if (( TMUX )) && command -v dpkg-shlibdeps >/dev/null; then
  mkdir -p "$STAGE_ROOT/shlibs/debian"
  printf 'Source: %s\n\nPackage: %s\nArchitecture: %s\n' "$PKG" "$PKG" "$ARCH" > "$STAGE_ROOT/shlibs/debian/control"
  SHLIBS=$(cd "$STAGE_ROOT/shlibs" && dpkg-shlibdeps -O "$STAGE$OPT/tmux-3.8/bin/tmux" 2>/dev/null \
           | sed -n 's/^shlibs:Depends=//p') || SHLIBS=""
fi
[[ -n "$SHLIBS" ]] || SHLIBS="libc6"
DEPENDS="$SHLIBS, bash (>= 5), python3, git, jq, curl, ca-certificates, procps, util-linux, coreutils, systemd"
SIZE_KB=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $SIZE_KB
Depends: $DEPENDS
Recommends: alacritty | konsole, python3-gi, gir1.2-gtk-3.0, libnotify-bin, xclip
Suggests: kdialog
Section: devel
Priority: optional
Homepage: https://github.com/Geek2017/ACF
Description: coding agents side by side, one tab per project
 Agentic CLI Fleet opens every project you work on in a tab of its own, with
 its coding agent (Claude Code, Codex, Gemini or Antigravity) already running,
 in one terminal window, on a patched tmux. A resource budget keeps the agents
 from slowing the machine, a chat log keeps every conversation in its project,
 and the council lets several models discuss one question.
 .
 Open "Agents" from the app menu: the first time, it sets the fleet up for
 your user (no sudo); after that it opens the fleet.
EOF
cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
  echo "Agentic CLI Fleet $VERSION is in $OPT."
  echo "Open \"Agents\" from the app menu (or run $PKG): the first time, it sets the fleet up for you."
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"
chmod 644 "$STAGE/DEBIAN/control"

echo "packing $DEB..."
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB" >/dev/null
mkdir -p "$DIST"
cp -f "$DEB" "$DIST/"
OUT="$DIST/$(basename "$DEB")"
echo "built: $OUT ($(du -h "$OUT" | cut -f1), $(dpkg-deb -c "$OUT" | wc -l) files)"
if command -v lintian >/dev/null; then lintian "$OUT" || echo "(lintian reported the above)"; fi
echo "install with:  sudo apt install '$OUT'"
