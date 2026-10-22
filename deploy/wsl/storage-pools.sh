#!/usr/bin/env bash
# Puts workdirs and Podman storage on fixed-size disk images; run as root with Monarch stopped: bash storage-pools.sh [user] [work GB] [storage GB]
set -euo pipefail

MONARCH_USER="${1:-monarch}"
WORK_GB="${2:-10}"
STORE_GB="${3:-20}"
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run as root"
MONARCH_UID=$(id -u "$MONARCH_USER")
HOME_DIR=$(getent passwd "$MONARCH_USER" | cut -d: -f6)
WORK="$HOME_DIR/monarch/work"
STORE="$HOME_DIR/.local/share/containers"
POOLS=/var/lib/monarch
as_user() { sudo -u "$MONARCH_USER" XDG_RUNTIME_DIR="/run/user/$MONARCH_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$MONARCH_UID/bus" "$@"; }

free_gb=$(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc 0-9)
need=$((WORK_GB + STORE_GB))
# The images are sparse, but they are only a real ceiling if the Windows drive could actually hold them.
[ -z "$free_gb" ] || [ "$free_gb" -ge $((need + 10)) ] || die "pools need ${need}GB plus 10GB headroom, the Windows drive has ${free_gb}GB free; pass smaller sizes"

pool() { # name, mountpoint, size GB
  local img="$POOLS/$1.img" mnt="$2" size="$3"
  if findmnt -rn "$mnt" >/dev/null; then echo "$mnt already a mounted pool"; return; fi
  [ -e "$img" ] || { truncate -s "${size}G" "$img"; mkfs.ext4 -q -F -m 0 -L "monarch-$1" "$img"; }
  mkdir -p "$mnt"
  grep -q " $mnt " /etc/fstab || echo "$img $mnt ext4 loop,nosuid,nodev,noatime,discard 0 2" >> /etc/fstab
  mount "$mnt"
  chown "$MONARCH_USER:$MONARCH_USER" "$mnt"
  chmod 700 "$mnt"
}

mkdir -p "$POOLS" && chmod 700 "$POOLS"
if ! findmnt -rn "$STORE" >/dev/null || ! findmnt -rn "$WORK" >/dev/null; then
  say "Stopping Monarch and Podman to move their storage"
  as_user systemctl --user stop monarch.service podman.socket podman.service 2>/dev/null || true
  [ -z "$(as_user podman ps -q 2>/dev/null)" ] || die "sandboxes are still running; stop them first"
fi

if ! findmnt -rn "$STORE" >/dev/null; then
  say "Podman storage: ${STORE_GB}GB pool (existing images are dropped and rebuilt on next start)"
  as_user podman system reset -f >/dev/null 2>&1 || true
  rm -rf "$STORE"
  pool storage "$STORE" "$STORE_GB"
fi
if ! findmnt -rn "$WORK" >/dev/null; then
  say "Sandbox workdirs: ${WORK_GB}GB pool"
  rm -rf "$WORK"
  pool work "$WORK" "$WORK_GB"
fi

ENV="$HOME_DIR/.config/monarch/monarch.env"
if [ -f "$ENV" ]; then
  # The floor has to watch the pools too: sandbox creation should stop before a pool fills, not after.
  sed -i "s#^MONARCH_DISK_CHECK_PATHS=.*#MONARCH_DISK_CHECK_PATHS=/mnt/c,$WORK,$STORE#" "$ENV"
  grep -q '^MONARCH_DISK_CHECK_PATHS=' "$ENV" || echo "MONARCH_DISK_CHECK_PATHS=/mnt/c,$WORK,$STORE" >> "$ENV"
fi

as_user systemctl --user start podman.socket
df -h "$WORK" "$STORE" | sed 1d
echo "Pools ready. Start Monarch: systemctl --user start monarch (as $MONARCH_USER); images rebuild on first start."
