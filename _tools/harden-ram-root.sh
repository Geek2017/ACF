#!/usr/bin/env bash
# harden-ram-root.sh: install/enable systemd-oomd and cap /tmp tmpfs proportionally to host RAM.
# Run once with: sudo bash _tools/harden-ram-root.sh
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${TMP_SIZE:-}" ]]; then
  if [[ -r "$HERE/_tools/tune-specs.py" ]] && command -v python3 >/dev/null 2>&1; then
    TMP_SIZE=$(python3 -I "$HERE/_tools/tune-specs.py" --field tmp_size 2>/dev/null || echo "2G")
  else
    TMP_SIZE="2G"
  fi
fi
if [[ ! "$TMP_SIZE" =~ ^[0-9]+[MG]$ ]]; then
  echo "Invalid TMP_SIZE: $TMP_SIZE (expected e.g. 2G or 1536M)" >&2
  exit 2
fi
FSTAB="/etc/fstab"

echo "=== 1. Install and enable systemd-oomd ==="
if ! dpkg -s systemd-oomd >/dev/null 2>&1; then
  apt-get update
  apt-get install -y systemd-oomd
fi
systemctl enable --now systemd-oomd
systemctl is-active --quiet systemd-oomd

echo "=== 2. Cap /tmp tmpfs to ${TMP_SIZE} in ${FSTAB} ==="
if ! grep -Eq '^[^#[:space:]]+[[:space:]]+/tmp[[:space:]]+tmpfs[[:space:]]' "$FSTAB"; then
  echo "Warning: no tmpfs /tmp entry found in ${FSTAB}; skipping fstab edit." >&2
else
  if ! grep -Eq '^[^#[:space:]]+[[:space:]]+/tmp[[:space:]]+tmpfs[[:space:]]+[^#]*size=' "$FSTAB"; then
    bak="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$FSTAB" "$bak"
    echo "Backed up ${FSTAB} -> ${bak}"
    sed -i -E "s|^([^#[:space:]]+[[:space:]]+/tmp[[:space:]]+tmpfs[[:space:]]+)([^[:space:]]+)|\1\2,size=${TMP_SIZE}|" "$FSTAB"
  else
    echo "${FSTAB} /tmp already has a size= cap; leaving it as-is."
  fi

  num=${TMP_SIZE%[MG]}; unit=${TMP_SIZE#"$num"}
  if [[ "$unit" == G ]]; then cap_kb=$(( num * 1024 * 1024 )); else cap_kb=$(( num * 1024 )); fi
  safe_kb=$(( cap_kb * 92 / 100 ))
  used_kb=$(df -k --output=used /tmp | tail -n 1 | tr -d ' ')
  if [[ "$used_kb" =~ ^[0-9]+$ ]] && (( used_kb < safe_kb )); then
    mount -o "remount,size=${TMP_SIZE}" /tmp
  else
    echo "Skipping live remount: /tmp holds $((used_kb / 1024)) MiB (>= $((safe_kb / 1024)) MiB). Clean /tmp or reboot." >&2
  fi
fi

echo "=== 3. Verify ==="
echo "systemd-oomd: $(systemctl is-active systemd-oomd)"
df -h /tmp
grep -E '^tmpfs[[:space:]]+/tmp[[:space:]]' "$FSTAB" || true
