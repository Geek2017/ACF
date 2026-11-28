#!/usr/bin/env bash
# build-dmg.sh: the fleet as a macOS disk-image installer (counterpart to build-deb.sh):
#   dist/agentic-cli-fleet_<VERSION>_<arch>.dmg
#
#   bash _tools/build-dmg.sh              build it on macOS (arm64 or x86_64)
#   bash _tools/build-dmg.sh --dry-run    show what it would bundle, build nothing
#   bash _tools/build-dmg.sh --no-tmux    skip bundling patched tmux 3.8
#
# What the disk image holds:
#   ACF.app/
#     Contents/MacOS/ACF                  launcher: opens the fleet if already installed; on first
#                                         run shows the native splash and runs mac-setup.sh in Terminal
#     Contents/Resources/acf.icns         app icon (16px..512px)
#     Contents/Resources/fleet/           clean fleet payload (template config/agents/*, zero host paths)
#     Contents/Resources/fleet/bin-mac/   precompiled afc-splash-mac and agents-hotkey binaries
#     Contents/Resources/fleet/tmux-3.8/  prebuilt patched tmux 3.8 (unless --no-tmux)
#   Applications                          symlink to /Applications (drag ACF.app here to install)
#   Install-README.txt                    short install instructions
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
die() { echo "build-dmg: $*" >&2; exit 1; }

