#!/usr/bin/env bash
# Installs or upgrades Monarch as a systemd user service. Run as root: bash install-runtime.sh <repo dir> <linux binary> [user]
set -euo pipefail

SRC="${1:?repo directory (the one with sandbox-images/ and agent-services/)}"
BIN="${2:?monarch binary built with GOOS=linux}"
MONARCH_USER="${3:-monarch}"
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run as root: after hardening only root can read /mnt/c"
[ -x /usr/local/lib/monarch/preflight.sh ] || die "run harden.sh first"
MONARCH_UID=$(id -u "$MONARCH_USER")
HOME_DIR=$(getent passwd "$MONARCH_USER" | cut -d: -f6)
APP="$HOME_DIR/app"
as_user() { sudo -u "$MONARCH_USER" XDG_RUNTIME_DIR="/run/user/$MONARCH_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$MONARCH_UID/bus" "$@"; }

say "Staging the build in $APP"
as_user systemctl --user stop monarch.service 2>/dev/null || true
mkdir -p "$APP/agent-services" "$HOME_DIR/monarch/work"
install -m 755 "$BIN" "$APP/monarch"
rm -rf "$APP/sandbox-images" && cp -r "$SRC/sandbox-images" "$APP/"
find "$SRC/agent-services" -maxdepth 1 -type f \( -name '*.js' -o -name '*.mjs' -o -name 'package*.json' \) -exec cp {} "$APP/agent-services/" \;
for d in hub opengap; do rm -rf "$APP/agent-services/$d" && cp -r "$SRC/agent-services/$d" "$APP/agent-services/"; done
cp "$SRC/deploy/wsl/wsclient.mjs" "$APP/agent-services/" 2>/dev/null || true
# After hardening the service user cannot read /mnt/c, so its tooling lives beside the app.
rm -rf "$APP/deploy" && mkdir -p "$APP/deploy" && cp "$SRC"/deploy/wsl/*.sh "$SRC"/deploy/wsl/*.mjs "$APP/deploy/"
chown -R "$MONARCH_USER:$MONARCH_USER" "$APP" "$HOME_DIR/monarch"
(cd "$APP/agent-services" && as_user npm ci --no-audit --no-fund --loglevel=error)

ENV="$HOME_DIR/.config/monarch/monarch.env"
if [ ! -f "$ENV" ]; then
  say "Writing $ENV (fresh secrets; edit MONARCH_PUBLIC_ORIGIN and your API keys)"
  mkdir -p "$(dirname "$ENV")"
  rnd() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
  cat > "$ENV" <<CONF
# Your Tailscale Funnel address, e.g. https://inspiron.tail1234.ts.net
MONARCH_PUBLIC_ORIGIN=https://CHANGE-ME.ts.net
MONARCH_BETA_CODE=$(rnd 6)
MONARCH_SESSION_SECRET=$(rnd 32)
MONARCH_CONTAINER_CLI=podman
DOCKER_HOST=unix:///run/user/$MONARCH_UID/podman/podman.sock
MONARCH_WORK_DIR=$HOME_DIR/monarch/work
MONARCH_DISK_CHECK_PATHS=/mnt/c,$HOME_DIR/monarch/work,$HOME_DIR/.local/share/containers
MONARCH_PREVIEW_MODE=quicktunnel
MONARCH_PREHEAT_IMAGES=node,react,python,builder
MONARCH_MAX_SANDBOXES=2
MONARCH_MAX_PER_USER=1
# GROQ_API_KEY=
CONF
fi
chown -R "$MONARCH_USER:$MONARCH_USER" "$(dirname "$ENV")"
chmod 700 "$(dirname "$ENV")"
chmod 600 "$ENV"

install -m 755 "$SRC/deploy/wsl/status.sh" /usr/local/lib/monarch/status.sh

say "systemd user unit (starts at boot through linger, refuses to start if hardening is off)"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/monarch.service" <<UNIT
[Unit]
Description=Monarch
Wants=podman.socket
After=podman.socket

[Service]
WorkingDirectory=%h/app
EnvironmentFile=%h/.config/monarch/monarch.env
ExecStartPre=/usr/local/lib/monarch/preflight.sh
ExecStart=%h/app/monarch
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=30

[Install]
WantedBy=default.target
UNIT
chown -R "$MONARCH_USER:$MONARCH_USER" "$HOME_DIR/.config"
as_user systemctl --user daemon-reload
as_user systemctl --user enable monarch.service >/dev/null

if grep -q 'CHANGE-ME' "$ENV"; then
  echo "Set MONARCH_PUBLIC_ORIGIN in $ENV, then: systemctl --user start monarch (as $MONARCH_USER)"
else
  as_user systemctl --user restart monarch.service
  sleep 5
  as_user systemctl --user --no-pager status monarch.service | head -5
fi
echo "Beta code: $(grep '^MONARCH_BETA_CODE=' "$ENV" | cut -d= -f2)"
