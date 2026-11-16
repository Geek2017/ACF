#!/usr/bin/env bash
# build-tmux.sh: build the fleet's patched tmux 3.8 using ONLY what is in this folder.
# No download, no sudo: the source archive, the patch and the four build packages are all here.
#
#   bash _tools/build-tmux.sh                 build and install into ~/.local/opt/tmux-3.8
#   bash _tools/build-tmux.sh --prefix DIR    install somewhere else (to try a build safely)
#   bash _tools/build-tmux.sh --dry-run       check the parts and say what it would do
#
# Uses: tmux/src/tmux-3.8.tar.gz   the official tmux 3.8 source
#       tmux/afc-tmux-3.8.patch    the fleet's changes (thin scrollbar, header-click position, hover)
#                                  and upstream's fix for pane output drawing over an open menu
#       tmux/deps/*.deb            libevent-dev, libncurses-dev, bison, m4 (Ubuntu 24.04, amd64);
#                                  unpacked into a temporary folder, never installed on the system
#       tmux/SHA256SUMS            checked before anything is built
# Needs on the machine: gcc, make, pkg-config, dpkg, tar, patch (all in Ubuntu's build-essential set).
# On another distro or CPU, delete tmux/deps and install those four packages' equivalents yourself;
# with no .deb files present the system's own are used.
#
# The build runs in a temporary folder and at low priority. If a tmux is already installed at the
# target, it is kept beside the new one as bin/tmux-before-<date>. A running fleet keeps using the
# old program until it is restarted; this script does not restart anything.
set -euo pipefail
PREFIX="$HOME/.local/opt/tmux-3.8"; DRY=0
while (( $# )); do
  case "$1" in
    --prefix) PREFIX=${2:?--prefix needs a folder}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/tmux/src/tmux-3.8.tar.gz"; PATCH="$HERE/tmux/afc-tmux-3.8.patch"; DEPS="$HERE/tmux/deps"

for f in "$SRC" "$PATCH"; do [[ -r "$f" ]] || { echo "missing: $f" >&2; exit 1; }; done
for c in gcc make pkg-config tar patch; do command -v "$c" >/dev/null || { echo "needs $c on this machine" >&2; exit 1; }; done
debs=(); for d in "$DEPS"/*.deb; do [[ -e "$d" ]] && debs+=("$d"); done
(( ${#debs[@]} == 0 )) || command -v dpkg >/dev/null || { echo "needs dpkg to unpack tmux/deps (or delete that folder)" >&2; exit 1; }
if [[ -r "$HERE/tmux/SHA256SUMS" ]]; then
  ( cd "$HERE/tmux" && sha256sum --quiet -c SHA256SUMS ) || { echo "a file in tmux/ does not match SHA256SUMS" >&2; exit 1; }
fi

echo "source : $SRC"
echo "patch  : $PATCH ($(grep -c '^+++ ' "$PATCH") files)"
echo "deps   : ${#debs[@]} package(s) from the folder$( (( ${#debs[@]} )) || echo ' (none: using the system'"'"'s)')"
echo "install: $PREFIX"
if (( DRY )); then echo "DRY RUN: parts are all here and intact; nothing built."; exit 0; fi

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CPP=""; LDF=""
if (( ${#debs[@]} )); then
  for d in "${debs[@]}"; do dpkg -x "$d" "$W/dep"; done
  L="$W/dep/usr/lib/$(gcc -dumpmachine)"
  # drop the dangling .so links, so the libraries are linked in from the .a files
  rm -f "$L"/libevent*.so "$L"/libtinfo.so "$L"/libncurses*.so "$L"/libcurses.so "$L"/libtermcap.so
  export PATH="$W/dep/usr/bin:$PATH" M4="$W/dep/usr/bin/m4" BISON_PKGDATADIR="$W/dep/usr/share/bison"
  export PKG_CONFIG_PATH="$L/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$W/dep"
  CPP="-I$W/dep/usr/include"; LDF="-L$L"
fi

tar xzf "$SRC" -C "$W"
cd "$W/tmux-3.8"
patch -p2 --quiet < "$PATCH"
echo "configuring..."
./configure --prefix="$PREFIX" CPPFLAGS="$CPP" LDFLAGS="$LDF" > "$W/configure.log" 2>&1 || { tail -15 "$W/configure.log"; exit 1; }
echo "compiling (low priority)..."
nice -n 10 make -j2 > "$W/make.log" 2>&1 || { grep -n ' error' "$W/make.log" | head -20; exit 1; }
if [[ -x "$PREFIX/bin/tmux" ]]; then cp -p "$PREFIX/bin/tmux" "$PREFIX/bin/tmux-before-$(date +%Y%m%d-%H%M%S)"; fi
make install > "$W/install.log" 2>&1 || { tail -10 "$W/install.log"; exit 1; }
cp -p "$PATCH" "$PREFIX/afc-thin-scrollbar.patch"

echo "built: $("$PREFIX/bin/tmux" -V) at $PREFIX/bin/tmux"
[[ "$PREFIX" == "$HOME/.local/opt/tmux-3.8" ]] && echo "The fleet uses it after its next restart (~/.local/bin/tmux must point at $PREFIX/bin/tmux)."
exit 0