PKG=agentic-cli-fleet
ARCH=$(uname -m)
VERSION=$(tr -d ' \n' < "$HERE/VERSION" 2>/dev/null || true)
[[ "$VERSION" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || die "no version in $HERE/VERSION"

STAGE_ROOT="${ACF_DMG_STAGE:-/tmp/acf-dmg-$$}"
STAGE="$STAGE_ROOT/root"
APP="$STAGE/ACF.app"
FLEET="$APP/Contents/Resources/fleet"
DIST="$HERE/dist"
OUT="$DIST/${PKG}_${VERSION}_${ARCH}.dmg"
EXCLUDE=(--exclude=./.git --exclude=./logs --exclude=./dist --exclude='__pycache__' --exclude='*.bak-*'
         --exclude='*.pyc' --exclude=./config/agents/copy-names)

if (( DRY )); then
  echo "would build $PKG $VERSION ($ARCH) macOS installer"
  echo "  stage in $STAGE"
  echo "  ACF.app/Contents/Resources/fleet/  <- clean repo payload (config/agents/* as templates)"
  echo "  ACF.app/Contents/Resources/fleet/bin-mac/{afc-splash-mac,agents-hotkey}"
  (( TMUX )) && echo "  ACF.app/Contents/Resources/fleet/tmux-3.8/  <- prebuilt patched tmux 3.8" \
             || echo "  (no tmux bundle: mac-setup.sh builds it on first run)"
  echo "  ACF.app/Contents/Resources/acf.icns + Applications symlink"
  echo "  write $OUT"
  [[ "$(uname -s)" == Darwin ]] || echo "  (note: must run on macOS to compile Swift binaries and create .dmg)"
  exit 0
fi

[[ "$(uname -s)" == Darwin ]] || die "run build-dmg.sh on macOS (current OS: $(uname -s))"
for cmd in hdiutil iconutil swiftc tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found"
done
[[ -f "$HERE/share/acf/splash.png" && -f "$HERE/share/icons/hicolor/256x256/apps/acf.png" ]] \
  || die "no logo files: run  python3 _tools/build-logo.py"

trap 'rm -rf "$STAGE_ROOT"' EXIT
rm -rf "$STAGE_ROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FLEET/bin-mac"

echo "staging fleet payload in $STAGE..."
tar -C "$HERE" "${EXCLUDE[@]}" -cf - . | tar -C "$FLEET" -xf -
chmod -R u+rwX,go+rX,go-w "$FLEET"

# Strip machine-specific lists to clean templates (mirrors build-deb.sh)
A="$FLEET/config/agents"
keep_default() {
  [[ -f "$1" ]] || return 0
  awk -v d="$2" -v n="${3:-}" '/^#/ || !NF { print; next } $2 == d { if (n != "") $1 = n; printf "%-8s %s\n", $1, $2 }' "$1" > "$1.new"
  mv -f "$1.new" "$1"
}
keep_default "$A/accounts" "~/.claude" main
keep_default "$A/accounts-codex" "~/.codex"
keep_default "$A/accounts-gemini" "~"
keep_default "$A/accounts-agy" "~"
if [[ -f "$A/projects" ]]; then
  { grep -E '^#' "$A/projects" | grep -v '^# closed' > "$A/projects.new" || true; }
  mv -f "$A/projects.new" "$A/projects"
fi
if [[ -f "$A/account-labels" ]]; then
  { grep -E '^#' "$A/account-labels" > "$A/account-labels.new" || true; }
  mv -f "$A/account-labels.new" "$A/account-labels"
fi
: > "$A/log-projects"
chmod 644 "$A"/*

# Scrub host-specific paths from desktop template and agents picker default
sed -i '' -E 's|^(Exec=)[^ ]*/\.local/bin/|\1/home/USER/.local/bin/|' "$FLEET/share/applications/agents.desktop"
sed -i '' -E 's/\$\{AGENTS_PICK_DIR:-[^}]*\}/${AGENTS_PICK_DIR:-$HOME}/' "$FLEET/bin/agents"
left=$(grep -rIl -e "$HOME/" -e "/media/$(id -un)/" "$FLEET" 2>/dev/null | sed "s|^$FLEET||" || true)
[[ -z "$left" ]] || die "host-specific paths remain in bundle: $left"

# Compile native macOS binaries (universal arm64 + x86_64 when supported, else native arch)
build_mac_bin() {
  local src="$1" dst="$2"
  if command -v lipo >/dev/null 2>&1 \
     && swiftc -O -suppress-warnings -target arm64-apple-macos13.0  -o "$dst.arm64"  "$src" 2>/dev/null \
     && swiftc -O -suppress-warnings -target x86_64-apple-macos13.0 -o "$dst.x86_64" "$src" 2>/dev/null; then
    lipo -create "$dst.arm64" "$dst.x86_64" -output "$dst"
    rm -f "$dst.arm64" "$dst.x86_64"
  else
    rm -f "$dst.arm64" "$dst.x86_64"
    swiftc -O -suppress-warnings -o "$dst" "$src"
  fi
  chmod 755 "$dst"
}
echo "compiling native macOS binaries (universal arm64+x86_64)..."
build_mac_bin "$HERE/share/mac/afc-splash-mac.swift" "$FLEET/bin-mac/afc-splash-mac"
build_mac_bin "$HERE/share/mac/agents-hotkey.swift"  "$FLEET/bin-mac/agents-hotkey"

# Bundle patched tmux 3.8 if requested
if (( TMUX )); then
  if [[ -x "$HOME/.local/opt/tmux-3.8/bin/tmux" ]]; then
    echo "bundling existing patched tmux 3.8 from ~/.local/opt/tmux-3.8..."
    mkdir -p "$FLEET/tmux-3.8"
    cp -Rp "$HOME/.local/opt/tmux-3.8"/* "$FLEET/tmux-3.8/"
  else
    echo "building patched tmux 3.8..."
    bash "$HERE/_tools/build-tmux.sh" --prefix "$FLEET/tmux-3.8" | sed 's/^/  /'
  fi
  [[ -x "$FLEET/tmux-3.8/bin/tmux" ]] || die "bundled tmux 3.8 binary missing"
fi

# Build acf.icns icon
echo "building acf.icns..."
ICONSET="$STAGE_ROOT/acf.iconset"
mkdir -p "$ICONSET"
cp "$HERE/share/icons/hicolor/16x16/apps/acf.png"   "$ICONSET/icon_16x16.png"
cp "$HERE/share/icons/hicolor/32x32/apps/acf.png"   "$ICONSET/icon_16x16@2x.png"
cp "$HERE/share/icons/hicolor/32x32/apps/acf.png"   "$ICONSET/icon_32x32.png"
cp "$HERE/share/icons/hicolor/64x64/apps/acf.png"   "$ICONSET/icon_32x32@2x.png"
cp "$HERE/share/icons/hicolor/128x128/apps/acf.png" "$ICONSET/icon_128x128.png"
cp "$HERE/share/icons/hicolor/256x256/apps/acf.png" "$ICONSET/icon_128x128@2x.png"
cp "$HERE/share/icons/hicolor/256x256/apps/acf.png" "$ICONSET/icon_256x256.png"
cp "$HERE/share/icons/hicolor/512x512/apps/acf.png" "$ICONSET/icon_256x256@2x.png"
cp "$HERE/share/icons/hicolor/512x512/apps/acf.png" "$ICONSET/icon_512x512.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/acf.icns"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ACF</string>
  <key>CFBundleDisplayName</key><string>Agentic CLI Fleet</string>
  <key>CFBundleIdentifier</key><string>io.github.acf.launcher</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>ACF</string>
  <key>CFBundleIconFile</key><string>acf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# First-run Terminal script (launched via open -a Terminal, so zero macOS Automation prompts)
cat > "$FLEET/_tools/mac-first-run.command" <<'FIRST'
#!/bin/bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -x /opt/homebrew/bin/bash ]]; then
  /opt/homebrew/bin/bash "$HERE/_tools/mac-setup.sh"
else
  /bin/bash "$HERE/_tools/mac-setup.sh"
fi
echo
read -rp "Press Enter to open Agentic CLI Fleet (or close this window) " _ || exit 0
exec "$HOME/.local/bin/agents"
FIRST
chmod 755 "$FLEET/_tools/mac-first-run.command"

# Launcher executable: ensures splash/hotkey assets are installed, shows native splash immediately,
# then opens the fleet (or launches mac-first-run.command in Terminal on first run).
cat > "$APP/Contents/MacOS/ACF" <<'LAUNCH'
#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$BUNDLE_DIR/Resources/fleet"
SPLASH_BIN="$FLEET/bin-mac/afc-splash-mac"
SPLASH_DIR="$FLEET/share/acf"

# Always keep ~/.local/share/acf and native macOS helpers in sync with this ACF.app bundle
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/acf"
for sf in "$SPLASH_DIR"/*; do
  [[ -f "$sf" ]] || continue
  dst="$HOME/.local/share/acf/${sf##*/}"
  [[ -f "$dst" && ! "$sf" -nt "$dst" ]] || cp -p "$sf" "$dst" 2>/dev/null || true
done
for mb in afc-splash-mac agents-hotkey; do
  src="$FLEET/bin-mac/$mb"; dst="$HOME/.local/bin/$mb"
  if [[ -x "$src" && ( ! -x "$dst" || "$src" -nt "$dst" ) ]]; then
    cp -p "$src" "$dst" 2>/dev/null || true
    chmod 755 "$dst" 2>/dev/null || true
  fi
done

splash_enabled() {
  [[ "${ACF_SPLASH:-}" =~ ^(0|off|no)$ ]] && return 1
  local f="$HOME/.config/agents/settings"
  if [[ -r "$f" ]]; then
    local v
    v=$(awk '$1 == "splash" { v = tolower($2) } END { print v }' "$f" 2>/dev/null || true)
    [[ "$v" == off || "$v" == 0 || "$v" == no ]] && return 1
  fi
  return 0
}

play_splash() {
  local text="$1" secs="$2"
  splash_enabled || return 0
  [[ -x "$SPLASH_BIN" && -f "$SPLASH_DIR/splash.png" ]] || return 0
  "$SPLASH_BIN" --assets "$SPLASH_DIR" --text "$text" --seconds "$secs" > "${TMPDIR:-/tmp}/afc-splash.log" 2>&1 < /dev/null &
  local sp=$!
  for _ in $(seq 1 60); do kill -0 "$sp" 2>/dev/null || break; sleep 0.1; done
}

# Check if the fleet is already open in a Terminal client
fleet_attached() {
  local tm=""
  for c in "$HOME/.local/bin/tmux" "$HOME/.local/opt/tmux-3.8/bin/tmux" /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    [[ -x "$c" ]] && { tm="$c"; break; }
  done
  [[ -n "$tm" ]] && [[ -n "$("$tm" -L agents list-clients -t agents 2>/dev/null || true)" ]]
}

if [[ -x "$HOME/.local/bin/agents" ]]; then
  if fleet_attached; then
    open -a Terminal >/dev/null 2>&1 || true
    exit 0
  fi
  play_splash "Starting the fleet…" 4
  exec env ACF_SPLASH=0 "$HOME/.local/bin/agents" --window
fi

# First run: show native splash, then open Terminal to run mac-first-run.command (no osascript needed)
play_splash "Setting the fleet up…" 3
exec open -a Terminal "$FLEET/_tools/mac-first-run.command"
LAUNCH
chmod 755 "$APP/Contents/MacOS/ACF"

# Ad-hoc sign so Apple Silicon Gatekeeper/exec accepts the bundle locally
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

# Drag-to-Applications layout
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install-README.txt" <<README
Agentic CLI Fleet $VERSION for macOS ($ARCH)
============================================

1. Drag ACF.app onto the Applications folder.
2. Open ACF from Applications, Spotlight (Cmd+Space -> ACF), or Launchpad.
3. On first launch, Terminal runs mac-setup.sh to install links, tmux, splash, and Option+A hotkey.
4. After setup, opening ACF (or pressing Option+A) shows the splash and opens your fleet.
README

mkdir -p "$DIST"
rm -f "$OUT"
echo "creating $OUT..."
hdiutil create -volname "Agentic CLI Fleet" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
echo "install: open '$OUT' and drag ACF.app into Applications"
